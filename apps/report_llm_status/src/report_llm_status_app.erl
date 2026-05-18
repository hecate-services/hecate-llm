-module(report_llm_status_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    report_llm_status_sup:start_link().

stop(_State) ->
    ok.
