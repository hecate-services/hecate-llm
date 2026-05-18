-module(manage_providers_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    manage_providers_sup:start_link().

stop(_State) ->
    ok.
