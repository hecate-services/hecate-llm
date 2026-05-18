%%% @doc hecate-llm OTP application entry.
-module(hecate_llm_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    hecate_om:boot(hecate_llm_service).

stop(_State) ->
    ok.
