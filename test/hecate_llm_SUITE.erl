%%% @doc Smoke tests for hecate-llm.
-module(hecate_llm_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([service_info/1, capabilities_count/1, mesh_rpc_unknown/1, chat_missing_fields/1,
         check_health_wire_safe/1]).

all() ->
    [service_info, capabilities_count, mesh_rpc_unknown, chat_missing_fields,
     check_health_wire_safe].

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
