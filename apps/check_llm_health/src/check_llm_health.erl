%%% @doc Check LLM Health
%%% Checks health of all configured providers.
-module(check_llm_health).

-export([check/0, check_all/0]).

%% @doc Check health of all providers. Returns ok if any provider is healthy.
-spec check() -> ok | {error, term()}.
check() ->
    case has_any_healthy(check_all()) of
        true  -> ok;
        false -> {error, all_providers_unhealthy}
    end.

has_any_healthy(Results) ->
    maps:fold(fun(_Name, Status, Acc) -> Acc orelse (Status =:= ok) end, false, Results).

%% @doc Check health of each provider, returns per-provider status map.
-spec check_all() -> #{binary() => ok | {error, term()}}.
check_all() ->
    Providers = manage_providers:list(),
    maps:fold(fun(Name, Config, Acc) -> Acc#{Name => provider_status(Config)} end, #{}, Providers).

provider_status(#{type := Type} = Config) ->
    case maps:get(enabled, Config, true) of
        true  -> (llm_provider:provider_module(Type)):health(Config);
        false -> {error, disabled}
    end.
