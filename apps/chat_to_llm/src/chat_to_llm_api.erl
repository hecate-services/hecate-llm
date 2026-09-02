%%% @doc Chat to LLM API handler.
%%%
%%% Handles POST /api/llm/chat requests with full streaming SSE and
%%% tool call support.
%%%
%%% Request body:
%%%   - model (required): Model name
%%%   - messages (required): List of chat messages
%%%   - stream (optional): true for SSE streaming, false for sync
%%%   - temperature (optional): Temperature for generation
%%%   - max_tokens (optional): Maximum tokens to generate
%%%   - tools (optional): List of tool definitions for function calling
%%%
%%% Response (sync):
%%%   {ok: true, response: {...}}
%%%
%%% Response (streaming):
%%%   SSE events with data: {...} chunks, ending with data: [DONE]
%%%
%%% @end
-module(chat_to_llm_api).

-export([init/2, routes/0]).

routes() -> [{"/api/llm/chat", ?MODULE, []}].

%%% ===================================================================
%%% Cowboy Handler
%%% ===================================================================

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            handle_chat(Req0, State);
        _ ->
            hecate_api_utils:method_not_allowed(Req0)
    end.

%%% ===================================================================
%%% Chat Handler
%%% ===================================================================

handle_chat(Req0, State) ->
    case hecate_api_utils:read_json_body(Req0) of
        {ok, Params, Req1}       -> handle_parsed_chat(Params, Req1, State);
        {error, invalid_json, Req1} -> hecate_api_utils:bad_request(<<"Invalid JSON">>, Req1)
    end.

handle_parsed_chat(Params, Req1, State) ->
    Model = maps:get(<<"model">>, Params, undefined),
    Messages = maps:get(<<"messages">>, Params, []),
    Stream = maps:get(<<"stream">>, Params, false),
    dispatch_chat(validate_chat_params(Model, Messages), Stream, Req1, Model, Messages, Params, State).

dispatch_chat(ok, true, Req1, Model, Messages, Params, State) ->
    handle_streaming_chat(Req1, Model, Messages, Params, State);
dispatch_chat(ok, _Stream, Req1, Model, Messages, Params, State) ->
    handle_sync_chat(Req1, Model, Messages, Params, State);
dispatch_chat({error, Reason}, _Stream, Req1, _Model, _Messages, _Params, _State) ->
    hecate_api_utils:bad_request(Reason, Req1).

%%% ===================================================================
%%% Sync Chat
%%% ===================================================================

handle_sync_chat(Req0, Model, Messages, Params, _State) ->
    Opts = build_chat_opts(Model, Params),
    FormattedMessages = format_messages(Messages),
    TranslateSchema = maps:get(<<"translate_schema">>, Params, undefined),

    case chat_to_llm:chat(Model, FormattedMessages, Opts) of
        {ok, Response} ->
            maybe_translate_response(Response, TranslateSchema, Req0);
        {error, {unknown_model, _}} ->
            hecate_api_utils:json_error(404, <<"Model not found in any provider">>, Req0);
        {error, {http_error, 429, _Body}} ->
            hecate_api_utils:json_error(429, <<"Rate limit exceeded — provider quota exhausted">>, Req0);
        {error, {http_error, 401, _Body}} ->
            hecate_api_utils:json_error(401, <<"Authentication failed — check API key">>, Req0);
        {error, {http_error, 403, _Body}} ->
            hecate_api_utils:json_error(403, <<"Access denied by provider">>, Req0);
        {error, {http_error, Code, _Body}} when Code >= 500 ->
            hecate_api_utils:json_error(503, <<"LLM backend unavailable">>, Req0);
        {error, {http_error, Code, _Body}} ->
            Msg = iolist_to_binary(io_lib:format("Provider returned HTTP ~B", [Code])),
            hecate_api_utils:json_error(502, Msg, Req0);
        {error, Reason} ->
            hecate_api_utils:json_error(500, Reason, Req0)
    end.

%%% ===================================================================
%%% Streaming Chat
%%% ===================================================================

handle_streaming_chat(Req0, Model, Messages, Params, _State) ->
    Opts = build_chat_opts(Model, Params),
    FormattedMessages = format_messages(Messages),

    case chat_to_llm:chat_stream(Model, FormattedMessages, Opts) of
        {ok, Ref} ->
            Req1 = cowboy_req:stream_reply(200, #{
                <<"content-type">> => <<"text/event-stream">>,
                <<"cache-control">> => <<"no-cache">>,
                <<"connection">> => <<"keep-alive">>
            }, Req0),
            stream_chunks(Req1, Ref);
        {error, {unknown_model, _}} ->
            hecate_api_utils:json_error(404, <<"Model not found in any provider">>, Req0);
        {error, Reason} ->
            hecate_api_utils:json_error(500, Reason, Req0)
    end.

%%% ===================================================================
%%% Stream Chunk Processing
%%% ===================================================================

stream_chunks(Req, Ref) ->
    stream_chunks(Req, Ref, #{}).

stream_chunks(Req, Ref, State) ->
    receive
        {llm_chunk, Ref, Chunk} ->
            handle_llm_chunk(Chunk, Ref, Req, State);

        %% Tool use start (Anthropic streaming)
        {llm_tool_use_start, Ref, ToolInfo} ->
            %% Start accumulating tool input
            Id = maps:get(id, ToolInfo, <<>>),
            Name = maps:get(name, ToolInfo, <<>>),
            NewState = State#{current_tool => #{id => Id, name => Name, input => <<>>}},
            stream_chunks(Req, Ref, NewState);

        %% Tool input delta (Anthropic streaming)
        {llm_tool_input_delta, Ref, PartialJson} ->
            %% Accumulate JSON input
            CurrentTool = maps:get(current_tool, State, #{input => <<>>}),
            CurrentInput = maps:get(input, CurrentTool, <<>>),
            NewInput = <<CurrentInput/binary, PartialJson/binary>>,
            NewTool = CurrentTool#{input => NewInput},
            NewState = State#{current_tool => NewTool},
            stream_chunks(Req, Ref, NewState);

        %% Content block stop (Anthropic streaming)
        {llm_content_block_stop, Ref} ->
            %% If we have a current tool, emit it as a complete tool_use
            emit_pending_tool_use(maps:get(current_tool, State, undefined), Req, Ref, State);

        {llm_done, Ref} ->
            cowboy_req:stream_body(<<"data: [DONE]\n\n">>, fin, Req),
            {ok, Req, []};

        {llm_error, Ref, Reason} ->
            ErrorData = iolist_to_binary(json:encode(#{error => hecate_api_utils:format_error(Reason)})),
            cowboy_req:stream_body(<<"data: ", ErrorData/binary, "\n\n">>, fin, Req),
            {ok, Req, []}

    after 300000 ->
        %% 5-minute timeout for model loading (matches provider recv_timeout)
        ErrorData = iolist_to_binary(json:encode(#{error => <<"Timeout waiting for LLM response">>})),
        cowboy_req:stream_body(<<"data: ", ErrorData/binary, "\n\n">>, fin, Req),
        {ok, Req, []}
    end.

%%% ===================================================================
%%% Helpers
%%% ===================================================================

%% @doc Handle one streamed LLM chunk: build the SSE event, send it, and
%% recurse with updated accumulator state.
handle_llm_chunk(Chunk, Ref, Req, State) ->
    Content = chunk_content(Chunk),
    Done = maps:get(<<"done">>, Chunk, false),
    StopReason = maps:get(<<"done_reason">>, Chunk, maps:get(<<"stop_reason">>, Chunk, undefined)),
    NewState = accumulate_deltas(Chunk, State),
    {Event, FinalState} = done_event(Done, Content, NewState),
    Event1 = merge_complete_tool_calls(Event, Chunk, Content),
    Event2 = merge_stop_reason(Event1, StopReason),
    EventWithUsage = merge_usage(Event2, Chunk, Done),
    send_event(Req, EventWithUsage),
    maybe_send_followup_done(Done, Event, Chunk, Req, FinalState, Ref).

%% Ollama puts content inside "message", OpenAI at top level.
chunk_content(Chunk) ->
    case maps:get(<<"message">>, Chunk, undefined) of
        #{<<"content">> := C} -> C;
        _ -> maps:get(<<"content">>, Chunk, <<>>)
    end.

%% Accumulate OpenAI/Groq tool_call_deltas into State.
accumulate_deltas(Chunk, State) ->
    case maps:get(<<"tool_call_deltas">>, Chunk, undefined) of
        undefined -> State;
        Deltas when is_list(Deltas) -> lists:foldl(fun accumulate_tool_delta/2, State, Deltas)
    end.

%% On Done with accumulated tool calls, emit them.
done_event(false, Content, State) ->
    {#{content => Content, done => false}, State};
done_event(true, Content, State) ->
    PendingCalls = maps:get(pending_tool_calls, State, #{}),
    build_done_event(maps:size(PendingCalls), PendingCalls, Content, State).

build_done_event(0, _PendingCalls, Content, State) ->
    {#{content => Content, done => true}, State};
build_done_event(_Count, PendingCalls, Content, State) ->
    %% Build complete tool calls from accumulated deltas
    ToolCalls = build_pending_tool_calls(PendingCalls),
    Msg = #{role => <<"assistant">>, content => Content, tool_calls => ToolCalls},
    {#{content => Content, done => false, message => Msg},
     maps:remove(pending_tool_calls, State)}.

%% Handle complete tool calls in chunk (Ollama sends all at once).
merge_complete_tool_calls(Event, Chunk, Content) ->
    case maps:get(<<"tool_calls">>, Chunk, undefined) of
        undefined -> Event;
        ToolCalls2 when is_list(ToolCalls2) ->
            Msg2 = #{
                role => <<"assistant">>,
                content => Content,
                tool_calls => [format_tool_call(TC) || TC <- ToolCalls2]
            },
            Event#{message => Msg2}
    end.

merge_stop_reason(Event, undefined) -> Event;
merge_stop_reason(Event, null) -> Event;
merge_stop_reason(Event, Reason) -> Event#{stop_reason => Reason}.

merge_usage(Event, _Chunk, false) -> Event;
merge_usage(Event, Chunk, true) -> Event#{model => maps:get(<<"model">>, Chunk, <<>>), usage => usage_from_chunk(Chunk)}.

usage_from_chunk(Chunk) ->
    #{
        prompt_tokens => maps:get(<<"prompt_eval_count">>, Chunk, 0),
        completion_tokens => maps:get(<<"eval_count">>, Chunk, 0)
    }.

send_event(Req, Event) ->
    Data = iolist_to_binary(json:encode(Event)),
    cowboy_req:stream_body(<<"data: ", Data/binary, "\n\n">>, nofin, Req).

%% If we emitted accumulated tool calls, send a follow-up done event.
maybe_send_followup_done(true, Event, Chunk, Req, FinalState, Ref) ->
    send_followup_done(maps:is_key(message, Event), Chunk, Req, FinalState, Ref);
maybe_send_followup_done(false, _Event, _Chunk, Req, FinalState, Ref) ->
    stream_chunks(Req, Ref, FinalState).

send_followup_done(true, Chunk, Req, FinalState, Ref) ->
    %% We emitted tool calls with done=false; now send the real done
    DoneEvent = #{
        content => <<>>, done => true,
        model => maps:get(<<"model">>, Chunk, <<>>),
        usage => usage_from_chunk(Chunk)
    },
    send_event(Req, DoneEvent),
    stream_chunks(Req, Ref, FinalState);
send_followup_done(false, _Chunk, Req, FinalState, Ref) ->
    stream_chunks(Req, Ref, FinalState).

%% @doc Emit an accumulated Anthropic tool_use block, if one is pending.
emit_pending_tool_use(undefined, Req, Ref, State) ->
    stream_chunks(Req, Ref, State);
emit_pending_tool_use(Tool, Req, Ref, State) ->
    %% Get the accumulated input JSON and decode it to avoid double-encoding
    InputJson = maps:get(input, Tool, <<"{}">>),
    InputMap = decode_or_empty(InputJson),
    ToolUse = #{
        id => maps:get(id, Tool, <<>>),
        name => maps:get(name, Tool, <<>>),
        arguments => InputMap
    },
    Event = #{done => false, content => <<>>, tool_use => ToolUse},
    send_event(Req, Event),
    NewState = maps:remove(current_tool, State),
    stream_chunks(Req, Ref, NewState).

decode_or_empty(Json) ->
    try json:decode(Json) catch _:_ -> #{} end.

%% @doc Validate chat parameters.
validate_chat_params(undefined, _Messages) ->
    {error, <<"model is required">>};
validate_chat_params(_Model, []) ->
    {error, <<"messages cannot be empty">>};
validate_chat_params(_Model, Messages) when not is_list(Messages) ->
    {error, <<"messages must be an array">>};
validate_chat_params(_Model, _Messages) ->
    ok.

%% @doc Build options map from request parameters.
build_chat_opts(Model, Params) ->
    Opts = #{model => Model},
    Opts1 = case maps:get(<<"temperature">>, Params, undefined) of
        undefined -> Opts;
        Temp -> Opts#{temperature => Temp}
    end,
    Opts2 = case maps:get(<<"max_tokens">>, Params, undefined) of
        undefined -> Opts1;
        MaxTokens -> Opts1#{max_tokens => MaxTokens}
    end,
    %% Add tools if provided (for function calling)
    case maps:get(<<"tools">>, Params, undefined) of
        undefined -> Opts2;
        [] -> Opts2;
        Tools when is_list(Tools) -> Opts2#{tools => Tools}
    end.

%% @doc Format messages from JSON to internal format.
%% Preserves tool_calls (assistant requesting tools) and tool_call_id (tool results).
format_messages(Messages) ->
    lists:map(fun format_one_message/1, Messages).

format_one_message(M) ->
    Base = #{
        role => maps:get(<<"role">>, M, <<"user">>),
        content => maps:get(<<"content">>, M, <<>>)
    },
    %% Preserve tool_calls for assistant messages (needed for tool calling flow)
    Base1 = maybe_add_tool_calls(Base, maps:get(<<"tool_calls">>, M, undefined)),
    %% Preserve tool_call_id for tool result messages
    maybe_add_tool_call_id(Base1, maps:get(<<"tool_call_id">>, M, undefined)).

maybe_add_tool_calls(Base, undefined)   -> Base;
maybe_add_tool_calls(Base, [])          -> Base;
maybe_add_tool_calls(Base, ToolCalls)   -> Base#{tool_calls => ToolCalls}.

maybe_add_tool_call_id(Base, undefined)  -> Base;
maybe_add_tool_call_id(Base, <<>>)       -> Base;
maybe_add_tool_call_id(Base, ToolCallId) -> Base#{tool_call_id => ToolCallId}.

%% @doc Format a tool call for JSON output.
%% Decode arguments if they're a JSON string to avoid double-encoding.
format_tool_call(#{id := Id, name := Name, arguments := Args}) ->
    #{
        id => Id,
        name => Name,
        arguments => maybe_decode_args(Args)
    };
format_tool_call(TC) ->
    TC.

maybe_decode_args(Args) when is_binary(Args) -> decode_or_empty(Args);
maybe_decode_args(Args) -> Args.

%% @doc Accumulate an OpenAI/Groq tool call delta into State.
%% Deltas arrive incrementally: first with id+name, then arguments_delta chunks.
accumulate_tool_delta(Delta, State) ->
    Index = maps:get(<<"index">>, Delta, 0),
    Pending = maps:get(pending_tool_calls, State, #{}),
    Current = maps:get(Index, Pending, #{id => <<>>, name => <<>>, arguments => <<>>}),
    %% Update id if present
    C1 = case maps:get(<<"id">>, Delta, undefined) of
        undefined -> Current;
        Id -> Current#{id => Id}
    end,
    %% Update name if present
    C2 = case maps:get(<<"name">>, Delta, undefined) of
        undefined -> C1;
        Name -> C1#{name => Name}
    end,
    %% Append arguments delta
    C3 = case maps:get(<<"arguments_delta">>, Delta, undefined) of
        undefined -> C2;
        ArgsDelta ->
            OldArgs = maps:get(arguments, C2, <<>>),
            C2#{arguments => <<OldArgs/binary, ArgsDelta/binary>>}
    end,
    State#{pending_tool_calls => Pending#{Index => C3}}.

%% @doc Build complete tool calls from accumulated pending deltas.
build_pending_tool_calls(PendingMap) ->
    Sorted = lists:sort(maps:to_list(PendingMap)),
    [begin
        Args = maps:get(arguments, TC, <<"{}">>),
        DecodedArgs = try json:decode(Args) catch _:_ -> #{} end,
        #{
            id => maps:get(id, TC, <<>>),
            name => maps:get(name, TC, <<>>),
            arguments => DecodedArgs
        }
    end || {_Idx, TC} <- Sorted].

%% @doc Optionally translate the LLM response through a schema.
%% When translate_schema is provided, extracts content from the response
%% and runs it through translate_output for canonical structuring.
%% Falls back to raw response on translation failure.
maybe_translate_response(Response, undefined, Req) ->
    hecate_api_utils:json_ok(#{response => Response}, Req);
maybe_translate_response(Response, Schema, Req) ->
    Content = extract_response_content_for_translate(Response),
    case translate_output:translate(Content, Schema) of
        {ok, Translated} ->
            hecate_api_utils:json_ok(#{
                response => Response,
                translated => Translated
            }, Req);
        {error, _} ->
            %% Graceful fallback — return raw response
            hecate_api_utils:json_ok(#{response => Response}, Req)
    end.

extract_response_content_for_translate(#{<<"message">> := #{<<"content">> := C}}) -> C;
extract_response_content_for_translate(#{message := #{content := C}}) -> C;
extract_response_content_for_translate(#{<<"content">> := C}) -> C;
extract_response_content_for_translate(#{content := C}) -> C;
extract_response_content_for_translate(_) -> <<>>.
