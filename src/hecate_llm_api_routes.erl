%%% @doc Discovers Cowboy routes from umbrella apps.
-module(hecate_llm_api_routes).

-export([discover_routes/0]).

-define(LLM_APPS, [
    llm,
    chat_to_llm,
    manage_providers,
    check_llm_health,
    get_available_llms_page,
    track_llm_usage
]).

discover_routes() ->
    lists:flatmap(fun routes_for_app/1, ?LLM_APPS).

routes_for_app(App) ->
    case application:get_key(App, modules) of
        {ok, Modules} -> lists:flatmap(fun routes_for_module/1, Modules);
        undefined     -> []
    end.

routes_for_module(Mod) ->
    case erlang:function_exported(Mod, routes, 0) of
        true  -> safe_routes(Mod);
        false -> []
    end.

safe_routes(Mod) ->
    try Mod:routes() catch _:_ -> [] end.
