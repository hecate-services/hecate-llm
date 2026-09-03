%%% @doc Chat to LLM
%%% Dispatches chat completion to the appropriate provider via manage_providers.
%%% Instruments all calls with llm_pricing for cost tracking.
%%%
%%% THE FALLBACK. A caller names a model, and the model picks the provider
%%% (manage_providers:provider_for_model/1). When that provider cannot
%%% answer -- rate-limited, down, timing out, or not listing the model at
%%% all because its own model listing was rate-limited too -- the call is
%%% made once more against the fallback provider with the fallback model,
%%% and the reply says so (`served_by', `requested_model'). NVIDIA's free
%%% endpoint answered 429 to every request on this fleet for a full day
%%% (2026-09-02/03) and this gateway, holding only an NVIDIA key, failed
%%% every call without a single log line. Now the fallback is tried and
%%% the switch is logged.
%%%
%%% Configured by environment, so a node can change it without a rebuild:
%%%
%%%   HECATE_LLM_FALLBACK_PROVIDER   default `deepseek'; `none' disables
%%%   HECATE_LLM_FALLBACK_MODEL      default `deepseek-chat'
%%%
%%% The fallback provider must be detected like any other (its API key in
%%% the environment, see manage_providers:auto_detect_env_providers/1);
%%% a fallback named but not keyed is the same as none, and is logged once
%%% per failed call so the gap is visible.
%%%
%%% Only unary chat falls back. A stream has already committed to a
%%% provider by the time that provider fails mid-stream, and retrying the
%%% opening of a stream against a second provider is a different piece of
%%% work than this one.
-module(chat_to_llm).

-export([chat/2, chat/3, chat_stream/3]).
-export([fallback/0, retryable/1]).

%% Suppress dialyzer supertype warning (map() is intentionally general for API)
-dialyzer({nowarn_function, [chat/2, chat/3, record_telemetry/3]}).

-define(DEFAULT_FALLBACK_PROVIDER, <<"deepseek">>).
-define(DEFAULT_FALLBACK_MODEL, <<"deepseek-chat">>).

-spec chat(binary(), list()) -> {ok, map()} | {error, term()}.
chat(Model, Messages) ->
    chat(Model, Messages, #{}).

-spec chat(binary(), list(), map()) -> {ok, map()} | {error, term()}.
chat(Model, Messages, Opts) ->
    {Result, Provider} = primary(Model, Messages, Opts),
    settle(Result, Provider, Model, Messages, Opts).

%% @doc The configured fallback, or `none'.
-spec fallback() -> {binary(), binary()} | none.
fallback() ->
    fallback(env("HECATE_LLM_FALLBACK_PROVIDER", ?DEFAULT_FALLBACK_PROVIDER)).

fallback(<<"none">>) -> none;
fallback(<<>>)       -> none;
fallback(Provider)   -> {Provider, env("HECATE_LLM_FALLBACK_MODEL", ?DEFAULT_FALLBACK_MODEL)}.

%% @doc Whether a failure is the provider's rather than the request's.
%%
%% A 400 or 422 is the request itself being refused, and the same request
%% would be refused by the fallback too. Everything else -- a rate limit,
%% a 401 on a stale key, a 404 on a retired model id, a 5xx, a timeout, a
%% refused connection, a model this provider does not list -- is a reason
%% to ask someone else.
-spec retryable(term()) -> boolean().
retryable({http_error, Status, _Body}) -> Status =/= 400 andalso Status =/= 422;
retryable(_Reason)                     -> true.

%%% Internal: the primary attempt

primary(Model, Messages, Opts) ->
    case manage_providers:provider_for_model(Model) of
        {error, not_found} -> {{error, {unknown_model, Model}}, undefined};
        {Mod, Config}      -> {attempt(Mod, Config, Model, Messages, Opts),
                               maps:get(provider_name, Config, undefined)}
    end.

attempt(Mod, Config, Model, Messages, Opts) ->
    Result = Mod:chat(Config, Model, Messages, Opts),
    record_telemetry(Model, Result, Opts),
    Result.

%%% Internal: the fallback

settle({ok, _} = Ok, _Provider, _Model, _Messages, _Opts) ->
    Ok;
settle({error, Reason} = Err, Provider, Model, Messages, Opts) ->
    fall_back(retryable(Reason) andalso fallback(), Provider, Err, Model, Messages, Opts).

fall_back(false, _Provider, Err, _Model, _Messages, _Opts) ->
    Err;
fall_back(none, _Provider, Err, _Model, _Messages, _Opts) ->
    Err;
fall_back({Provider, _FallbackModel}, Provider, Err, Model, _Messages, _Opts) ->
    %% The failing provider IS the fallback: nothing else to try.
    logger:warning("[chat_to_llm] ~s failed on ~s (~s), which is the fallback provider itself",
                   [Model, Provider, brief(Err)]),
    Err;
fall_back({Fallback, FallbackModel}, _Provider, {error, Reason} = Err, Model, Messages, Opts) ->
    fall_back_via(manage_providers:get_provider(Fallback), Fallback, FallbackModel,
                  Reason, Err, Model, Messages, Opts).

fall_back_via({error, not_found}, Fallback, _FallbackModel, Reason, Err, Model, _Messages, _Opts) ->
    logger:warning("[chat_to_llm] ~s failed (~s); fallback provider ~s is not configured "
                   "(no API key detected)", [Model, brief(Reason), Fallback]),
    Err;
fall_back_via({ok, {Mod, Config}}, Fallback, FallbackModel, Reason, _Err, Model, Messages, Opts) ->
    logger:warning("[chat_to_llm] ~s failed (~s); falling back to ~s/~s",
                   [Model, brief(Reason), Fallback, FallbackModel]),
    served(attempt(Mod, Config, FallbackModel, Messages, Opts), Fallback, Model, Reason).

served({ok, Reply}, Fallback, Model, _Reason) ->
    {ok, Reply#{served_by => Fallback, requested_model => Model}};
served({error, FallbackReason}, Fallback, _Model, Reason) ->
    logger:warning("[chat_to_llm] fallback ~s failed too (~s)", [Fallback, brief(FallbackReason)]),
    {error, {fallback_failed, brief(Reason), brief(FallbackReason)}}.

%% A reason short enough to log and to put on the wire: a provider's
%% error body can be a page of HTML, and a 429 is the whole story.
brief({error, Reason})             -> brief(Reason);
brief({http_error, Status, _Body}) -> <<"http ", (integer_to_binary(Status))/binary>>;
brief({unknown_model, Model})      -> <<"unknown model ", Model/binary>>;
brief(Reason)                      -> iolist_to_binary(io_lib:format("~0p", [Reason])).

env(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        ""    -> Default;
        Value -> list_to_binary(Value)
    end.

%%% Internal: telemetry

record_telemetry(Model, {ok, Response}, Opts) ->
    TokensIn = maps:get(prompt_eval_count, Response,
                  maps:get(<<"prompt_eval_count">>, Response, 0)),
    TokensOut = maps:get(eval_count, Response,
                   maps:get(<<"eval_count">>, Response, 0)),
    maybe_record_telemetry(TokensIn + TokensOut, Model, TokensIn, TokensOut, Opts);
record_telemetry(_Model, _Error, _Opts) ->
    ok.

maybe_record_telemetry(0, _Model, _TokensIn, _TokensOut, _Opts) ->
    ok;
maybe_record_telemetry(_Total, Model, TokensIn, TokensOut, Opts) ->
    TelemetryData = #{
        model => Model,
        tokens_in => TokensIn,
        tokens_out => TokensOut,
        venture_id => maps:get(venture_id, Opts, <<"default">>),
        division_id => maps:get(division_id, Opts, undefined),
        agent_id => maps:get(agent_id, Opts, undefined),
        task_id => maps:get(task_id, Opts, undefined)
    },
    try
        llm_pricing:record_llm_call(TelemetryData)
    catch
        error:undef -> ok;
        _:_ -> ok
    end.

%% @doc Start a streaming chat completion. No fallback here: see the
%% moduledoc for why a stream commits to its provider.
-spec chat_stream(binary(), list(), map()) -> {ok, reference()} | {error, term()}.
chat_stream(Model, Messages, Opts) ->
    case manage_providers:provider_for_model(Model) of
        {error, not_found} -> {error, {unknown_model, Model}};
        {Mod, Config}      -> start_chat_stream(Mod, Config, Model, Messages, Opts)
    end.

start_chat_stream(Mod, Config, Model, Messages, Opts) ->
    Ref = make_ref(),
    Caller = self(),
    spawn_link(fun() -> Mod:chat_stream(Config, Model, Messages, Opts, Caller, Ref) end),
    {ok, Ref}.
