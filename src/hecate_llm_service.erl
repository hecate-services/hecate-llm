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
    %% Bare discovery records (no `handler' key): these 5 unary methods are
    %% actually served by hecate_llm_mesh_rpc's own macula:advertise/5 calls,
    %% and hecate-llm.stream_chat by stream_chat_with_llm's
    %% macula:advertise_stream/4 -- both predate, and stay outside, the
    %% handler-based macula_response:advertise_direct/7 path this callback
    %% would otherwise trigger. See hecate_om_service's own capability() doc.
    [
        #{name => <<"hecate-llm.chat">>,           version => 1},
        #{name => <<"hecate-llm.stream_chat">>,    version => 1},
        #{name => <<"hecate-llm.list_available">>, version => 1},
        #{name => <<"hecate-llm.check_health">>,   version => 1},
        #{name => <<"hecate-llm.report_status">>,  version => 1},
        #{name => <<"hecate-llm.track_usage">>,    version => 1}
    ].

identity_spec() ->
    #{
        scope     => <<"hecate-llm">>,
        actions   => [<<"publish_summary">>, <<"answer_query">>],
        resources => [<<"hecate-llm/*">>],
        ttl_days  => 30
    }.
