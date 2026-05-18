-module(detect_llms_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => detect_llms,
          start => {detect_llms, start_link, []},
          restart => permanent, shutdown => 5000,
          type => worker, modules => [detect_llms]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}}.
