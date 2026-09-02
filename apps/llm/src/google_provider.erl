%%% @doc Google Gemini LLM Provider
%%%
%%% Implements llm_provider behaviour for the Google Gemini (Generative AI) API.
%%% @end
-module(google_provider).
-behaviour(llm_provider).

-export([list_models/1, chat/4, chat_stream/6, health/1]).

%%% ===================================================================
%%% llm_provider callbacks
%%% ===================================================================

-spec list_models(map()) -> {ok, [map()]} | {error, term()}.
list_models(Config) ->
    Url = base_url(Config) ++ "/v1beta/models?key=" ++ api_key_str(Config),
    case hackney:get(Url, [], <<>>, [with_body]) of
        {ok, 200, _Headers, Body} ->
            #{<<"models">> := RawModels} = json:decode(Body),
            Models = lists:filtermap(fun normalize_model/1, RawModels),
            {ok, Models};
        {ok, Status, _Headers, RespBody} ->
            {error, {http_error, Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec chat(map(), binary(), list(), map()) -> {ok, map()} | {error, term()}.
chat(Config, Model, Messages, Opts) ->
    Url = base_url(Config) ++ "/v1beta/models/" ++ binary_to_list(Model)
        ++ ":generateContent?key=" ++ api_key_str(Config),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    {SystemInstruction, Contents} = extract_system(Messages),
    Body = json:encode(build_request(SystemInstruction, Contents, Opts)),
    case hackney:post(Url, Headers, Body, [with_body]) of
        {ok, 200, _RespHeaders, RespBody} ->
            Decoded = json:decode(RespBody),
            {ok, normalize_response(Decoded)};
        {ok, Status, _RespHeaders, RespBody} ->
            {error, {http_error, Status, RespBody}};
        {error, Reason} ->
            {error, Reason}
    end.

-spec chat_stream(map(), binary(), list(), map(), pid(), reference()) -> ok.
chat_stream(Config, Model, Messages, Opts, Caller, Ref) ->
    Url = base_url(Config) ++ "/v1beta/models/" ++ binary_to_list(Model)
        ++ ":streamGenerateContent?alt=sse&key=" ++ api_key_str(Config),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    {SystemInstruction, Contents} = extract_system(Messages),
    Body = json:encode(build_request(SystemInstruction, Contents, Opts)),
    case hackney:post(Url, Headers, Body, [async]) of
        {ok, ClientRef} ->
            stream_loop(ClientRef, Ref, Caller, <<>>);
        {error, Reason} ->
            Caller ! {llm_error, Ref, Reason}
    end,
    ok.

-spec health(map()) -> ok | {error, term()}.
health(Config) ->
    Url = base_url(Config) ++ "/v1beta/models?key=" ++ api_key_str(Config) ++ "&pageSize=1",
    case hackney:get(Url, [], <<>>, [with_body, {recv_timeout, 5000}]) of
        {ok, 200, _Headers, _Body} -> ok;
        {ok, 401, _Headers, _Body} -> {error, unauthorized};
        {ok, 403, _Headers, _Body} -> {error, forbidden};
        {ok, Status, _Headers, _Body} -> {error, {http_status, Status}};
        {error, Reason} -> {error, Reason}
    end.

%%% ===================================================================
%%% Internal
%%% ===================================================================

base_url(#{url := Url}) when is_list(Url) -> Url;
base_url(#{url := Url}) when is_binary(Url) -> binary_to_list(Url);
base_url(_) -> "https://generativelanguage.googleapis.com".

api_key_str(#{api_key := Key}) when is_binary(Key) -> binary_to_list(Key);
api_key_str(#{api_key := Key}) when is_list(Key) -> Key;
api_key_str(_) -> "".

%% Gemini uses a different message format: "contents" with "parts"
%% and system instructions are a separate top-level field.
extract_system(Messages) ->
    extract_system(Messages, undefined, []).

extract_system([], System, Acc) ->
    {System, lists:reverse(Acc)};
extract_system([#{role := <<"system">>} = M | Rest], _System, Acc) ->
    Content = maps:get(content, M, <<>>),
    extract_system(Rest, #{parts => [#{text => Content}]}, Acc);
extract_system([#{<<"role">> := <<"system">>} = M | Rest], _System, Acc) ->
    Content = maps:get(<<"content">>, M, <<>>),
    extract_system(Rest, #{parts => [#{text => Content}]}, Acc);
extract_system([M | Rest], System, Acc) ->
    Role = gemini_role(maps:get(role, M, maps:get(<<"role">>, M, <<"user">>))),
    Content = maps:get(content, M, maps:get(<<"content">>, M, <<>>)),
    extract_system(Rest, System, [#{role => Role, parts => [#{text => Content}]} | Acc]).

gemini_role(<<"assistant">>) -> <<"model">>;
gemini_role(Role) -> Role.

build_request(SystemInstruction, Contents, Opts) ->
    Base = #{contents => Contents},
    Base1 = case SystemInstruction of
        undefined -> Base;
        _ -> Base#{systemInstruction => SystemInstruction}
    end,
    %% Add tools if provided
    Base2 = case maps:get(tools, Opts, undefined) of
        undefined -> Base1;
        [] -> Base1;
        Tools when is_list(Tools) ->
            FunctionDecls = [tool_to_gemini_schema(T) || T <- Tools],
            %% Add toolConfig to allow tool use (AUTO mode)
            Base1#{
                tools => [#{functionDeclarations => FunctionDecls}],
                toolConfig => #{functionCallingConfig => #{mode => <<"AUTO">>}}
            }
    end,
    Config = build_generation_config(Opts),
    case maps:size(Config) of
        0 -> Base2;
        _ -> Base2#{generationConfig => Config}
    end.

%% @doc Convert tool definition to Gemini's function declaration format.
tool_to_gemini_schema(#{name := Name, description := Desc, input_schema := Schema}) ->
    #{
        name => Name,
        description => Desc,
        parameters => normalize_schema(Schema)
    };
tool_to_gemini_schema(#{<<"name">> := Name, <<"description">> := Desc, <<"input_schema">> := Schema}) ->
    #{
        name => Name,
        description => Desc,
        parameters => normalize_schema(Schema)
    }.

%% Normalize JSON schema for Gemini (type must be uppercase)
normalize_schema(Schema) when is_map(Schema) ->
    Schema1 = normalize_type(Schema),
    Schema2 = normalize_properties(Schema1),
    normalize_required(Schema2);
normalize_schema(Other) -> Other.

%% Convert type to uppercase (remove old key, add new)
normalize_type(Schema) ->
    apply_type(maps:get(<<"type">>, Schema, undefined), maps:get(type, Schema, undefined), Schema).

apply_type(undefined, undefined, Schema) ->
    Schema;
apply_type(undefined, Type, Schema) ->
    (maps:remove(type, Schema))#{type => string:uppercase(ensure_binary(Type))};
apply_type(BinType, _AtomType, Schema) ->
    (maps:remove(<<"type">>, Schema))#{type => string:uppercase(ensure_binary(BinType))}.

%% Recursively normalize properties
normalize_properties(Schema) ->
    apply_properties(maps:get(<<"properties">>, Schema, undefined), maps:get(properties, Schema, undefined), Schema).

apply_properties(undefined, undefined, Schema) ->
    Schema;
apply_properties(undefined, Props, Schema) when is_map(Props) ->
    (maps:remove(properties, Schema))#{properties => normalize_props_map(Props)};
apply_properties(BinProps, _AtomProps, Schema) when is_map(BinProps) ->
    (maps:remove(<<"properties">>, Schema))#{properties => normalize_props_map(BinProps)}.

normalize_props_map(Props) ->
    maps:map(fun(_K, V) -> normalize_schema(V) end, Props).

%% Also normalize required array
normalize_required(Schema) ->
    apply_required(maps:get(<<"required">>, Schema, undefined), maps:get(required, Schema, undefined), Schema).

apply_required(undefined, undefined, Schema) ->
    Schema;
apply_required(undefined, Req, Schema) ->
    (maps:remove(required, Schema))#{required => Req};
apply_required(BinReq, _AtomReq, Schema) ->
    (maps:remove(<<"required">>, Schema))#{required => BinReq}.

ensure_binary(B) when is_binary(B) -> B;
ensure_binary(L) when is_list(L) -> list_to_binary(L);
ensure_binary(A) when is_atom(A) -> atom_to_binary(A, utf8).

build_generation_config(Opts) ->
    Config = #{},
    Config1 = case maps:get(temperature, Opts, undefined) of
        undefined -> Config;
        Temp -> Config#{temperature => Temp}
    end,
    case maps:get(max_tokens, Opts, undefined) of
        undefined -> Config1;
        MaxTokens -> Config1#{maxOutputTokens => MaxTokens}
    end.

normalize_model(#{<<"name">> := FullName} = M) ->
    %% Model names come as "models/gemini-1.5-pro" — strip prefix
    Name = case binary:split(FullName, <<"/">>) of
        [_, ShortName] -> ShortName;
        _ -> FullName
    end,
    SupportedMethods = maps:get(<<"supportedGenerationMethods">>, M, []),
    CanGenerate = lists:member(<<"generateContent">>, SupportedMethods),
    case CanGenerate andalso is_useful_google_model(Name) of
        true ->
            InputLimit = maps:get(<<"inputTokenLimit">>, M, 0),
            OutputLimit = maps:get(<<"outputTokenLimit">>, M, 0),
            {true, #{
                name => Name,
                context_length => InputLimit + OutputLimit,
                family => <<"gemini">>,
                parameter_size => <<>>,
                format => <<"api">>
            }};
        false ->
            false
    end;
normalize_model(_) ->
    false.

%% Filter Google models to production chat models only.
%% Excludes: TTS, image-gen, robotics, computer-use, gemma (local models),
%% "latest" aliases (duplicates), previews with date suffixes, niche models.
is_useful_google_model(Name) ->
    not is_excluded_google_model(Name).

is_excluded_google_model(Name) ->
    lists:any(fun(Pattern) -> binary:match(Name, Pattern) =/= nomatch end, [
        <<"tts">>,
        <<"image">>,
        <<"robotics">>,
        <<"computer-use">>,
        <<"nano-banana">>,
        <<"deep-research">>,
        <<"customtools">>
    ])
    orelse is_gemma_model(Name)
    orelse is_latest_alias(Name)
    orelse is_dated_preview(Name).

is_gemma_model(<<"gemma", _/binary>>) -> true;
is_gemma_model(_) -> false.

is_latest_alias(Name) ->
    binary:match(Name, <<"-latest">>) =/= nomatch.

%% Exclude preview models with date suffixes like "preview-09-2025"
%% but keep simple "-preview" names like "gemini-3-pro-preview"
is_dated_preview(Name) ->
    case binary:match(Name, <<"preview-">>) of
        {Pos, Len} ->
            After = binary:part(Name, Pos + Len, byte_size(Name) - Pos - Len),
            %% If what follows starts with a digit, it's a dated preview
            starts_with_digit(After);
        nomatch ->
            false
    end.

starts_with_digit(<<C, _/binary>>) when C >= $0, C =< $9 -> true;
starts_with_digit(_) -> false.

normalize_response(#{<<"candidates">> := [Candidate | _]} = Resp) ->
    Content = maps:get(<<"content">>, Candidate, #{}),
    Parts = maps:get(<<"parts">>, Content, []),
    Text = extract_text(Parts),
    ToolCalls = extract_function_calls(Parts),
    Usage = maps:get(<<"usageMetadata">>, Resp, #{}),
    FinishReason = maps:get(<<"finishReason">>, Candidate, <<>>),
    BaseResp = #{
        content => Text,
        model => <<>>,
        done => true,
        stop_reason => FinishReason,
        eval_count => maps:get(<<"candidatesTokenCount">>, Usage, 0),
        prompt_eval_count => maps:get(<<"promptTokenCount">>, Usage, 0),
        message => #{role => <<"assistant">>, content => Text}
    },
    case ToolCalls of
        [] -> BaseResp;
        _ -> BaseResp#{tool_calls => ToolCalls}
    end;
normalize_response(Unexpected) ->
    logger:warning("[google_provider:normalize_response/1] unexpected response structure: ~p",
                   [Unexpected]),
    #{content => <<>>, done => true}.

extract_text([]) -> <<>>;
extract_text([#{<<"text">> := Text} | _]) -> Text;
extract_text([#{<<"functionCall">> := _} | Rest]) -> extract_text(Rest);
extract_text([_ | Rest]) -> extract_text(Rest).

%% Extract function calls from parts
extract_function_calls(Parts) ->
    lists:filtermap(fun extract_function_call/1, Parts).

extract_function_call(#{<<"functionCall">> := #{<<"name">> := Name, <<"args">> := Args}}) ->
    {true, #{
        id => generate_tool_id(),
        name => Name,
        arguments => Args
    }};
extract_function_call(#{<<"functionCall">> := #{<<"name">> := Name}}) ->
    {true, #{
        id => generate_tool_id(),
        name => Name,
        arguments => #{}
    }};
extract_function_call(_) ->
    false.

generate_tool_id() ->
    <<H:64, L:64>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("call_~16.16.0b~16.16.0b", [H, L])).

stream_loop(ClientRef, Ref, Caller, Buffer) ->
    receive
        {hackney_response, ClientRef, {status, 200, _}} ->
            stream_loop(ClientRef, Ref, Caller, Buffer);
        {hackney_response, ClientRef, {status, Status, _}} ->
            Caller ! {llm_error, Ref, {http_status, Status}},
            hackney:close(ClientRef);
        {hackney_response, ClientRef, {headers, _Headers}} ->
            stream_loop(ClientRef, Ref, Caller, Buffer);
        {hackney_response, ClientRef, done} ->
            Caller ! {llm_done, Ref};
        {hackney_response, ClientRef, Chunk} when is_binary(Chunk) ->
            handle_sse_chunk(Chunk, ClientRef, Ref, Caller, Buffer);
        {hackney_response, ClientRef, {error, Reason}} ->
            Caller ! {llm_error, Ref, Reason}
    after 120000 ->
        Caller ! {llm_error, Ref, timeout},
        hackney:close(ClientRef)
    end.

handle_sse_chunk(Chunk, ClientRef, Ref, Caller, Buffer) ->
    NewBuffer = <<Buffer/binary, Chunk/binary>>,
    {Events, Rest} = parse_sse(NewBuffer),
    lists:foreach(fun(EventData) ->
        process_sse_event(EventData, Ref, Caller)
    end, Events),
    stream_loop(ClientRef, Ref, Caller, Rest).

process_sse_event(Data, Ref, Caller) ->
    try json:decode(Data) of
        #{<<"candidates">> := [Candidate | _]} = Resp ->
            emit_gemini_chunk(Candidate, Resp, Ref, Caller);
        _ ->
            ok
    catch _:_ ->
        ok
    end.

emit_gemini_chunk(Candidate, Resp, Ref, Caller) ->
    Content = maps:get(<<"content">>, Candidate, #{}),
    Parts = maps:get(<<"parts">>, Content, []),
    Text = extract_text(Parts),
    ToolCalls = extract_function_calls(Parts),
    FinishReason = maps:get(<<"finishReason">>, Candidate, null),
    Done = FinishReason =/= null,
    %% Use binary keys to match what hecate_api_llm expects
    ChunkMap = #{<<"content">> => Text, <<"done">> => Done},
    ChunkMap1 = merge_gemini_tool_calls(ChunkMap, ToolCalls),
    ChunkMap2 = merge_gemini_finish_reason(ChunkMap1, Done, FinishReason),
    FinalChunk = merge_gemini_usage(ChunkMap2, Done, Resp),
    Caller ! {llm_chunk, Ref, FinalChunk}.

%% Add tool calls if present
merge_gemini_tool_calls(ChunkMap, [])        -> ChunkMap;
merge_gemini_tool_calls(ChunkMap, ToolCalls) -> ChunkMap#{<<"tool_calls">> => ToolCalls}.

%% Add stop reason if done
merge_gemini_finish_reason(ChunkMap1, true, FinishReason) when FinishReason =/= null ->
    ChunkMap1#{<<"stop_reason">> => FinishReason};
merge_gemini_finish_reason(ChunkMap1, _Done, _FinishReason) ->
    ChunkMap1.

merge_gemini_usage(ChunkMap2, false, _Resp) ->
    ChunkMap2;
merge_gemini_usage(ChunkMap2, true, Resp) ->
    Usage = maps:get(<<"usageMetadata">>, Resp, #{}),
    ChunkMap2#{
        <<"eval_count">> => maps:get(<<"candidatesTokenCount">>, Usage, 0),
        <<"prompt_eval_count">> => maps:get(<<"promptTokenCount">>, Usage, 0)
    }.

parse_sse(Buffer) ->
    Lines = binary:split(Buffer, <<"\n">>, [global]),
    parse_sse_lines(Lines, [], <<>>).

parse_sse_lines([], Acc, Rest) ->
    {lists:reverse(Acc), Rest};
parse_sse_lines([<<>>], Acc, _Rest) ->
    {lists:reverse(Acc), <<>>};
parse_sse_lines([Last], Acc, _Rest) ->
    {lists:reverse(Acc), Last};
parse_sse_lines([<<"data: ", Data/binary>> | Rest], Acc, _) ->
    parse_sse_lines(Rest, [Data | Acc], <<>>);
parse_sse_lines([<<>> | Rest], Acc, _) ->
    parse_sse_lines(Rest, Acc, <<>>);
parse_sse_lines([_Line | Rest], Acc, _) ->
    parse_sse_lines(Rest, Acc, <<>>).
