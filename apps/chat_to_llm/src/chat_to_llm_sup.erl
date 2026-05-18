-module(chat_to_llm_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% chat_to_llm.erl is stateless — no children. The dispatch lives
    %% in hecate_llm_mesh_rpc which calls chat_to_llm:chat/3 directly.
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
