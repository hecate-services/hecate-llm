-module(track_llm_usage_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% llm_usage_state is an evoq_state, instantiated per-aggregate
    %% rather than supervised as a singleton.
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
