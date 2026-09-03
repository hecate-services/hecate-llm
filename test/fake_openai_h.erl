%%% @doc A fake OpenAI-compatible endpoint for the suite: two providers on
%%% one listener, told apart by path prefix.
%%%
%%%   /dead/v1/models            lists `kimi' -- so the model resolves here
%%%   /dead/v1/chat/completions  answers 429 to everything -- NVIDIA, 2026-09-02
%%%   /alive/v1/models           lists `deepseek-chat'
%%%   /alive/v1/chat/completions answers "pong"
%%%
%%% The primary therefore fails exactly the way the live fleet failed (a
%%% provider that lists a model and then rate-limits the call), and the
%%% fallback answers. Every request is also reported to the test process
%%% named in the handler state, so a test can assert which provider was
%%% asked, in which order, for which model.
-module(fake_openai_h).

-export([init/2]).

init(Req0, #{report_to := Pid} = State) ->
    Path = cowboy_req:path(Req0),
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Pid ! {asked, Path, model_in(Body)},
    {Status, Reply} = answer(Path),
    Req2 = cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>},
                            json:encode(Reply), Req1),
    {ok, Req2, State}.

answer(<<"/dead/v1/models">>) ->
    {200, #{data => [#{id => <<"kimi">>, owned_by => <<"dead">>}]}};
answer(<<"/dead/v1/chat/completions">>) ->
    {429, #{status => 429, title => <<"Too Many Requests">>}};
answer(<<"/alive/v1/models">>) ->
    {200, #{data => [#{id => <<"deepseek-chat">>, owned_by => <<"alive">>}]}};
answer(<<"/alive/v1/chat/completions">>) ->
    {200, #{choices => [#{message => #{role => <<"assistant">>, content => <<"pong">>},
                          finish_reason => <<"stop">>}],
            model => <<"deepseek-chat">>,
            usage => #{prompt_tokens => 3, completion_tokens => 1}}};
answer(_Other) ->
    {404, #{error => <<"no such route">>}}.

model_in(<<>>) ->
    undefined;
model_in(Body) ->
    try maps:get(<<"model">>, json:decode(Body), undefined)
    catch _:_ -> undefined
    end.
