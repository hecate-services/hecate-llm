-module(check_llm_health_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    check_llm_health_sup:start_link().

stop(_State) ->
    ok.
