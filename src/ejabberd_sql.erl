%%%----------------------------------------------------------------------
%%% File    : ejabberd_sql.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Serve SQL connection
%%% Created :  8 Dec 2004 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_sql).

-author('alexey@process-one.net').

-behaviour(p1_fsm).

%% External exports
-export([start_link/2,
	 sql_query/2,
	 sql_query_t/1,
	 sql_transaction/2,
	 sql_bloc/2,
	 abort/1,
	 restart/1,
	 use_new_schema/0,
	 sql_query_to_iolist/1,
	 escape/1,
	 standard_escape/1,
	 escape_like/1,
	 escape_like_arg/1,
	 escape_like_arg_circumflex/1,
	 to_bool/1,
	 sqlite_db/1,
	 sqlite_file/1,
	 encode_term/1,
	 decode_term/1,
	 odbcinst_config/0,
	 init_mssql/0,
	 keep_alive/2,
	 to_list/2,
	 to_array/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4,
	 handle_info/3, terminate/3, print_state/1,
	 code_change/4]).

-export([connecting/2, connecting/3,
	 session_established/2, session_established/3]).

-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-include("ejabberd_stacktrace.hrl").

-record(state,
	{db_ref               :: undefined | pid(),
	 db_type = odbc       :: pgsql | mysql | sqlite | odbc | mssql,
	 db_version           :: undefined | non_neg_integer(),
	 host                 :: binary(),
	 pending_requests     :: p1_queue:queue(),
	 overload_reported    :: undefined | integer()}).

-define(STATE_KEY, ejabberd_sql_state).
-define(NESTING_KEY, ejabberd_sql_nesting_level).
-define(TOP_LEVEL_TXN, 0).
-define(MAX_TRANSACTION_RESTARTS, 10).
-define(KEEPALIVE_QUERY, [<<"SELECT 1;">>]).
-define(PREPARE_KEY, ejabberd_sql_prepare).
%%-define(DBGFSM, true).
-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

-type state() :: #state{}.
-type sql_query_simple() :: [sql_query() | binary()] | #sql_query{} |
			    fun(() -> any()) | fun((atom(), _) -> any()).
-type sql_query() :: sql_query_simple() |
		     [{atom() | {atom(), any()}, sql_query_simple()}].
-type sql_query_result() :: {updated, non_neg_integer()} |
                            {error, binary() | atom()} |
                            {selected, [binary()], [[binary()]]} |
                            {selected, [any()]} |
			    ok.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
-spec start_link(binary(), pos_integer()) -> {ok, pid()} | {error, term()}.
start_link(Host, I) ->
    Proc = binary_to_atom(get_worker_name(Host, I), utf8),
    p1_fsm:start_link({local, Proc}, ?MODULE, [Host],
		      fsm_limit_opts() ++ ?FSMOPTS).

-spec sql_query(binary(), sql_query()) -> sql_query_result().
sql_query(Host, Query) ->
    sql_call(Host, {sql_query, Query}).

%% SQL transaction based on a list of queries
%% This function automatically
-spec sql_transaction(binary(), [sql_query()] | fun(() -> any())) ->
                             {atomic, any()} |
                             {aborted, any()}.
sql_transaction(Host, Queries)
    when is_list(Queries) ->
    F = fun () ->
		lists:foreach(fun (Query) -> sql_query_t(Query) end,
			      Queries)
	end,
    sql_transaction(Host, F);
%% SQL transaction, based on a erlang anonymous function (F = fun)
sql_transaction(Host, F) when is_function(F) ->
    case sql_call(Host, {sql_transaction, F}) of
	{atomic, _} = Ret -> Ret;
	{aborted, _} = Ret -> Ret;
	Err -> {aborted, Err}
    end.

%% SQL bloc, based on a erlang anonymous function (F = fun)
sql_bloc(Host, F) -> sql_call(Host, {sql_bloc, F}).

sql_call(Host, Msg) ->
    Timeout = query_timeout(Host),
    case get(?STATE_KEY) of
	undefined ->
	    sync_send_event(Host,
			    {sql_cmd, Msg, current_time() + Timeout},
			    Timeout);
	_State ->
	    nested_op(Msg)
    end.

keep_alive(Host, Proc) ->
    Timeout = query_timeout(Host),
    case sync_send_event(
	   Proc,
	   {sql_cmd, {sql_query, ?KEEPALIVE_QUERY}, current_time() + Timeout},
	   Timeout) of
	{selected,_,[[<<"1">>]]} ->
	    ok;
	_Err ->
	    ?ERROR_MSG("Keep alive query failed, closing connection: ~p", [_Err]),
	    sync_send_event(Proc, force_timeout, Timeout)
    end.

sync_send_event(Host, Msg, Timeout) when is_binary(Host) ->
    case ejabberd_sql_sup:start(Host) of
	ok ->
	    Proc = get_worker(Host),
	    sync_send_event(Proc, Msg, Timeout);
	{error, _} = Err ->
	    Err
    end;
sync_send_event(Proc, Msg, Timeout) ->
    try p1_fsm:sync_send_event(Proc, Msg, Timeout)
    catch _:{Reason, {p1_fsm, _, _}} ->
	    {error, Reason}
    end.

-spec sql_query_t(sql_query()) -> sql_query_result().
%% This function is intended to be used from inside an sql_transaction:
sql_query_t(Query) ->
    QRes = sql_query_internal(Query),
    case QRes of
      {error, Reason} -> restart(Reason);
      Rs when is_list(Rs) ->
	  case lists:keysearch(error, 1, Rs) of
	    {value, {error, Reason}} -> restart(Reason);
	    _ -> QRes
	  end;
      _ -> QRes
    end.

abort(Reason) ->
    exit(Reason).

restart(Reason) ->
    throw({aborted, Reason}).

-spec escape_char(char()) -> binary().
escape_char($\000) -> <<"\\0">>;
escape_char($\n) -> <<"\\n">>;
escape_char($\t) -> <<"\\t">>;
escape_char($\b) -> <<"\\b">>;
escape_char($\r) -> <<"\\r">>;
escape_char($') -> <<"''">>;
escape_char($") -> <<"\\\"">>;
escape_char($\\) -> <<"\\\\">>;
escape_char(C) -> <<C>>.

-spec escape(binary()) -> binary().
escape(S) ->
	<<  <<(escape_char(Char))/binary>> || <<Char>> <= S >>.

%% Escape character that will confuse an SQL engine
%% Percent and underscore only need to be escaped for pattern matching like
%% statement
escape_like(S) when is_binary(S) ->
    << <<(escape_like(C))/binary>> || <<C>> <= S >>;
escape_like($%) -> <<"\\%">>;
escape_like($_) -> <<"\\_">>;
escape_like($\\) -> <<"\\\\\\\\">>;
escape_like(C) when is_integer(C), C >= 0, C =< 255 -> escape_char(C).

escape_like_arg(S) when is_binary(S) ->
    << <<(escape_like_arg(C))/binary>> || <<C>> <= S >>;
escape_like_arg($%) -> <<"\\%">>;
escape_like_arg($_) -> <<"\\_">>;
escape_like_arg($\\) -> <<"\\\\">>;
escape_like_arg(C) when is_integer(C), C >= 0, C =< 255 -> <<C>>.

escape_like_arg_circumflex(S) when is_binary(S) ->
    << <<(escape_like_arg_circumflex(C))/binary>> || <<C>> <= S >>;
escape_like_arg_circumflex($%) -> <<"^%">>;
escape_like_arg_circumflex($_) -> <<"^_">>;
escape_like_arg_circumflex($^) -> <<"^^">>;
escape_like_arg_circumflex($[) -> <<"^[">>;     % For MSSQL
escape_like_arg_circumflex($]) -> <<"^]">>;
escape_like_arg_circumflex(C) when is_integer(C), C >= 0, C =< 255 -> <<C>>.

to_bool(<<"t">>) -> true;
to_bool(<<"true">>) -> true;
to_bool(<<"1">>) -> true;
to_bool(true) -> true;
to_bool(1) -> true;
to_bool(_) -> false.

to_list(EscapeFun, Val) ->
    Escaped = lists:join(<<",">>, lists:map(EscapeFun, Val)),
    [<<"(">>, Escaped, <<")">>].

to_array(EscapeFun, Val) ->
    Escaped = lists:join(<<",">>, lists:map(EscapeFun, Val)),
    [<<"{">>, Escaped, <<"}">>].

encode_term(Term) ->
    escape(list_to_binary(
             erl_prettypr:format(erl_syntax:abstract(Term),
                                 [{paper, 65535}, {ribbon, 65535}]))).

decode_term(Bin) ->
    Str = binary_to_list(<<Bin/binary, ".">>),
    try
	{ok, Tokens, _} = erl_scan:string(Str),
	{ok, Term} = erl_parse:parse_term(Tokens),
	Term
    catch _:{badmatch, {error, {Line, Mod, Reason}, _}} ->
	    ?ERROR_MSG("Corrupted Erlang term in SQL database:~n"
		       "** Scanner error: at line ~B: ~ts~n"
		       "** Term: ~ts",
		       [Line, Mod:format_error(Reason), Bin]),
	    erlang:error(badarg);
	  _:{badmatch, {error, {Line, Mod, Reason}}} ->
	    ?ERROR_MSG("Corrupted Erlang term in SQL database:~n"
		       "** Parser error: at line ~B: ~ts~n"
		       "** Term: ~ts",
		       [Line, Mod:format_error(Reason), Bin]),
	    erlang:error(badarg)
    end.

-spec sqlite_db(binary()) -> atom().
sqlite_db(Host) ->
    list_to_atom("ejabberd_sqlite_" ++ binary_to_list(Host)).

-spec sqlite_file(binary()) -> string().
sqlite_file(Host) ->
    case ejabberd_option:sql_database(Host) of
	undefined ->
	    Path = ["sqlite", atom_to_list(node()),
		    binary_to_list(Host), "ejabberd.db"],
	    case file:get_cwd() of
		{ok, Cwd} ->
		    filename:join([Cwd|Path]);
		{error, Reason} ->
		    ?ERROR_MSG("Failed to get current directory: ~ts",
			       [file:format_error(Reason)]),
		    filename:join(Path)
	    end;
	File ->
	    binary_to_list(File)
    end.

use_new_schema() ->
    ejabberd_option:new_sql_schema().

-spec get_worker(binary()) -> atom().
get_worker(Host) ->
    PoolSize = ejabberd_option:sql_pool_size(Host),
    I = p1_rand:round_robin(PoolSize) + 1,
    binary_to_existing_atom(get_worker_name(Host, I), utf8).

-spec get_worker_name(binary(), pos_integer()) -> binary().
get_worker_name(Host, I) ->
    <<"ejabberd_sql_", Host/binary, $_, (integer_to_binary(I))/binary>>.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------
init([Host]) ->
    process_flag(trap_exit, true),
    case ejabberd_option:sql_keepalive_interval(Host) of
        undefined ->
            ok;
        KeepaliveInterval ->
            timer:apply_interval(KeepaliveInterval, ?MODULE,
                                 keep_alive, [Host, self()])
    end,
    [DBType | _] = db_opts(Host),
    p1_fsm:send_event(self(), connect),
    QueueType = ejabberd_option:sql_queue_type(Host),
    {ok, connecting,
     #state{db_type = DBType, host = Host,
	    pending_requests = p1_queue:new(QueueType, max_fsm_queue())}}.

connecting(connect, #state{host = Host} = State) ->
    ConnectRes = case db_opts(Host) of
		   [mysql | Args] -> apply(fun mysql_connect/8, Args);
           [pgsql | Args] -> apply(fun pgsql_connect/8, Args);
           [sqlite | Args] -> apply(fun sqlite_connect/1, Args);
		   [mssql | Args] -> apply(fun odbc_connect/2, Args);
		   [odbc | Args] -> apply(fun odbc_connect/2, Args)
		 end,
    case ConnectRes of
        {ok, Ref} ->
	    try link(Ref) of
		_ ->
		    lists:foreach(
		      fun({{?PREPARE_KEY, _} = Key, _}) ->
			      erase(Key);
			 (_) ->
			      ok
		      end, get()),
		    PendingRequests =
			p1_queue:dropwhile(
			  fun(Req) ->
				  p1_fsm:send_event(self(), Req),
				  true
			  end, State#state.pending_requests),
		    State1 = State#state{db_ref = Ref,
					 pending_requests = PendingRequests},
		    State2 = get_db_version(State1),
		    {next_state, session_established, State2}
	    catch _:Reason ->
		    handle_reconnect(Reason, State)
	    end;
	{error, Reason} ->
	    handle_reconnect(Reason, State)
    end;
connecting(Event, State) ->
    ?WARNING_MSG("Unexpected event in 'connecting': ~p",
		 [Event]),
    {next_state, connecting, State}.

connecting({sql_cmd, {sql_query, ?KEEPALIVE_QUERY}, Timestamp},
	   From, State) ->
    reply(From, {error, <<"SQL connection failed">>}, Timestamp),
    {next_state, connecting, State};
connecting({sql_cmd, Command, Timestamp} = Req, From,
	   State) ->
    ?DEBUG("Queuing pending request while connecting:~n\t~p",
	   [Req]),
    PendingRequests =
	try p1_queue:in({sql_cmd, Command, From, Timestamp},
			State#state.pending_requests)
	catch error:full ->
		Err = <<"SQL request queue is overfilled">>,
		?ERROR_MSG("~ts, bouncing all pending requests", [Err]),
		Q = p1_queue:dropwhile(
		      fun({sql_cmd, _, To, TS}) ->
			      reply(To, {error, Err}, TS),
			      true
		      end, State#state.pending_requests),
		p1_queue:in({sql_cmd, Command, From, Timestamp}, Q)
	end,
    {next_state, connecting,
     State#state{pending_requests = PendingRequests}};
connecting(Request, {Who, _Ref}, State) ->
    ?WARNING_MSG("Unexpected call ~p from ~p in 'connecting'",
		 [Request, Who]),
    {next_state, connecting, State}.

session_established({sql_cmd, Command, Timestamp}, From,
		    State) ->
    run_sql_cmd(Command, From, State, Timestamp);
session_established(Request, {Who, _Ref}, State) ->
    ?WARNING_MSG("Unexpected call ~p from ~p in 'session_established'",
		 [Request, Who]),
    {next_state, session_established, State}.

session_established({sql_cmd, Command, From, Timestamp},
		    State) ->
    run_sql_cmd(Command, From, State, Timestamp);
session_established(force_timeout, State) ->
    {stop, timeout, State};
session_established(Event, State) ->
    ?WARNING_MSG("Unexpected event in 'session_established': ~p",
		 [Event]),
    {next_state, session_established, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, {error, badarg}, StateName, State}.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

handle_info({'EXIT', _Pid, Reason}, _StateName, State) ->
    handle_reconnect(Reason, State);
handle_info(Info, StateName, State) ->
    ?WARNING_MSG("Unexpected info in ~p: ~p",
		 [StateName, Info]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, State) ->
    case State#state.db_type of
        mysql -> catch p1_mysql_conn:stop(State#state.db_ref);
        sqlite -> catch sqlite3:close(sqlite_db(State#state.host));
        _ -> ok
    end,
    ok.

%%----------------------------------------------------------------------
%% Func: print_state/1
%% Purpose: Prepare the state to be printed on error log
%% Returns: State to print
%%----------------------------------------------------------------------
print_state(State) -> State.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
handle_reconnect(Reason, #state{host = Host} = State) ->
    StartInterval = ejabberd_option:sql_start_interval(Host),
    ?WARNING_MSG("~p connection failed:~n"
		 "** Reason: ~p~n"
		 "** Retry after: ~B seconds",
		 [State#state.db_type, Reason,
		  StartInterval div 1000]),
    p1_fsm:send_event_after(StartInterval, connect),
    {next_state, connecting, State}.

run_sql_cmd(Command, From, State, Timestamp) ->
    case current_time() >= Timestamp of
	true ->
	    State1 = report_overload(State),
	    {next_state, session_established, State1};
	false ->
	    put(?NESTING_KEY, ?TOP_LEVEL_TXN),
	    put(?STATE_KEY, State),
	    abort_on_driver_error(outer_op(Command), From, Timestamp)
    end.

%% Only called by handle_call, only handles top level operations.
%% @spec outer_op(Op) -> {error, Reason} | {aborted, Reason} | {atomic, Result}
outer_op({sql_query, Query}) ->
    sql_query_internal(Query);
outer_op({sql_transaction, F}) ->
    outer_transaction(F, ?MAX_TRANSACTION_RESTARTS, <<"">>);
outer_op({sql_bloc, F}) -> execute_bloc(F).

%% Called via sql_query/transaction/bloc from client code when inside a
%% nested operation
nested_op({sql_query, Query}) ->
    sql_query_internal(Query);
nested_op({sql_transaction, F}) ->
    NestingLevel = get(?NESTING_KEY),
    if NestingLevel =:= (?TOP_LEVEL_TXN) ->
	   outer_transaction(F, ?MAX_TRANSACTION_RESTARTS, <<"">>);
       true -> inner_transaction(F)
    end;
nested_op({sql_bloc, F}) -> execute_bloc(F).

%% Never retry nested transactions - only outer transactions
inner_transaction(F) ->
    PreviousNestingLevel = get(?NESTING_KEY),
    case get(?NESTING_KEY) of
      ?TOP_LEVEL_TXN ->
	  {backtrace, T} = process_info(self(), backtrace),
	  ?ERROR_MSG("Inner transaction called at outer txn "
		     "level. Trace: ~ts",
		     [T]),
	  erlang:exit(implementation_faulty);
      _N -> ok
    end,
    put(?NESTING_KEY, PreviousNestingLevel + 1),
    Result = (catch F()),
    put(?NESTING_KEY, PreviousNestingLevel),
    case Result of
      {aborted, Reason} -> {aborted, Reason};
      {'EXIT', Reason} -> {'EXIT', Reason};
      {atomic, Res} -> {atomic, Res};
      Res -> {atomic, Res}
    end.

outer_transaction(F, NRestarts, _Reason) ->
    PreviousNestingLevel = get(?NESTING_KEY),
    case get(?NESTING_KEY) of
      ?TOP_LEVEL_TXN -> ok;
      _N ->
	  {backtrace, T} = process_info(self(), backtrace),
	  ?ERROR_MSG("Outer transaction called at inner txn "
		     "level. Trace: ~ts",
		     [T]),
	  erlang:exit(implementation_faulty)
    end,
    sql_begin(),
    put(?NESTING_KEY, PreviousNestingLevel + 1),
    try F() of
	Res ->
	    sql_commit(),
	    {atomic, Res}
    catch
	?EX_RULE(throw, {aborted, Reason}, _) when NRestarts > 0 ->
	    sql_rollback(),
            put(?NESTING_KEY, ?TOP_LEVEL_TXN),
	    outer_transaction(F, NRestarts - 1, Reason);
	?EX_RULE(throw, {aborted, Reason}, Stack) when NRestarts =:= 0 ->
	    StackTrace = ?EX_STACK(Stack),
	    ?ERROR_MSG("SQL transaction restarts exceeded~n** "
		       "Restarts: ~p~n** Last abort reason: "
		       "~p~n** Stacktrace: ~p~n** When State "
		       "== ~p",
		       [?MAX_TRANSACTION_RESTARTS, Reason,
			StackTrace, get(?STATE_KEY)]),
	    sql_rollback(),
	    {aborted, Reason};
	?EX_RULE(exit, Reason, _) ->
	    sql_rollback(),
	    {aborted, Reason}
    end.

execute_bloc(F) ->
    case catch F() of
      {aborted, Reason} -> {aborted, Reason};
      {'EXIT', Reason} -> {aborted, Reason};
      Res -> {atomic, Res}
    end.

execute_fun(F) when is_function(F, 0) ->
    F();
execute_fun(F) when is_function(F, 2) ->
    State = get(?STATE_KEY),
    F(State#state.db_type, State#state.db_version).

sql_query_internal([{_, _} | _] = Queries) ->
    State = get(?STATE_KEY),
    case select_sql_query(Queries, State) of
        undefined ->
            {error, <<"no matching query for the current DBMS found">>};
        Query ->
            sql_query_internal(Query)
    end;
sql_query_internal(#sql_query{} = Query) ->
    State = get(?STATE_KEY),
    Res =
        try
            case State#state.db_type of
                odbc ->
                    generic_sql_query(Query);
		mssql ->
		    mssql_sql_query(Query);
                pgsql ->
                    Key = {?PREPARE_KEY, Query#sql_query.hash},
                    case get(Key) of
                        undefined ->
                            case pgsql_prepare(Query, State) of
                                {ok, _, _, _} ->
                                    put(Key, prepared);
                                {error, Error} ->
                                    ?ERROR_MSG("PREPARE failed for SQL query "
                                               "at ~p: ~p",
                                               [Query#sql_query.loc, Error]),
                                    put(Key, ignore)
                            end;
                        _ ->
                            ok
                    end,
                    case get(Key) of
                        prepared ->
                            pgsql_execute_sql_query(Query, State);
                        _ ->
                            generic_sql_query(Query)
                    end;
                mysql ->
                    generic_sql_query(Query);
                sqlite ->
                    sqlite_sql_query(Query)
            end
        catch exit:{timeout, _} ->
		{error, <<"timed out">>};
	      exit:{killed, _} ->
		{error, <<"killed">>};
	      exit:{normal, _} ->
		{error, <<"terminated unexpectedly">>};
	      exit:{shutdown, _} ->
		{error, <<"shutdown">>};
	      ?EX_RULE(Class, Reason, Stack) ->
		StackTrace = ?EX_STACK(Stack),
                ?ERROR_MSG("Internal error while processing SQL query:~n** ~ts",
			   [misc:format_exception(2, Class, Reason, StackTrace)]),
                {error, <<"internal error">>}
        end,
    check_error(Res, Query);
sql_query_internal(F) when is_function(F) ->
    case catch execute_fun(F) of
        {aborted, Reason} -> {error, Reason};
        {'EXIT', Reason} -> {error, Reason};
        Res -> Res
    end;
sql_query_internal(Query) ->
    State = get(?STATE_KEY),
    ?DEBUG("SQL: \"~ts\"", [Query]),
    QueryTimeout = query_timeout(State#state.host),
    Res = case State#state.db_type of
	    odbc ->
		to_odbc(odbc:sql_query(State#state.db_ref, [Query],
                                       QueryTimeout - 1000));
	    mssql ->
		to_odbc(odbc:sql_query(State#state.db_ref, [Query],
                                       QueryTimeout - 1000));
	    pgsql ->
		pgsql_to_odbc(pgsql:squery(State#state.db_ref, Query,
					   QueryTimeout - 1000));
	    mysql ->
		R = mysql_to_odbc(p1_mysql_conn:squery(State#state.db_ref,
						   [Query], self(),
						   [{timeout, QueryTimeout - 1000},
						    {result_type, binary}])),
		  R;
	      sqlite ->
		  Host = State#state.host,
		  sqlite_to_odbc(Host, sqlite3:sql_exec(sqlite_db(Host), Query))
	  end,
    check_error(Res, Query).

select_sql_query(Queries, State) ->
    select_sql_query(
      Queries, State#state.db_type, State#state.db_version, undefined).

select_sql_query([], _Type, _Version, undefined) ->
    undefined;
select_sql_query([], _Type, _Version, Query) ->
    Query;
select_sql_query([{any, Query} | _], _Type, _Version, _) ->
    Query;
select_sql_query([{Type, Query} | _], Type, _Version, _) ->
    Query;
select_sql_query([{{Type, _Version1}, Query1} | Rest], Type, undefined, _) ->
    select_sql_query(Rest, Type, undefined, Query1);
select_sql_query([{{Type, Version1}, Query1} | Rest], Type, Version, Query) ->
    if
        Version >= Version1 ->
            Query1;
        true ->
            select_sql_query(Rest, Type, Version, Query)
    end;
select_sql_query([{_, _} | Rest], Type, Version, Query) ->
    select_sql_query(Rest, Type, Version, Query).

generic_sql_query(SQLQuery) ->
    sql_query_format_res(
      sql_query_internal(generic_sql_query_format(SQLQuery)),
      SQLQuery).

generic_sql_query_format(SQLQuery) ->
    Args = (SQLQuery#sql_query.args)(generic_escape()),
    (SQLQuery#sql_query.format_query)(Args).

generic_escape() ->
    #sql_escape{string = fun(X) -> <<"'", (escape(X))/binary, "'">> end,
		integer = fun(X) -> misc:i2l(X) end,
		boolean = fun(true) -> <<"1">>;
                             (false) -> <<"0">>
                          end,
		in_array_string = fun(X) -> <<"'", (escape(X))/binary, "'">> end
               }.

sqlite_sql_query(SQLQuery) ->
    sql_query_format_res(
      sql_query_internal(sqlite_sql_query_format(SQLQuery)),
      SQLQuery).

sqlite_sql_query_format(SQLQuery) ->
    Args = (SQLQuery#sql_query.args)(sqlite_escape()),
    (SQLQuery#sql_query.format_query)(Args).

sqlite_escape() ->
    #sql_escape{string = fun(X) -> <<"'", (standard_escape(X))/binary, "'">> end,
		integer = fun(X) -> misc:i2l(X) end,
		boolean = fun(true) -> <<"1">>;
                             (false) -> <<"0">>
                          end,
		in_array_string = fun(X) -> <<"'", (standard_escape(X))/binary, "'">> end
               }.

standard_escape(S) ->
    << <<(case Char of
              $' -> << "''" >>;
              _ -> << Char >>
          end)/binary>> || <<Char>> <= S >>.

mssql_sql_query(SQLQuery) ->
    sqlite_sql_query(SQLQuery).

pgsql_prepare(SQLQuery, State) ->
    Escape = #sql_escape{_ = fun(X) -> X end},
    N = length((SQLQuery#sql_query.args)(Escape)),
    Args = [<<$$, (integer_to_binary(I))/binary>> || I <- lists:seq(1, N)],
    Query = (SQLQuery#sql_query.format_query)(Args),
    pgsql:prepare(State#state.db_ref, SQLQuery#sql_query.hash, Query).

pgsql_execute_escape() ->
    #sql_escape{string = fun(X) -> X end,
		integer = fun(X) -> [misc:i2l(X)] end,
		boolean = fun(true) -> "1";
                             (false) -> "0"
                          end,
		in_array_string = fun(X) -> <<"\"", (escape(X))/binary, "\"">> end
               }.

pgsql_execute_sql_query(SQLQuery, State) ->
    Args = (SQLQuery#sql_query.args)(pgsql_execute_escape()),
    ExecuteRes =
        pgsql:execute(State#state.db_ref, SQLQuery#sql_query.hash, Args),
%    {T, ExecuteRes} =
%        timer:tc(pgsql, execute, [State#state.db_ref, SQLQuery#sql_query.hash, Args]),
%    io:format("T ~ts ~p~n", [SQLQuery#sql_query.hash, T]),
    Res = pgsql_execute_to_odbc(ExecuteRes),
    sql_query_format_res(Res, SQLQuery).


sql_query_format_res({selected, _, Rows}, SQLQuery) ->
    Res =
        lists:flatmap(
          fun(Row) ->
                  try
                      [(SQLQuery#sql_query.format_res)(Row)]
                  catch
		      ?EX_RULE(Class, Reason, Stack) ->
			  StackTrace = ?EX_STACK(Stack),
                          ?ERROR_MSG("Error while processing SQL query result:~n"
                                     "** Row: ~p~n** ~ts",
                                     [Row,
				      misc:format_exception(2, Class, Reason, StackTrace)]),
                          []
                  end
          end, Rows),
    {selected, Res};
sql_query_format_res(Res, _SQLQuery) ->
    Res.

sql_query_to_iolist(SQLQuery) ->
    generic_sql_query_format(SQLQuery).

sql_begin() ->
    sql_query_internal(
      [{mssql, [<<"begin transaction;">>]},
       {any, [<<"begin;">>]}]).

sql_commit() ->
    sql_query_internal(
      [{mssql, [<<"commit transaction;">>]},
       {any, [<<"commit;">>]}]).

sql_rollback() ->
    sql_query_internal(
      [{mssql, [<<"rollback transaction;">>]},
       {any, [<<"rollback;">>]}]).


%% Generate the OTP callback return tuple depending on the driver result.
abort_on_driver_error({error, <<"query timed out">>} = Reply, From, Timestamp) ->
    reply(From, Reply, Timestamp),
    {stop, timeout, get(?STATE_KEY)};
abort_on_driver_error({error, <<"Failed sending data on socket", _/binary>>} = Reply,
		      From, Timestamp) ->
    reply(From, Reply, Timestamp),
    {stop, closed, get(?STATE_KEY)};
abort_on_driver_error({error, <<"SQL connection failed">>} = Reply, From, Timestamp) ->
    reply(From, Reply, Timestamp),
    {stop, timeout, get(?STATE_KEY)};
abort_on_driver_error({error, <<"Communication link failure">>} = Reply, From, Timestamp) ->
    reply(From, Reply, Timestamp),
    {stop, closed, get(?STATE_KEY)};
abort_on_driver_error(Reply, From, Timestamp) ->
    reply(From, Reply, Timestamp),
    {next_state, session_established, get(?STATE_KEY)}.

-spec report_overload(state()) -> state().
report_overload(#state{overload_reported = PrevTime} = State) ->
    CurrTime = current_time(),
    case PrevTime == undefined orelse (CurrTime - PrevTime) > timer:seconds(30) of
	true ->
	    ?ERROR_MSG("SQL connection pool is overloaded, "
		       "discarding stale requests", []),
	    State#state{overload_reported = current_time()};
	false ->
	    State
    end.

-spec reply({pid(), term()}, term(), integer()) -> term().
reply(From, Reply, Timestamp) ->
    case current_time() >= Timestamp of
	true -> ok;
	false -> p1_fsm:reply(From, Reply)
    end.

%% == pure ODBC code

%% part of init/1
%% Open an ODBC database connection
odbc_connect(SQLServer, Timeout) ->
    ejabberd:start_app(odbc),
    odbc:connect(binary_to_list(SQLServer),
		 [{scrollable_cursors, off},
		  {extended_errors, on},
		  {tuple_row, off},
		  {timeout, Timeout},
		  {binary_strings, on}]).

%% == Native SQLite code

%% part of init/1
%% Open a database connection to SQLite

sqlite_connect(Host) ->
    File = sqlite_file(Host),
    case filelib:ensure_dir(File) of
	ok ->
	    case sqlite3:open(sqlite_db(Host), [{file, File}]) of
		{ok, Ref} ->
		    sqlite3:sql_exec(
		      sqlite_db(Host), "pragma foreign_keys = on"),
		    {ok, Ref};
		{error, {already_started, Ref}} ->
		    {ok, Ref};
		{error, Reason} ->
		    {error, Reason}
	    end;
	Err ->
	    Err
    end.

%% Convert SQLite query result to Erlang ODBC result formalism
sqlite_to_odbc(Host, ok) ->
    {updated, sqlite3:changes(sqlite_db(Host))};
sqlite_to_odbc(Host, {rowid, _}) ->
    {updated, sqlite3:changes(sqlite_db(Host))};
sqlite_to_odbc(_Host, [{columns, Columns}, {rows, TRows}]) ->
    Rows = [lists:map(
	      fun(I) when is_integer(I) ->
		      integer_to_binary(I);
		 (B) ->
		      B
	      end, tuple_to_list(Row)) || Row <- TRows],
    {selected, [list_to_binary(C) || C <- Columns], Rows};
sqlite_to_odbc(_Host, {error, _Code, Reason}) ->
    {error, Reason};
sqlite_to_odbc(_Host, _) ->
    {updated, undefined}.

%% == Native PostgreSQL code

%% part of init/1
%% Open a database connection to PostgreSQL
pgsql_connect(Server, Port, DB, Username, Password, ConnectTimeout,
	      Transport, SSLOpts) ->
    case pgsql:connect([{host, Server},
                        {database, DB},
                        {user, Username},
                        {password, Password},
                        {port, Port},
			{transport, Transport},
			{connect_timeout, ConnectTimeout},
                        {as_binary, true}|SSLOpts]) of
        {ok, Ref} ->
            pgsql:squery(Ref, [<<"alter database \"">>, DB, <<"\" set ">>,
                               <<"standard_conforming_strings='off';">>]),
            pgsql:squery(Ref, [<<"set standard_conforming_strings to 'off';">>]),
            {ok, Ref};
        Err ->
            Err
    end.

%% Convert PostgreSQL query result to Erlang ODBC result formalism
pgsql_to_odbc({ok, PGSQLResult}) ->
    case PGSQLResult of
      [Item] -> pgsql_item_to_odbc(Item);
      Items -> [pgsql_item_to_odbc(Item) || Item <- Items]
    end.

pgsql_item_to_odbc({<<"SELECT", _/binary>>, Rows,
		    Recs}) ->
    {selected, [element(1, Row) || Row <- Rows], Recs};
pgsql_item_to_odbc({<<"FETCH", _/binary>>, Rows,
		    Recs}) ->
    {selected, [element(1, Row) || Row <- Rows], Recs};
pgsql_item_to_odbc(<<"INSERT ", OIDN/binary>>) ->
    [_OID, N] = str:tokens(OIDN, <<" ">>),
    {updated, binary_to_integer(N)};
pgsql_item_to_odbc(<<"DELETE ", N/binary>>) ->
    {updated, binary_to_integer(N)};
pgsql_item_to_odbc(<<"UPDATE ", N/binary>>) ->
    {updated, binary_to_integer(N)};
pgsql_item_to_odbc({error, Error}) -> {error, Error};
pgsql_item_to_odbc(_) -> {updated, undefined}.

pgsql_execute_to_odbc({ok, {<<"SELECT", _/binary>>, Rows}}) ->
    {selected, [], [[Field || {_, Field} <- Row] || Row <- Rows]};
pgsql_execute_to_odbc({ok, {'INSERT', N}}) ->
    {updated, N};
pgsql_execute_to_odbc({ok, {'DELETE', N}}) ->
    {updated, N};
pgsql_execute_to_odbc({ok, {'UPDATE', N}}) ->
    {updated, N};
pgsql_execute_to_odbc({error, Error}) -> {error, Error};
pgsql_execute_to_odbc(_) -> {updated, undefined}.


%% == Native MySQL code

%% part of init/1
%% Open a database connection to MySQL
mysql_connect(Server, Port, DB, Username, Password, ConnectTimeout,  _, _) ->
    case p1_mysql_conn:start(binary_to_list(Server), Port,
			     binary_to_list(Username),
			     binary_to_list(Password),
			     binary_to_list(DB),
			     ConnectTimeout, fun log/3)
	of
	{ok, Ref} ->
	    p1_mysql_conn:fetch(
		Ref, [<<"set names 'utf8mb4' collate 'utf8mb4_bin';">>], self()),
	    {ok, Ref};
	Err -> Err
    end.

%% Convert MySQL query result to Erlang ODBC result formalism
mysql_to_odbc({updated, MySQLRes}) ->
    {updated, p1_mysql:get_result_affected_rows(MySQLRes)};
mysql_to_odbc({data, MySQLRes}) ->
    mysql_item_to_odbc(p1_mysql:get_result_field_info(MySQLRes),
		       p1_mysql:get_result_rows(MySQLRes));
mysql_to_odbc({error, MySQLRes})
  when is_binary(MySQLRes) ->
    {error, MySQLRes};
mysql_to_odbc({error, MySQLRes})
  when is_list(MySQLRes) ->
    {error, list_to_binary(MySQLRes)};
mysql_to_odbc({error, MySQLRes}) ->
    {error, p1_mysql:get_result_reason(MySQLRes)};
mysql_to_odbc(ok) ->
    ok.


%% When tabular data is returned, convert it to the ODBC formalism
mysql_item_to_odbc(Columns, Recs) ->
    {selected, [element(2, Column) || Column <- Columns], Recs}.

to_odbc({selected, Columns, Recs}) ->
    Rows = [lists:map(
	      fun(I) when is_integer(I) ->
		      integer_to_binary(I);
		 (B) ->
		      B
	      end, Row) || Row <- Recs],
    {selected, [list_to_binary(C) || C <- Columns], Rows};
to_odbc({error, Reason}) when is_list(Reason) ->
    {error, list_to_binary(Reason)};
to_odbc(Res) ->
    Res.

get_db_version(#state{db_type = pgsql} = State) ->
    case pgsql:squery(State#state.db_ref,
                      <<"select current_setting('server_version_num')">>) of
        {ok, [{_, _, [[SVersion]]}]} ->
            case catch binary_to_integer(SVersion) of
                Version when is_integer(Version) ->
                    State#state{db_version = Version};
                Error ->
                    ?WARNING_MSG("Error getting pgsql version: ~p", [Error]),
                    State
            end;
        Res ->
            ?WARNING_MSG("Error getting pgsql version: ~p", [Res]),
            State
    end;
get_db_version(State) ->
    State.

log(Level, Format, Args) ->
    case Level of
      debug -> ?DEBUG(Format, Args);
      info -> ?INFO_MSG(Format, Args);
      normal -> ?INFO_MSG(Format, Args);
      error -> ?ERROR_MSG(Format, Args)
    end.

db_opts(Host) ->
    Type = ejabberd_option:sql_type(Host),
    Server = ejabberd_option:sql_server(Host),
    Timeout = ejabberd_option:sql_connect_timeout(Host),
    Transport = case ejabberd_option:sql_ssl(Host) of
		    false -> tcp;
		    true -> ssl
		end,
    warn_if_ssl_unsupported(Transport, Type),
    case Type of
        odbc ->
            [odbc, Server, Timeout];
        sqlite ->
            [sqlite, Host];
        _ ->
            Port = ejabberd_option:sql_port(Host),
            DB = case ejabberd_option:sql_database(Host) of
		     undefined -> <<"ejabberd">>;
		     D -> D
		 end,
            User = ejabberd_option:sql_username(Host),
            Pass = ejabberd_option:sql_password(Host),
	    SSLOpts = get_ssl_opts(Transport, Host),
	    case Type of
		mssql ->
		    [mssql, <<"DRIVER=FreeTDS;SERVER=", Server/binary, ";UID=", User/binary,
			      ";DATABASE=", DB/binary ,";PWD=", Pass/binary,
			      ";PORT=", (integer_to_binary(Port))/binary ,";CLIENT_CHARSET=UTF-8;">>, Timeout];
		_ ->
		    [Type, Server, Port, DB, User, Pass, Timeout, Transport, SSLOpts]
	    end
    end.

warn_if_ssl_unsupported(tcp, _) ->
    ok;
warn_if_ssl_unsupported(ssl, pgsql) ->
    ok;
warn_if_ssl_unsupported(ssl, Type) ->
    ?WARNING_MSG("SSL connection is not supported for ~ts", [Type]).

get_ssl_opts(ssl, Host) ->
    Opts1 = case ejabberd_option:sql_ssl_certfile(Host) of
		undefined -> [];
		CertFile -> [{certfile, CertFile}]
	    end,
    Opts2 = case ejabberd_option:sql_ssl_cafile(Host) of
		undefined -> Opts1;
		CAFile -> [{cacertfile, CAFile}|Opts1]
	    end,
    case ejabberd_option:sql_ssl_verify(Host) of
	true ->
	    case lists:keymember(cacertfile, 1, Opts2) of
		true ->
		    [{verify, verify_peer}|Opts2];
		false ->
		    ?WARNING_MSG("SSL verification is enabled for "
				 "SQL connection, but option "
				 "'sql_ssl_cafile' is not set; "
				 "verification will be disabled", []),
		    Opts2
	    end;
	false ->
	    Opts2
    end;
get_ssl_opts(tcp, _) ->
    [].

init_mssql() ->
    ODBCINST = io_lib:fwrite("[FreeTDS]~n"
			     "Driver = libtdsodbc.so~n", []),
    ?DEBUG("~ts:~n~ts", [odbcinst_config(), ODBCINST]),
    case filelib:ensure_dir(odbcinst_config()) of
	ok ->
	    try
		ok = write_file_if_new(odbcinst_config(), ODBCINST),
		os:putenv("ODBCSYSINI", tmp_dir()),
		ok
	    catch error:{badmatch, {error, Reason} = Err} ->
		    ?ERROR_MSG("Failed to create temporary files in ~ts: ~ts",
			       [tmp_dir(), file:format_error(Reason)]),
		    Err
	    end;
	{error, Reason} = Err ->
	    ?ERROR_MSG("Failed to create temporary directory ~ts: ~ts",
		       [tmp_dir(), file:format_error(Reason)]),
	    Err
    end.

write_file_if_new(File, Payload) ->
    case filelib:is_file(File) of
	true -> ok;
	false -> file:write_file(File, Payload)
    end.

tmp_dir() ->
    case os:type() of
	{win32, _} -> filename:join([os:getenv("HOME"), "conf"]);
	_ -> filename:join(["/tmp", "ejabberd"])
    end.

odbcinst_config() ->
    filename:join(tmp_dir(), "odbcinst.ini").

max_fsm_queue() ->
    proplists:get_value(max_queue, fsm_limit_opts(), unlimited).

fsm_limit_opts() ->
    ejabberd_config:fsm_limit_opts([]).

query_timeout(LServer) ->
    ejabberd_option:sql_query_timeout(LServer).

current_time() ->
    erlang:monotonic_time(millisecond).

%% ***IMPORTANT*** This error format requires extended_errors turned on.
extended_error({"08S01", _, Reason}) ->
    % TCP Provider: The specified network name is no longer available
    ?DEBUG("ODBC Link Failure: ~ts", [Reason]),
    <<"Communication link failure">>;
extended_error({"08001", _, Reason}) ->
    % Login timeout expired
    ?DEBUG("ODBC Connect Timeout: ~ts", [Reason]),
    <<"SQL connection failed">>;
extended_error({"IMC01", _, Reason}) ->
    % The connection is broken and recovery is not possible
    ?DEBUG("ODBC Link Failure: ~ts", [Reason]),
    <<"Communication link failure">>;
extended_error({"IMC06", _, Reason}) ->
    % The connection is broken and recovery is not possible
    ?DEBUG("ODBC Link Failure: ~ts", [Reason]),
    <<"Communication link failure">>;
extended_error({Code, _, Reason}) ->
    ?DEBUG("ODBC Error ~ts: ~ts", [Code, Reason]),
    iolist_to_binary(Reason);
extended_error(Error) ->
    Error.

check_error({error, Why} = Err, _Query) when Why == killed ->
    Err;
check_error({error, Why}, #sql_query{} = Query) ->
    Err = extended_error(Why),
    ?ERROR_MSG("SQL query '~ts' at ~p failed: ~p",
               [Query#sql_query.hash, Query#sql_query.loc, Err]),
    {error, Err};
check_error({error, Why}, Query) ->
    Err = extended_error(Why),
    case catch iolist_to_binary(Query) of
        SQuery when is_binary(SQuery) ->
            ?ERROR_MSG("SQL query '~ts' failed: ~p", [SQuery, Err]);
        _ ->
            ?ERROR_MSG("SQL query ~p failed: ~p", [Query, Err])
    end,
    {error, Err};
check_error(Result, _Query) ->
    Result.
