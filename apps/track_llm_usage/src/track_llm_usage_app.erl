-module(track_llm_usage_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    track_llm_usage_sup:start_link().

stop(_State) ->
    ok.
