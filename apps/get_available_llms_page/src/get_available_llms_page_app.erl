-module(get_available_llms_page_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    get_available_llms_page_sup:start_link().

stop(_State) ->
    ok.
