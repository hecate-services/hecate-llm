-module(report_llm_status_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => report_llm_status,
          start => {report_llm_status, start_link, []},
          restart => permanent, shutdown => 5000,
          type => worker, modules => [report_llm_status]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}}.
