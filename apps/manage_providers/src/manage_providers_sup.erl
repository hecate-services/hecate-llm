-module(manage_providers_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => manage_providers,
          start => {manage_providers, start_link, []},
          restart => permanent, shutdown => 5000,
          type => worker, modules => [manage_providers]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}}.
