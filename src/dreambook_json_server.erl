-module(dreambook_json_server).

-include_lib("logger.hrl").
-include_lib("emysql/include/emysql.hrl").

-export([start_link/0, start_link/1, stop/1]).
-export([handle_http_request/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
    start_link([]).

start_link(Options) ->
    Port = proplists:get_value(port, Options, 8080),
    IP   = proplists:get_value(ip, Options, "0.0.0.0"),
    Name = dreambook_json_mochiserver,
    Loop = fun(Request) -> ?MODULE:handle_http_request(Request) end,
    MochiOptions = [{ip, IP}, {port, Port}, {loop, Loop}, {name, Name}],
    mochiweb_http:start(MochiOptions).

stop(Pid) ->
    mochiweb_http:stop(Pid).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_http_request(Request) ->

    try
        case Request:get(path) of
            "/api"         -> ok;
            "/favicon.ico" -> erlang:error({favicon, 404});
            _              -> erlang:error({invalid_path, 404})
        end,

        ?LOG_DEBUG("Request from ~s: ~s", [dreambook_utils:peername(Request:get(socket)), Request:get(raw_path)]),

        Options = Request:parse_qs(),
        UID = proplists:get_value("uid", Options),
        SIG = proplists:get_value("sig", Options),
        Method = proplists:get_value("method", Options),
        Keyword = proplists:get_value("keyword", Options),

        validate_sig(UID, SIG),

        case Method of
            "get_balance"   -> Request:ok({"application/json", get_balance(UID)});
            "get_history"   -> Request:ok({"application/json", get_history(UID)});
            "find_books"    -> Request:ok({"application/json", find_books(Keyword)});
            "find_meaning"  -> Request:ok({"application/json", find_meaning(UID, Keyword)});
            "find_keywords" -> Request:ok({"application/json", find_keywords(Keyword)});
            _               -> erlang:error({invalid_method, 405})
        end
    catch
        _:{favicon, Code} ->
            Request:respond({Code, [], []}); %% Silently ignore favicon
        _:{Reason, Code} when is_integer(Code) ->
            ?LOG_TRACE("Error occured: ~p; responding by page ~B", [Reason, Code]),
            Request:respond({Code, [], []});
        Cat:Err ->
            ?LOG_TRACE("Error ~p:~p occured: responding by page ~B", [Cat, Err, 500]),
            Request:respond({500,  [], []})
    end.

validate_sig(undefined, _) -> erlang:error(no_uid, 401);
validate_sig(_UID, _SIG) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Utils:

validate_arg(undefined) -> erlang:error({invalid_args, 401});
validate_arg(_) -> ok.

get_balance(UID) ->
    validate_arg(UID),
    json({struct, [{<<"Banalce">>, dreambook_db_server:get_balance(UID)}]}).

get_history(UID) ->
    validate_arg(UID),
    json({struct, [{<<"History">>, dreambook_db_server:get_history(UID)}]}).

find_books(Keyword) ->
    validate_arg(Keyword),
    json({struct, [{<<"Books">>, dreambook_db_server:find_books(Keyword)}]}).

find_keywords(Keyword) ->
    validate_arg(Keyword),
    json({struct, [{<<"Keywords">>, dreambook_db_server:find_keywords(Keyword)}]}).

find_meaning(UID, Keyword) ->
    validate_arg(UID),
    validate_arg(Keyword),
    case dreambook_db_server:find_meaning(Keyword) of
        [] -> erlang:error({no_meaning, 404});
        Data ->
            case dreambook_db_server:in_history(UID, Keyword) of
                true  -> noop;
                false ->
                    case dreambook_db_server:del_balance(UID, 1) of
                        ok ->
                            ok = dreambook_db_server:add_history(UID, Keyword);
                        _  ->
                            erlang:error({no_money, 402})
                    end
            end,

            Meanings = lists:map(fun({B,M}) -> {struct,[{<<"Book">>,B},{<<"Meaning">>,M}]} end, Data),
            json({struct, [{<<"Meanings">>, Meanings}]})
    end.

json(Data) ->
    Encode = mochijson2:encoder([{utf8, true}]),
    dreambook_utils:json_pretty_print(Encode(Data)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%