%%% @doc Public facade for hecate-llm (admin / introspection only).
-module(hecate_llm).

-export([info/0, health/0, capabilities/0]).

info() -> hecate_llm_service:info().
health() -> hecate_om:health().
capabilities() -> hecate_llm_service:capabilities().
