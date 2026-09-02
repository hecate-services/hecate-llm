%%% @doc API handler: GET /api/llm/providers
%%%
%%% List all configured LLM providers.
%%% @end
-module(get_providers_page_api).

-export([init/2, routes/0]).

routes() -> [{"/api/llm/providers", ?MODULE, []}].

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"GET">> -> handle_get(Req0, State);
        _ -> hecate_api_utils:method_not_allowed(Req0)
    end.

handle_get(Req0, _State) ->
    Providers = manage_providers:list(),
    %% Convert to JSON-safe format (atoms to binaries)
    JsonProviders = maps:map(fun(_Name, Config) -> json_safe_provider(Config) end, Providers),
    hecate_api_utils:json_ok(#{providers => JsonProviders}, Req0).

json_safe_provider(Config) ->
    Type = maps:get(type, Config, unknown),
    Base = #{
        type => atom_to_binary(Type, utf8),
        enabled => maps:get(enabled, Config, true)
    },
    maybe_add_url(Base, maps:get(url, Config, undefined)).

maybe_add_url(Base, undefined)              -> Base;
maybe_add_url(Base, Url) when is_list(Url)  -> Base#{url => list_to_binary(Url)};
maybe_add_url(Base, Url)                    -> Base#{url => Url}.
