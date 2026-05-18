%%% @doc Small Cowboy JSON helpers shared by slice API handlers.
-module(hecate_llm_http).

-export([
    ok_json/2, bad_request/2, not_found/1, method_not_allowed/1,
    read_json_body/1, get_field/2, get_field/3
]).

ok_json(Body, Req)        -> reply_json(200, Body, Req).
bad_request(Reason, Req)  -> reply_json(400, #{error => to_binary(Reason)}, Req).
not_found(Req)            -> reply_json(404, #{error => <<"not_found">>}, Req).
method_not_allowed(Req)   -> reply_json(405, #{error => <<"method_not_allowed">>}, Req).

read_json_body(Req0) ->
    case cowboy_req:read_body(Req0) of
        {ok, Body, Req1} when byte_size(Body) > 0 ->
            try {ok, jsx:decode(Body, [return_maps]), Req1}
            catch _:_ -> {error, invalid_json, Req1}
            end;
        {ok, _Empty, Req1} ->
            {ok, #{}, Req1}
    end.

get_field(Key, Params) -> get_field(Key, Params, undefined).
get_field(Key, Params, Default) when is_atom(Key) ->
    get_field(atom_to_binary(Key, utf8), Params, Default);
get_field(Key, Params, Default) when is_binary(Key) ->
    maps:get(Key, Params, Default).

reply_json(Code, Body, Req) ->
    cowboy_req:reply(Code,
                     #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(Body), Req).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L)   -> iolist_to_binary(L);
to_binary(A) when is_atom(A)   -> atom_to_binary(A, utf8);
to_binary(O)                    -> iolist_to_binary(io_lib:format("~p", [O])).
