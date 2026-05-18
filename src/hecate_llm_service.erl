%%% @doc Llm — implements the hecate_om_service behaviour.
-module(hecate_llm_service).
-behaviour(hecate_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{
        name        => <<"hecate-llm">>,
        version     => <<"0.1.0">>,
        description => <<"Realm-bound LLM serving over the mesh (Anthropic/OpenAI/Google/Ollama)">>
    }.

start(_Opts) ->
    hecate_llm_sup:start_link().

stop(_State) ->
    ok.

health() ->
    %% TODO: replace with a real health probe of the service.
    ok.

capabilities() ->
    %% TODO: list capabilities this service exposes on the mesh.
    [].

identity_spec() ->
    #{
        scope     => <<"hecate-llm">>,
        actions   => [<<"publish_summary">>, <<"answer_query">>],
        resources => [<<"hecate-llm/*">>],
        ttl_days  => 30
    }.
