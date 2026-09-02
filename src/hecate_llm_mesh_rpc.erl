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
        {{ok, Pool}, {ok, Realm}} ->
            lists:foreach(
                fun({Cap, Fun}) ->
                    try
                        ok = macula:advertise(Pool, Realm, Cap,
                                              {?MODULE, Fun}, #{})
                    catch _:_ -> ok
                    end
                end,
                handler_table()
            );
        _ ->
            ok
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

route(<<"hecate-llm.chat">>, #{<<"model">> := Model, <<"messages">> := Messages} = P) ->
    Opts = maps:get(<<"opts">>, P, #{}),
    case chat_to_llm:chat(Model, Messages, Opts) of
        {ok, Reply}        -> {ok, Reply};
        {error, _} = Err   -> Err
    end;
route(<<"hecate-llm.chat">>, _P) ->
    {error, missing_model_or_messages};

route(<<"hecate-llm.list_available">>, _P) ->
    %% Returns the list of detected models. `list/0' is stateless +
    %% reads from the manage_providers / detect_llms ETS table.
    case erlang:function_exported(get_available_llms_page, list, 0) of
        true  -> {ok, get_available_llms_page:list()};
        false -> {error, not_implemented}
    end;

route(<<"hecate-llm.check_health">>, _P) ->
    case erlang:function_exported(check_llm_health, check_all, 0) of
        true  -> {ok, wire_safe_health(check_llm_health:check_all())};
        false -> {error, not_implemented}
    end;

route(<<"hecate-llm.report_status">>, _P) ->
    %% report_llm_status is a gen_server; whatever introspection
    %% function we expose lands here. Today: stub.
    {ok, #{status => <<"todo">>}};

route(<<"hecate-llm.track_usage">>, P) ->
    case track_llm_call_v1:from_map(P) of
        {ok, Cmd} ->
            case maybe_track_llm_call:dispatch(Cmd) of
                ok                  -> {ok, #{status => accepted}};
                {ok, Result}        -> {ok, Result};
                {error, _} = E      -> E
            end;
        {error, _} = E -> E
    end;

route(Other, _P) ->
    {error, {unknown_method, Other}}.

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
