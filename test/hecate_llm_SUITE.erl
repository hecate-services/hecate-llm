%%% @doc Smoke tests for hecate-llm.
-module(hecate_llm_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([service_info/1, capabilities_count/1, mesh_rpc_unknown/1, chat_missing_fields/1,
         chat_reads_wire_shaped_payloads/1, list_available_is_wire_safe/1,
         check_health_wire_safe/1, retryable_is_about_the_provider_not_the_request/1,
         chat_falls_back_when_the_primary_is_rate_limited/1,
         chat_without_a_fallback_returns_the_primary_failure/1]).

all() ->
    [service_info, capabilities_count, mesh_rpc_unknown, chat_missing_fields,
     chat_reads_wire_shaped_payloads, list_available_is_wire_safe,
     check_health_wire_safe, retryable_is_about_the_provider_not_the_request,
     chat_falls_back_when_the_primary_is_rate_limited,
     chat_without_a_fallback_returns_the_primary_failure].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(hecate_llm),
    Config.

end_per_suite(_Config) ->
    application:stop(hecate_llm),
    ok.

service_info(_Config) ->
    Info = hecate_llm_service:info(),
    ?assertEqual(<<"hecate-llm">>, maps:get(name, Info)).

capabilities_count(_Config) ->
    Caps = hecate_llm_service:capabilities(),
    ?assertEqual(6, length(Caps)).

mesh_rpc_unknown(_Config) ->
    ?assertMatch({error, {unknown_method, _}},
                 hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.no_such">>, #{})).

chat_missing_fields(_Config) ->
    %% chat() needs both `model' and `messages'; an empty params map
    %% should be rejected at the dispatch layer.
    ?assertMatch({error, missing_model_or_messages},
                 hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.chat">>, #{})).

%% What a real mesh caller's payload looks like once macula has decoded
%% it: keys atomized where the atom exists, `{text, _}' where it does
%% not, and every text value wrapped as `{text, Bin}'. Before 2026-09-03
%% all three shapes answered `missing_model_or_messages', so no mesh
%% caller had ever reached a provider through this gateway. With no
%% provider keyed in this VM the model cannot resolve, which is the
%% proof that the fields were read: the error names the model.
chat_reads_wire_shaped_payloads(_Config) ->
    Messages = [#{role => {text, <<"user">>}, content => {text, <<"hi">>}}],
    Atomized = #{model => {text, <<"nomodel">>}, messages => Messages},
    ?assertEqual({error, {unknown_model, <<"nomodel">>}},
                 hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.chat">>, Atomized)),
    Texted = #{{text, <<"model">>} => {text, <<"nomodel">>},
               {text, <<"messages">>} => [#{{text, <<"role">>} => {text, <<"user">>},
                                            {text, <<"content">>} => {text, <<"hi">>}}]},
    ?assertEqual({error, {unknown_model, <<"nomodel">>}},
                 hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.chat">>, Texted)),
    Binary = #{<<"model">> => <<"nomodel">>,
               <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertEqual({error, {unknown_model, <<"nomodel">>}},
                 hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.chat">>, Binary)).

%% `list/0' answers `{ok, Models}' itself; the route used to wrap that in
%% a second `{ok, _}', a bare tuple macula_frame refuses to encode, so
%% every `hecate-llm.list_available' call faulted on the wire.
list_available_is_wire_safe(_Config) ->
    {module, get_available_llms_page} = code:ensure_loaded(get_available_llms_page),
    {ok, Models} = hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.list_available">>, #{}),
    ?assert(is_list(Models)),
    lists:foreach(fun(M) -> ?assert(is_map(M)), assert_no_tuple(M) end, Models).

assert_no_tuple(Map) when is_map(Map) ->
    maps:foreach(fun(_K, V) -> assert_no_tuple(V) end, Map);
assert_no_tuple(List) when is_list(List) ->
    lists:foreach(fun assert_no_tuple/1, List);
assert_no_tuple(Value) ->
    ?assert(not is_tuple(Value)).

check_health_wire_safe(_Config) ->
    %% ollama is always present (manage_providers' own default) and
    %% never running in this test env, so check_llm_health:check_all/0
    %% is guaranteed to return at least one real `{error, Reason}' here
    %% -- exactly the shape macula_frame:check_value/2 rejects as an
    %% unencodable tuple. Regression test for that live mesh failure:
    %% every value dispatch/2 returns for check_health must be wire-safe
    %% (no tuple, anywhere), not just well-typed Erlang.
    %%
    %% `route/2' gates on erlang:function_exported/3, which requires
    %% the module already loaded -- true in the real release (`-mode
    %% embedded' preloads everything, confirmed in Containerfile/logs)
    %% but not guaranteed in a fresh `rebar3 ct' VM if nothing else in
    %% the suite happens to touch check_llm_health first.
    {module, check_llm_health} = code:ensure_loaded(check_llm_health),
    {ok, Results} = hecate_llm_mesh_rpc:dispatch(<<"hecate-llm.check_health">>, #{}),
    ?assert(maps:is_key(<<"ollama">>, Results)),
    maps:foreach(fun(_Name, Status) -> ?assert(not is_tuple(Status)) end, Results).

retryable_is_about_the_provider_not_the_request(_Config) ->
    ?assert(chat_to_llm:retryable({http_error, 429, <<"Too Many Requests">>})),
    ?assert(chat_to_llm:retryable({http_error, 401, <<>>})),
    ?assert(chat_to_llm:retryable({http_error, 404, <<>>})),
    ?assert(chat_to_llm:retryable({http_error, 503, <<>>})),
    ?assert(chat_to_llm:retryable(timeout)),
    ?assert(chat_to_llm:retryable(econnrefused)),
    ?assert(chat_to_llm:retryable({unknown_model, <<"m">>})),
    ?assertNot(chat_to_llm:retryable({http_error, 400, <<"bad request">>})),
    ?assertNot(chat_to_llm:retryable({http_error, 422, <<"unprocessable">>})).

%% The live failure of 2026-09-02, replayed against a fake: the primary
%% lists the model and then answers 429 to the call, the fallback answers.
%% The reply says who served it and what was asked for, and the fake
%% reports the order in which it was asked.
chat_falls_back_when_the_primary_is_rate_limited(_Config) ->
    with_fake_providers(fun() ->
        os:putenv("HECATE_LLM_FALLBACK_PROVIDER", "alive"),
        os:putenv("HECATE_LLM_FALLBACK_MODEL", "deepseek-chat"),
        Reply = chat_to_llm:chat(<<"kimi">>, [#{role => <<"user">>, content => <<"ping">>}]),
        ?assertMatch({ok, #{content := <<"pong">>, served_by := <<"alive">>,
                            requested_model := <<"kimi">>, model := <<"deepseek-chat">>}},
                     Reply),
        ?assertEqual([{<<"/dead/v1/chat/completions">>, <<"kimi">>},
                      {<<"/alive/v1/chat/completions">>, <<"deepseek-chat">>}],
                     completions_asked())
    end).

chat_without_a_fallback_returns_the_primary_failure(_Config) ->
    with_fake_providers(fun() ->
        os:putenv("HECATE_LLM_FALLBACK_PROVIDER", "none"),
        ?assertMatch({error, {http_error, 429, _}},
                     chat_to_llm:chat(<<"kimi">>, [#{role => <<"user">>, content => <<"ping">>}])),
        ?assertEqual([{<<"/dead/v1/chat/completions">>, <<"kimi">>}], completions_asked())
    end).

%%% Fixture: two OpenAI-compatible providers on one local listener

with_fake_providers(Fun) ->
    Dispatch = cowboy_router:compile([{'_', [{"/[...]", fake_openai_h, #{report_to => self()}}]}]),
    {ok, _} = cowboy:start_clear(fake_openai, [{ip, {127, 0, 0, 1}}, {port, 0}],
                                 #{env => #{dispatch => Dispatch}}),
    Base = "http://127.0.0.1:" ++ integer_to_list(ranch:get_port(fake_openai)),
    ok = manage_providers:add(<<"dead">>, openai, #{url => Base ++ "/dead", api_key => <<"k">>}),
    ok = manage_providers:add(<<"alive">>, openai, #{url => Base ++ "/alive", api_key => <<"k">>}),
    try
        Fun()
    after
        os:unsetenv("HECATE_LLM_FALLBACK_PROVIDER"),
        os:unsetenv("HECATE_LLM_FALLBACK_MODEL"),
        manage_providers:remove(<<"dead">>),
        manage_providers:remove(<<"alive">>),
        cowboy:stop_listener(fake_openai)
    end.

%% Only the completions, in order; the model listings that built the
%% cache are not what these tests are about.
completions_asked() ->
    completions_asked([]).

completions_asked(Acc) ->
    receive
        {asked, Path, Model} ->
            completions_asked(keep_completion(Path, Model, Acc))
    after 0 ->
        lists:reverse(Acc)
    end.

keep_completion(<<"/dead/v1/chat/completions">> = P, M, Acc) -> [{P, M} | Acc];
keep_completion(<<"/alive/v1/chat/completions">> = P, M, Acc) -> [{P, M} | Acc];
keep_completion(_Listing, _M, Acc) -> Acc.
