-module(chat_to_llm_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    chat_to_llm_sup:start_link().

stop(_State) ->
    ok.
