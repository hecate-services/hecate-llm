%%% @doc Smoke tests for hecate-llm.
-module(hecate_llm_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([service_info/1, capabilities_count/1, mesh_rpc_unknown/1, chat_missing_fields/1]).

all() ->
    [service_info, capabilities_count, mesh_rpc_unknown, chat_missing_fields].

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
