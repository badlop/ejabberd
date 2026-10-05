%%%-------------------------------------------------------------------
%%% File    : mod_webadmin_dbrowser_sql.erl
%%% Author  :
%%% Purpose : WebAdmin DBrowser: SQL backend
%%% Created :
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2026   ProcessOne
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
%%%-------------------------------------------------------------------

%%%% definitions

%% @format-begin

-module(mod_webadmin_dbrowser_sql).

-behaviour(mod_webadmin_dbrowser).

-export([init/2]).
-export([get_commands_spec/0]).
-export([web_menu_host/3, web_page_host/3]).
-export([sql_database/1, sql_tables/1, sql_table_details/2, sql_tables_details/1,
         sql_table_info/2, sql_table_elements/2, sql_clear_table/2, sql_drop_table/2]).
-export([get_sql_table_contentx/2]).

-import(ejabberd_web_admin, [make_command/4, make_table/2]).

-include("ejabberd_commands.hrl").
-include("ejabberd_http.hrl").
-include("ejabberd_sql_pt.hrl").
-include("ejabberd_web_admin.hrl").
-include("logger.hrl").
-include("translate.hrl").

-include_lib("xmpp/include/xmpp.hrl").

%%%==================================
%%%% DBrowser

init(_Host, _Opts) ->
    {ok,
     [{commands, get_commands_spec()},
      {hook, webadmin_menu_host, web_menu_host, 50},
      {hook, webadmin_page_host, web_page_host, 50}]}.

%%%==================================
%%%% commands: define

get_commands_spec() ->
    Parametrized =
        lists:map(fun(Max) ->
                     CommandName = make_command_name(Max),
                     Args =
                         [{list_to_atom(integer_to_list(Int)), string} || Int <- lists:seq(1, Max)],
                     #ejabberd_commands{name = CommandName,
                                        tags = [internal, sql],
                                        module = ?MODULE,
                                        function = get_sql_table_contentx,
                                        args = [{table_name, binary}, {host, binary}],
                                        result = {contents, {list, {content, {tuple, Args}}}}}
                  end,
                  lists:seq(1, 30)),
    [#ejabberd_commands{name = sql_database,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_database,
                        args = [{host, binary}],
                        result = {path, string}},
     #ejabberd_commands{name = sql_tables,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_tables,
                        args = [{host, binary}],
                        result = {tables, {list, {table, string}}}},
     #ejabberd_commands{name = sql_table_details,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_table_details,
                        args = [{host, binary}, {name, binary}],
                        result = {res_tuple, {tuple, [{count, integer}]}}},
     #ejabberd_commands{name = sql_tables_details,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_tables_details,
                        args = [{host, binary}],
                        result =
                            {res_list,
                             {list, {list_tuple, {tuple, [{name, string}, {elements, integer}]}}}}},
     #ejabberd_commands{name = sql_table_info,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_table_info,
                        args = [{host, binary}, {name, binary}],
                        result = {path, string}},
     #ejabberd_commands{name = sql_table_elements,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_table_elements,
                        args = [{host, binary}, {name, binary}],
                        result = {res_list, {list, {list_list, {list, {field, string}}}}}},
     #ejabberd_commands{name = sql_clear_table,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_clear_table,
                        args = [{host, binary}, {name, binary}],
                        result = {res_atom, restuple}},
     #ejabberd_commands{name = sql_drop_table,
                        tags = [internal, sql],
                        module = ?MODULE,
                        function = sql_drop_table,
                        args = [{host, binary}, {name, binary}],
                        result = {res_atom, restuple}}
     | Parametrized].

%%%==================================
%%%% commands: implement

sql_database(Host) ->
    sql_database(Host, ejabberd_option:sql_type(Host)).

sql_database(Host, sqlite) ->
    Type = atom_to_binary(ejabberd_option:sql_type(Host)),
    FilePath = iolist_to_binary(ejabberd_sql:sqlite_file(Host)),
    <<Type/binary, "://", FilePath/binary>>;
sql_database(Host, _Other) ->
    Type = atom_to_binary(ejabberd_option:sql_type(Host)),
    Server = ejabberd_option:sql_server(Host),
    Port = integer_to_binary(ejabberd_option:sql_port(Host)),
    Db = ejabberd_option:sql_database(Host),
    <<Type/binary, "://", Server/binary, ":", Port/binary, "/", Db/binary>>.

sql_tables(Host) ->
    sql_tables(Host, ejabberd_option:sql_type(Host)).

sql_tables(Host, sqlite) ->
    TablesAtoms =
        sqlite3:list_tables(
            ejabberd_sql:sqlite_db(Host)),
    lists:sort([atom_to_binary(Atom) || Atom <- TablesAtoms]);
%%sql_tables(Host, pgsql) ->
%%    Query = ["SELECT table_name FROM information_schema.tables WHERE table_schema='public'"],
%%    {selected, _Cols, Rows} = ejabberd_sql:sql_query(Host, Query),
%%    lists:sort([Row || [Row] <- Rows]);
sql_tables(Host, SqlType) when (SqlType == mysql) or (SqlType == pgsql) ->
    TS = case SqlType of
             pgsql ->
                 <<"public">>;
             mysql ->
                 ejabberd_option:sql_database(Host)
         end,
    Query =
        <<"SELECT table_name FROM information_schema.tables WHERE table_schema='",
          TS/binary,
          "'">>,
    {selected, _Cols, Rows} = ejabberd_sql:sql_query(Host, Query),
    lists:sort([Row || [Row] <- Rows]);
sql_tables(Host, SqlType) ->
    ?WARNING_MSG("The command sql_tables doesn't support SQL type ~p (for host ~p)",
                 [SqlType, Host]),
    [].

get_notserverhost_tables() ->
    [bosh, % is only stored on the first defined database
     caps_features, % global for the server, and only stores data in the first defined database
     mix_channel,
     mix_participant,
     mix_subscription,
     muc_room_subscribers, % host = conference.localhost
     oauth_client, % global, stores only in the first DB
     oauth_token, % jid = admin@localhost, stores only in the first BD
     privacy_list_data, % related with table privacy_list
     proxy65,
     pubsub_item,
     pubsub_node, % host = user1@localhost
     pubsub_node_option,
     pubsub_node_owner,
     pubsub_state,
     pubsub_subscription_opt,
     schema_version, % it's stored for each vhost
     sqlite_sequence]. % global

sql_table_details(Host, Table) ->
    NotSH = get_notserverhost_tables(),
    Query =
        case lists:member(
                 misc:binary_to_atom(Table), NotSH)
        of
            false ->
                <<"SELECT COUNT(*) FROM ", Table/binary, " WHERE server_host='", Host/binary, "'">>;
            true ->
                <<"SELECT COUNT(*) FROM ", Table/binary>>
        end,
    case ejabberd_sql:sql_query(Host, Query) of
        {selected, [_], [[ResBinary]]} ->
            {binary_to_integer(ResBinary)};
        OtherResponse ->
            ?WARNING_MSG("Unexpected result for query ~p: ~n~p", [Query, OtherResponse]),
            {0}
    end.

sql_tables_details(Host) ->
    lists:map(fun(Table) ->
                 {Count} = sql_table_details(Host, Table),
                 {Table, Count}
              end,
              sql_tables(Host)).

sql_table_info(Host, Table) ->
    sql_table_info(Host, Table, ejabberd_option:sql_type(Host)).

%%% TODO: Investigate why some tables crash.
%%% If that crash can't be solved, at least try to detect when this will happen
%%% and avoid calling it if it will crash.
sql_table_info(Host, Table, sqlite) ->
    Db = ejabberd_sql:sqlite_db(Host),
    try sqlite3:table_info(Db, binary_to_existing_atom(Table)) of
        InfoErlang ->
            io_lib:format("~p", [InfoErlang])
    catch
        exit:{{function_clause, _}, _} ->
            "Sorry, there was an internal problem getting details of this SQLite table."
    end;
sql_table_info(Host, Table, pgsql) ->
    Query =
        <<"SELECT column_name,data_type,character_maximum_length FROM information_schema.columns WHERE table_name='",
          Table/binary,
          "'">>,
    {selected, _Cols, Rows} = ejabberd_sql:sql_query(Host, Query),
    io_lib:format("~p", [Rows]);
sql_table_info(Host, Table, mysql) ->
    Query =
        <<"SELECT column_name,data_type,character_maximum_length FROM information_schema.columns WHERE table_name='",
          Table/binary,
          "'">>,
    {selected, _Cols, Rows} = ejabberd_sql:sql_query(Host, Query),
    io_lib:format("~p", [Rows]);
sql_table_info(_Host, _Table, SqlType) ->
    io_lib:format("Error: The command sql_table_info does not support SQL type ~p",
                  [SqlType]).

sql_table_elements(Host, Table) ->
    sql_table_elements(Host, Table, ejabberd_option:sql_type(Host)).

sql_table_elements(Host, Table, sqlite) ->
    [{columns, Columns}, {rows, RowsTuples}] =
        sqlite3:read_all(
            ejabberd_sql:sqlite_db(Host), Table),
    ColumnsBin = [list_to_binary(Column) || Column <- Columns],
    lists:append([ColumnsBin], RowsTuples);
sql_table_elements(Host, Table, _) ->
    NotSH = get_notserverhost_tables(),
    Query =
        case lists:member(binary_to_existing_atom(Table), NotSH) of
            false ->
                <<"SELECT * FROM ", Table/binary, " WHERE server_host='", Host/binary, "'">>;
            true ->
                <<"SELECT * FROM ", Table/binary>>
        end,
    {selected, Columns, Rows} = ejabberd_sql:sql_query(Host, Query),
    Rows2 = [prepare_row(Row) || Row <- Rows],
    [Columns | Rows2].

prepare_row(Tuple) when is_tuple(Tuple) ->
    prepare_row(tuple_to_list(Tuple));
prepare_row(List) when is_list(List) ->
    List2 = [prepare_item(Item) || Item <- List],
    list_to_tuple(List2).

prepare_item(I) when is_integer(I) ->
    integer_to_binary(I);
prepare_item({xmlcdata, B}) when is_binary(B) ->
    B;
prepare_item(B) when is_binary(B) ->
    B.

sql_clear_table(Host, Table) ->
    {updated, Integer} = ejabberd_sql:sql_query(Host, <<"DELETE FROM ", Table/binary>>),
    {ok,
     lists:flatten(
         io_lib:format("Table ~s cleared: deleted ~p", [Table, Integer]))}.

sql_drop_table(Host, Table) ->
    case ejabberd_sql:sql_query(Host, <<"DROP TABLE ", Table/binary>>) of
        {updated, _} ->
            {ok,
             lists:flatten(
                 io_lib:format("Table ~s dropped.", [Table]))};
        {error, Elements} ->
            {error, proplists:get_value(message, Elements)}
    end.

%%%==================================
%%%% webadmin host

web_menu_host(Acc, Host, Lang) ->
    case ejabberd_option:sql_database(Host) of
        undefined ->
            Acc;
        _ ->
            [{<<"sql">>, translate:translate(Lang, ?T("SQL DBrowser"))} | Acc]
    end.

web_page_host(_,
              Host,
              #request{us = {Username, Server}, path = [<<"sql">> | RPath]} = R) ->
    Jid = jid:make(Username, Server),
    case any_rules_allowed(global, [configure], Jid) of
        true ->
            Title = [?XC(<<"h1">>, <<"SQL DBrowser for ", Host/binary>>)],
            Level = length(RPath),
            Node = node(),
            Get = [make_command(sql_database, R, [{<<"host">>, Host}], [])],
            Db = webadmin_db({Node, Host}, RPath, R, Level),
            {stop, Title ++ Get ++ Db};
        false ->
            Title = [?XC(<<"p">>, <<"Only available for global server administrators">>)],
            {stop, Title}
    end;
web_page_host(Acc, _, _) ->
    Acc.

%% Copied from ejabberd_web_admin.erl
any_rules_allowed(Host, Access, Entity) ->
    lists:any(fun(Rule) -> allow == acl:match_rule(Host, Rule, Entity) end, Access).

%%%==================================
%%%% webadmin_db

webadmin_db({_Node, Host}, [<<"table">>, TableName, <<"info">> | RPath], R, Level) ->
    Service = <<"SQL Tables">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Info">>, RPath}),
    Get = [make_command(sql_table_info,
                        R,
                        [{<<"host">>, Host}, {<<"name">>, TableName}],
                        [{table_options, {10, RPath}},
                         {result_links, [{path, paragraph, 1, <<"">>}]}])],
    Breadcrumb ++ Get;
webadmin_db({Node, Host}, [<<"table">>, TableName, <<"elements">> | RPath], R, Level) ->
    Service = <<"SQL Tables">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Elements">>, RPath}),
    Get = [webadmin_node_db_table_page_tabular(Node, Host, R, RPath, Level, TableName)],
    Breadcrumb ++ Get;
webadmin_db({_Node, Host}, [<<"table">>, TableName, <<"clear">> | RPath], R, Level) ->
    Service = <<"SQL Tables">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Clear Content">>, RPath}),
    Set = [make_command(sql_clear_table,
                        R,
                        [{<<"host">>, Host}, {<<"name">>, TableName}],
                        [{style, danger}])],
    Breadcrumb ++ Set;
webadmin_db({_Node, Host}, [<<"table">>, TableName, <<"drop">> | RPath], R, Level) ->
    Service = <<"SQL Tables">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Drop Table">>, RPath}),
    Set = [make_command(sql_drop_table,
                        R,
                        [{<<"host">>, Host}, {<<"name">>, TableName}],
                        [{style, danger}])],
    Breadcrumb ++ Set;
webadmin_db(_Node, [<<"table">>, TableName | _RPath], _R, Level) ->
    Service = <<"SQL Tables">>,
    Breadcrumb = make_breadcrumb({table, Level, Service, TableName}),
    MenuItems =
        [{<<"info/">>, <<"Info">>},
         {<<"elements/">>, <<"Elements">>},
         {<<"clear/">>, <<"Clear Content">>},
         {<<"drop/">>, <<"Drop Table">>}],
    Get = [?XE(<<"ul">>, [?LI([?AC(MIU, MIN)]) || {MIU, MIN} <- MenuItems])],
    Breadcrumb ++ Get;
webadmin_db({Node, Host}, _RPath, R, _Level) ->
    Service = <<"SQL Tables">>,
    Breadcrumb = make_breadcrumb({service, Service}),
    Get = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [sql_tables_details,
                                  R,
                                  [{<<"host">>, Host}],
                                  [{result_links, [{name, sql_table, 3, <<"">>}]}]])],
    Breadcrumb ++ Get.

make_breadcrumb({service, Service}) ->
    make_breadcrumb([Service]);
make_breadcrumb({table, Level, Service, Name}) ->
    make_breadcrumb([{Level, Service}, separator, Name]);
make_breadcrumb({table_section, Level, Service, Name, Section, RPath}) ->
    make_breadcrumb([{Level, Service}, separator, {Level - 2, Name}, separator, Section
                     | RPath]);
make_breadcrumb(Elements) ->
    lists:map(fun ({xmlel, _, _, _} = Xmlel) ->
                      Xmlel;
                  (<<"sort">>) ->
                      ?C(<<" +">>);
                  (<<"page">>) ->
                      ?C(<<" #">>);
                  (separator) ->
                      ?C(<<" > ">>);
                  (Bin) when is_binary(Bin) ->
                      ?C(Bin);
                  ({Level, Bin}) when is_integer(Level) and is_binary(Bin) ->
                      ?AC(binary:copy(<<"../">>, Level), Bin)
              end,
              Elements).

%%%==================================
%%%% sql table view

get_table_headers(Host, Table, sqlite) ->
    [{columns, Columns}, {rows, _}] =
        sqlite3:read_all(
            ejabberd_sql:sqlite_db(Host), Table),
    [list_to_atom(Column) || Column <- Columns];
%% TODO: Optimize this query
get_table_headers(Host, Table, _) ->
    NotSH = get_notserverhost_tables(),
    Query =
        case lists:member(binary_to_existing_atom(Table), NotSH) of
            false ->
                <<"SELECT * FROM ", Table/binary, " WHERE server_host='", Host/binary, "'">>;
            true ->
                <<"SELECT * FROM ", Table/binary>>
        end,
    {selected, Columns, _Rows} = ejabberd_sql:sql_query(Host, Query),
    [misc:binary_to_atom(Column) || Column <- Columns].

webadmin_node_db_table_page_tabular(Node, Host, Request, RPath, Level, STable) ->
    SqlType = ejabberd_option:sql_type(Host),
    BaseArguments = [{<<"table_name">>, STable}, {<<"host">>, Host}],
    HeaderTexts = get_table_headers(Host, STable, SqlType),
    Arity = length(HeaderTexts),
    CommandName = make_command_name(Arity),
    ResultLinksSpecific =
        [{bare_peer, user, 3 + Level, <<>>},
         {data, xml_stanza, 0, <<>>},
         {jid, user, 3 + Level, <<>>},
         {opts, paragraph, 0, <<>>},
         {payload, xml_stanza, 0, <<>>},
         {peer, user, 3 + Level, <<>>},
         {seconds, timestamp, 0, <<>>},
         {timestamp, timestamp, 0, <<>>},
         {server_host, host, 3 + Level, <<>>},
         {txt, paragraph, 0, <<>>},
         {vcard, xml_stanza, 0, <<>>},
         {xml, xml_stanza, 0, <<>>}],
    ResultLinks =
        [{lists, paragraph, 0, <<>>}, {options, paragraph, 0, <<>>}, {opts, paragraph, 0, <<>>}
         | ResultLinksSpecific],
    ejabberd_cluster:call(Node,
                          ejabberd_web_admin,
                          make_command,
                          [CommandName,
                           Request,
                           BaseArguments,
                           [{header_texts, HeaderTexts},
                            {only, without_presentation},
                            {result_links, ResultLinks},
                            {result_named, true},
                            {table_options, {20, RPath}}]]).

make_command_name(Arity) ->
    TableArity = integer_to_binary(Arity),
    misc:binary_to_atom(<<"get_sql_table_content", TableArity/binary>>).

get_sql_table_contentx(TableBin, Host) ->
    SqlType = ejabberd_option:sql_type(Host),
    [_ | Res2] = sql_table_elements(Host, TableBin, SqlType),
    Res2.

%%%==================================

%%% vim: set foldmethod=marker foldmarker=%%%%,%%%=:
