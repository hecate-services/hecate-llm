%%% @doc Macula RPC dispatch for hecate-llm.
%%%
%%% Registers every advertised unary capability with the SDK at boot
%%% via `macula:advertise/5`. Streaming capabilities (currently just
%%% `hecate-llm.stream_chat`) self-register from
%%% `stream_chat_with_llm:init/1` via `macula:advertise_stream/4`,
%%% so they're absent from this table.
%%%
%%% Degrades silently when no pool / no realm — gen_server stays up,
%%% local `dispatch/2` keeps working for tests + HTTP admin.
-module(hecate_llm_mesh_rpc).
-behaviour(gen_server).

-export([
    start_link/0,
    dispatch/2,
    handle_chat/1,
    handle_list_available/1,
    handle_check_health/1,
    handle_report_status/1,
    handle_track_usage/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec dispatch(binary(), map()) -> {ok, term()} | {error, term()}.
dispatch(Method, Params) ->
    gen_server:call(?MODULE, {dispatch, Method, Params}).

init([]) ->
    advertise_all(),
    {ok, #{}}.

handle_call({dispatch, Method, Params}, _From, S) ->
    {reply, route(Method, Params), S};
handle_call(_, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.

%%% Internal: register every unary capability with the SDK

advertise_all() ->
    case {hecate_om:macula_client(), hecate_om_identity:realm()} of
        {{ok, Pool}, {ok, Realm}} -> advertise_capabilities(Pool, Realm);
        _                         -> ok
    end.

advertise_capabilities(Pool, Realm) ->
    lists:foreach(fun(CapFun) -> advertise_one(Pool, Realm, CapFun) end, handler_table()).

advertise_one(Pool, Realm, {Cap, Fun}) ->
    try
        ok = macula:advertise(Pool, Realm, Cap, {?MODULE, Fun}, #{})
    catch _:_ -> ok
    end.

handler_table() ->
    [
        {<<"hecate-llm.chat">>,           handle_chat},
        {<<"hecate-llm.list_available">>, handle_list_available},
        {<<"hecate-llm.check_health">>,   handle_check_health},
        {<<"hecate-llm.report_status">>,  handle_report_status},
        {<<"hecate-llm.track_usage">>,    handle_track_usage}
    ].

%%% Internal: handler entry points (one per unary capability)

handle_chat(P)           -> route(<<"hecate-llm.chat">>, P).
handle_list_available(P) -> route(<<"hecate-llm.list_available">>, P).
handle_check_health(P)   -> route(<<"hecate-llm.check_health">>, P).
handle_report_status(P)  -> route(<<"hecate-llm.report_status">>, P).
handle_track_usage(P)    -> route(<<"hecate-llm.track_usage">>, P).

%%% Internal: method → slice handler

%% Every payload is folded to one shape before any clause looks at it.
%% macula's frame decoder atomizes a payload's keys through
%% binary_to_existing_atom/1 (so `<<"model">>' arrives as `model'), a
%% key whose atom does not exist arrives as `{text, <<"...">>}', and
%% every text VALUE arrives as `{text, Bin}' (see hecate_om_wire's
%% moduledoc for both gotchas). The clauses below used to match bare
%% binary keys only, which no real mesh caller ever produced: every
%% `hecate-llm.chat' call answered `missing_model_or_messages' from
%% the day the wire started tagging text, verified live 2026-09-03
%% from inside a spartan mind with binary AND atom keys.
%% hecate_om_wire:field/2,3 solves this for one top-level key; a chat
%% payload nests maps (messages, opts, tools), so the whole tree is
%% folded here instead and the binary-key matches stay honest.
route(Method, Params) when is_map(Params) ->
    serve(Method, wire_in(Params));
route(Method, _NotAMap) ->
    serve(Method, #{}).

serve(<<"hecate-llm.chat">>, #{<<"model">> := Model, <<"messages">> := Messages} = P) ->
    chat_to_llm:chat(Model, Messages, chat_opts(P));
serve(<<"hecate-llm.chat">>, _P) ->
    {error, missing_model_or_messages};

serve(<<"hecate-llm.list_available">>, _P) ->
    %% `list/0' already answers `{ok, Models}'; wrapping that in another
    %% `{ok, _}' put a bare tuple on the wire, which macula_frame refuses
    %% ("tuple at payload cannot be encoded") and the whole call faulted.
    case erlang:function_exported(get_available_llms_page, list, 0) of
        true  -> wire_safe_models(get_available_llms_page:list());
        false -> {error, not_implemented}
    end;

serve(<<"hecate-llm.check_health">>, _P) ->
    case erlang:function_exported(check_llm_health, check_all, 0) of
        true  -> {ok, wire_safe_health(check_llm_health:check_all())};
        false -> {error, not_implemented}
    end;

serve(<<"hecate-llm.report_status">>, _P) ->
    %% report_llm_status is a gen_server; whatever introspection
    %% function we expose lands here. Today: stub.
    {ok, #{status => <<"todo">>}};

serve(<<"hecate-llm.track_usage">>, P) ->
    case track_llm_call_v1:from_map(P) of
        {ok, Cmd}      -> dispatch_track_usage(Cmd);
        {error, _} = E -> E
    end;

serve(Other, _P) ->
    {error, {unknown_method, Other}}.

%% The provider modules read their options atom-keyed (`temperature',
%% `max_tokens', `tools' -- see openai_provider:build_request/4). A
%% caller may put them under `opts' or beside `model' at the top level,
%% and after wire_in/1 both arrive binary-keyed; this is the one place
%% they are translated.
chat_opts(P) ->
    Nested = maps:get(<<"opts">>, P, #{}),
    lists:foldl(fun(Key, Acc) -> chat_opt(Key, P, Nested, Acc) end, #{},
                [temperature, max_tokens, tools]).

chat_opt(Key, P, Nested, Acc) ->
    Bin = atom_to_binary(Key, utf8),
    case maps:get(Bin, Nested, maps:get(Bin, P, undefined)) of
        undefined -> Acc;
        Value     -> Acc#{Key => Value}
    end.

wire_in(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) -> Acc#{wire_key(K) => wire_in(V)} end, #{}, Map);
wire_in(List) when is_list(List) ->
    [wire_in(V) || V <- List];
wire_in(Value) ->
    hecate_om_wire:unwrap(Value).

wire_key({text, Bin}) when is_binary(Bin) -> Bin;
wire_key(Atom) when is_atom(Atom)          -> atom_to_binary(Atom, utf8);
wire_key(Other)                            -> Other.

wire_safe_models({ok, Models}) when is_list(Models) ->
    {ok, [maps:map(fun(_K, V) -> wire_safe_value(V) end, M) || M <- Models, is_map(M)]};
wire_safe_models({error, _} = Err) ->
    Err.

wire_safe_value(V) when is_binary(V); is_integer(V); is_float(V); is_atom(V) -> V;
wire_safe_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).

dispatch_track_usage(Cmd) ->
    case maybe_track_llm_call:dispatch(Cmd) of
        ok                  -> {ok, #{status => accepted}};
        {ok, Result}        -> {ok, Result};
        {error, _} = E      -> E
    end.

%% check_llm_health:check_all/0's own contract is `ok | {error, term()}'
%% per provider (see llm_provider:health/1's `-callback') -- a fine
%% internal shape, but `{error, Reason}' is a bare 2-tuple, which
%% macula_frame:check_value/2 rejects outright ("tuple at ... cannot be
%% encoded"), whatever Reason is. Every provider's health check faults
%% the whole call the moment one of them (ollama, always present per
%% manage_providers' own default) is down, which it always is in this
%% deploy. Normalize to the same status/reason map shape
%% hecate_om_health_handler already uses.
wire_safe_health(Results) ->
    maps:map(fun(_Name, Status) -> wire_safe_status(Status) end, Results).

wire_safe_status(ok) ->
    <<"ok">>;
wire_safe_status({error, Reason}) ->
    #{status => <<"error">>,
      reason => iolist_to_binary(io_lib:format("~p", [Reason]))}.
