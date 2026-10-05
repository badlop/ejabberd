%%%-------------------------------------------------------------------
%%% File    : mod_webadmin_dbrowser_mnesia.erl
%%% Author  :
%%% Purpose : WebAdmin DBrowser: Mnesia backend
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

-module(mod_webadmin_dbrowser_mnesia).

-behaviour(mod_webadmin_dbrowser).

-export([init/2]).
-export([get_commands_spec/0]).
-export([web_menu_node/3, web_page_node/3]).
-export([node_db_table_page/3, get_mnesia_table_contentx/1]).

-import(ejabberd_web_admin, [make_command/2, make_command/4, make_table/2]).

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
      {hook, webadmin_menu_node, web_menu_node, 50, global},
      {hook, webadmin_page_node, web_page_node, 50, global}]}.

%%%==================================
%%%% commands: define

get_commands_spec() ->
    Parametrized =
        lists:map(fun(Max) ->
                     CommandName = make_command_name(Max),
                     Args =
                         [{list_to_atom(integer_to_list(Int)), string} || Int <- lists:seq(1, Max)],
                     #ejabberd_commands{name = CommandName,
                                        tags = [mnesia, internal],
                                        module = ?MODULE,
                                        function = get_mnesia_table_contentx,
                                        args = [{table_name, binary}],
                                        result = {contents, {list, {content, {tuple, Args}}}}}
                  end,
                  lists:seq(1, 30)),
    [#ejabberd_commands{name = node_db,
                        tags = [internal],
                        desc = "Generate WebAdmin Mnesia database HTML",
                        module = ?MODULE,
                        function = node_db,
                        args = [{node, atom}, {query, any}, {lang, binary}],
                        result = {res, any}},
     #ejabberd_commands{name = node_db_table,
                        tags = [internal],
                        desc = "Generate WebAdmin Mnesia database HTML for a table",
                        module = ?MODULE,
                        function = node_db_table,
                        args = [{node, atom}, {table, binary}, {lang, binary}],
                        result = {res, any}},
     #ejabberd_commands{name = node_db_table_page,
                        tags = [internal],
                        desc = "Generate WebAdmin Mnesia database HTML for a table content",
                        module = ?MODULE,
                        function = node_db_table_page,
                        args = [{node, atom}, {table, binary}, {page, integer}],
                        result = {res, any}},
     #ejabberd_commands{name = node_db_table_page_tabular,
                        tags = [internal],
                        desc = "Generate WebAdmin Mnesia database HTML for a table content",
                        module = ?MODULE,
                        function = node_db_table_page,
                        args = [{table, binary}, {page, integer}],
                        result = {res, any}}
     | Parametrized].

%%%==================================
%%%% commands: implement

get_mnesia_table_contentx(TableBin) ->
    Table = binary_to_existing_atom(TableBin, utf8),
    Keys = mnesia:dirty_all_keys(Table),
    Res = [mnesia:dirty_read(Table, Key) || Key <- Keys],
    Items = lists:flatten(Res),
    lists:map(fun(Row) ->
                 [_TableName | TableContent] = tuple_to_list(Row),
                 list_to_tuple([to_binary(X) || X <- TableContent])
              end,
              Items).

to_binary(X) when is_binary(X) ->
    X;
to_binary(X) ->
    str:format("~p", [X]).

%%%==================================
%%%% webadmin node

web_menu_node(Acc, _Node, _Lang) ->
    Acc ++ [{<<"db">>, <<"Mnesia DBrowser">>}, {<<"backup">>, <<"Mnesia Backup">>}].

web_page_node(_, Node, #request{path = [<<"backup">> | _RPath], lang = Lang} = R) ->
    Types =
        [{<<"#binary">>, <<"Binary">>},
         {<<"#plaintext">>, <<"Plain Text">>},
         {<<"#piefxis">>, <<"PIEXFIS (XEP-0227)">>},
         {<<"#sql">>, <<"SQL">>},
         {<<"#prosody">>, <<"Prosody">>},
         {<<"#jabberd14">>, <<"jabberd 1.4">>}],

    [?XC(<<"h1">>, str:translate_and_format(Lang, ?T("Backup of ~p"), [Node])),
     ?XCT(<<"p">>,
          ?T("Please note that these options will "
             "only backup the builtin Mnesia database. "
             "If you are using the ODBC module, you "
             "also need to backup your SQL database "
             "separately.")),
     ?XE(<<"ul">>, [?LI([?AC(MIU, MIN)]) || {MIU, MIN} <- Types]), ?X(<<"hr">>),
     ?XAC(<<"h2">>, [{<<"id">>, <<"binary">>}], <<"Binary">>),
     ?XCT(<<"p">>, ?T("Store binary backup:")),
     ?XE(<<"blockquote">>, [make_command(backup, R)]),
     ?XCT(<<"p">>, ?T("Restore binary backup immediately:")),
     ?XE(<<"blockquote">>, [make_command(restore, R, [], [{style, danger}])]),
     ?XCT(<<"p">>,
          ?T("Restore binary backup after next ejabberd "
             "restart (requires less memory):")),
     ?XE(<<"blockquote">>, [make_command(install_fallback, R, [], [{style, danger}])]),
     ?X(<<"hr">>), ?XAC(<<"h2">>, [{<<"id">>, <<"plaintext">>}], <<"Plain Text">>),
     ?XCT(<<"p">>, ?T("Store plain text backup:")),
     ?XE(<<"blockquote">>, [make_command(dump, R)]),
     ?XCT(<<"p">>, ?T("Restore plain text backup immediately:")),
     ?XE(<<"blockquote">>, [make_command(load, R, [], [{style, danger}])]), ?X(<<"hr">>),
     ?XAC(<<"h2">>, [{<<"id">>, <<"piefxis">>}], <<"PIEFXIS (XEP-0227)">>),
     ?XCT(<<"p">>, ?T("Import users data from a PIEFXIS file (XEP-0227):")),
     ?XE(<<"blockquote">>, [make_command(import_piefxis, R)]),
     ?XCT(<<"p">>, ?T("Export data of all users in the server to PIEFXIS files (XEP-0227):")),
     ?XE(<<"blockquote">>, [make_command(export_piefxis, R)]),
     ?XCT(<<"p">>, ?T("Export data of users in a host to PIEFXIS files (XEP-0227):")),
     ?XE(<<"blockquote">>, [make_command(export_piefxis_host, R)]), ?X(<<"hr">>),
     ?XAC(<<"h2">>, [{<<"id">>, <<"sql">>}], <<"SQL">>),
     ?XCT(<<"p">>, ?T("Export all tables as SQL queries to a file:")),
     ?XE(<<"blockquote">>, [make_command(export2sql, R)]), ?X(<<"hr">>),
     ?XAC(<<"h2">>, [{<<"id">>, <<"prosody">>}], <<"Prosody">>),
     ?XCT(<<"p">>, <<"Import data from Prosody:">>),
     ?XE(<<"blockquote">>, [make_command(import_prosody, R)]), ?X(<<"hr">>),
     ?XAC(<<"h2">>, [{<<"id">>, <<"jabberd14">>}], <<"jabberd 1.4">>),
     ?XCT(<<"p">>, ?T("Import user data from jabberd14 spool file:")),
     ?XE(<<"blockquote">>, [make_command(import_file, R)]),
     ?XCT(<<"p">>, ?T("Import users data from jabberd14 spool directory:")),
     ?XE(<<"blockquote">>, [make_command(import_dir, R)])];
web_page_node(_, Node, #request{path = [<<"db">> | RPath]} = R) ->
    PageTitle = <<"Mnesia DBrowser">>,
    Title = ?XC(<<"h1">>, PageTitle),
    Level = length(RPath),
    [Title, ?BR | webadmin_db(Node, RPath, R, Level)];
web_page_node(Acc, _, _) ->
    Acc.

%%%==================================
%%%% webadmin_db

webadmin_db(Node, [<<"table">>, TableName, <<"details">> | RPath], R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Details">>, RPath}),
    Get = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [mnesia_table_details,
                                  R,
                                  [{<<"table">>, TableName}],
                                  [{only, without_presentation}]])],
    Breadcrumb ++ Get;
webadmin_db(Node,
            [<<"table">>, TableName, <<"elements-raw">>, PageNumber | RPath],
            R,
            Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Elements (raw)">>, RPath}),
    Get = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [node_db_table_page,
                                  R,
                                  [{<<"node">>, Node},
                                   {<<"table">>, TableName},
                                   {<<"page">>, PageNumber}],
                                  [{only, without_presentation}]])],
    Breadcrumb ++ Get;
webadmin_db(Node, [<<"table">>, TableName, <<"elements-tabular">> | RPath], R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section,
                         Level,
                         Service,
                         TableName,
                         <<"Elements (tabular)">>,
                         RPath}),
    Get = [node_db_table_page_tabular(Node, R, RPath, Level, TableName, crude)],
    Breadcrumb ++ Get;
webadmin_db(Node, [<<"table">>, TableName, <<"elements-nice">> | RPath], R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Elements (nice)">>, RPath}),
    Get = [node_db_table_page_tabular(Node, R, RPath, Level, TableName, nice)],
    Breadcrumb ++ Get;
webadmin_db(Node, [<<"table">>, TableName, <<"change-storage">> | RPath], R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Change Storage">>, RPath}),
    Set = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [mnesia_table_change_storage, R, [{<<"table">>, TableName}], []])],
    Breadcrumb ++ Set;
webadmin_db(Node, [<<"table">>, TableName, <<"clear">> | RPath], R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Clear Content">>, RPath}),
    Set = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [mnesia_table_clear,
                                  R,
                                  [{<<"table">>, TableName}],
                                  [{style, danger}, {only, without_presentation}]])],
    Breadcrumb ++ Set;
webadmin_db(Node, [<<"table">>, TableName, <<"destroy">> | RPath], R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb =
        make_breadcrumb({table_section, Level, Service, TableName, <<"Destroy Table">>, RPath}),
    Set = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [mnesia_table_destroy,
                                  R,
                                  [{<<"table">>, TableName}],
                                  [{style, danger}, {only, without_presentation}]])],
    Breadcrumb ++ Set;
webadmin_db(_Node, [<<"table">>, TableName | _RPath], _R, Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb = make_breadcrumb({table, Level, Service, TableName}),
    MenuItems =
        [{<<"details/">>, <<"Details">>},
         {<<"elements-raw/1/">>, <<"Elements (raw)">>},
         {<<"elements-tabular/">>, <<"Elements (tabular)">>},
         {<<"elements-nice/">>, <<"Elements (nice)">>},
         {<<"change-storage/">>, <<"Change Storage">>},
         {<<"clear/">>, <<"Clear Content">>},
         {<<"destroy/">>, <<"Destroy Table">>}],
    Get = [?XE(<<"ul">>, [?LI([?AC(MIU, MIN)]) || {MIU, MIN} <- MenuItems])],
    Breadcrumb ++ Get;
webadmin_db(Node, _RPath, R, _Level) ->
    Service = <<"Mnesia DBrowser">>,
    Breadcrumb = make_breadcrumb({service, Service}),
    Get = [ejabberd_cluster:call(Node,
                                 ejabberd_web_admin,
                                 make_command,
                                 [mnesia_list_tables,
                                  R,
                                  [],
                                  [{result_links, [{name, mnesia_table, 3, <<"">>}]}]])],
    Breadcrumb ++ Get.

%%%==================================
%%%% make_breadcrumb

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
%%%% mnesia table view

node_db_table_page_tabular(Node, Request, RPath, Level, STable, ProcessingType) ->
    TableAtom = binary_to_existing_atom(STable, utf8),
    CommandName = make_command_name(mnesia:table_info(TableAtom, arity) - 1),
    BaseArguments = [{<<"table_name">>, STable}],
    HeaderTexts = mnesia:table_info(TableAtom, attributes),
    ResultLinksSpecific =
        case ProcessingType of
            crude ->
                [{packet, paragraph, 0, <<>>},
                 {vcard, paragraph, 0, <<>>},
                 {xml, paragraph, 0, <<>>}];
            nice ->
                [{bare_peer, user, 3 + Level, <<>>},
                 {created_at, timestamp, 0, <<>>},
                 {domain, host, 3 + Level, <<>>},
                 {expire, timestamp, 0, <<>>},
                 {expires, timestamp, 0, <<>>},
                 {from, user, 3 + Level, <<>>},
                 {inviter, user, 3 + Level, <<>>},
                 {jid, user, 3 + Level, <<>>},
                 {name_host, room, 3 + Level, <<>>},
                 {packet, xml_stanza, 0, <<>>},
                 {payload, xml_stanza, 0, <<>>},
                 {peer, user, 3 + Level, <<>>},
                 {server, host, 3 + Level, <<>>},
                 {server_host, host, 3 + Level, <<>>},
                 {timestamp, timestamp, 0, <<>>},
                 {to, user, 3 + Level, <<>>},
                 {us, user, 3 + Level, <<>>},
                 {user, user, 3 + Level, <<>>},
                 {vcard, xml_stanza, 0, <<>>},
                 {vhost, host, 3 + Level, <<>>},
                 {xml, xml_stanza, 0, <<>>}]
        end,
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
    binary_to_atom(<<"get_mnesia_table_content", TableArity/binary>>).

node_db_table_page(Node, STable, PageNumber) ->
    try binary_to_existing_atom(STable, utf8) of
        Table ->
            TInfo = ejabberd_cluster:call(Node, mnesia, table_info, [Table, all]),
            {value, {storage_type, Type}} = lists:keysearch(storage_type, 1, TInfo),
            {value, {size, Size}} = lists:keysearch(size, 1, TInfo),
            PageSize = 500,
            TableContentErl = get_table_content(Node, Table, Type, PageNumber, PageSize),
            TableContent = str:format("~p", [TableContentErl]),
            PagesLinks = build_elements_pages_list(Size, PageNumber, PageSize),
            [?P] ++ PagesLinks ++ [?XC(<<"pre">>, TableContent)]
    catch
        error:badarg ->
            []
    end.

build_elements_pages_list(Size, PageNumber, PageSize) ->
    PagesNumber = calculate_pages_number(Size, PageSize),
    PagesSeq = lists:seq(1, PagesNumber),
    PagesList =
        [?AC(<<"../", (integer_to_binary(N))/binary, "/">>,
             <<(integer_to_binary(N))/binary, " ">>)
         || N <- PagesSeq],
    lists:keyreplace([?C(<<(integer_to_binary(PageNumber))/binary, " ">>)],
                     4,
                     PagesList,
                     ?C(<<" [", (integer_to_binary(PageNumber))/binary, "] ">>)).

calculate_pages_number(Size, PageSize) ->
    Remainder =
        case Size rem PageSize of
            0 ->
                0;
            _ ->
                1
        end,
    case Size div PageSize + Remainder of
        1 ->
            0;
        Res ->
            Res
    end.

get_table_content(Node, Table, _Type, PageNumber, PageSize) ->
    Keys1 =
        lists:sort(
            ejabberd_cluster:call(Node, mnesia, dirty_all_keys, [Table])),
    FirstKeyPos = 1 - PageSize + PageNumber * PageSize,
    Keys = lists:sublist(Keys1, FirstKeyPos, PageSize),
    Res = [ejabberd_cluster:call(Node, mnesia, dirty_read, [Table, Key]) || Key <- Keys],
    lists:flatten(Res).

%%%==================================

%%% vim: set foldmethod=marker foldmarker=%%%%,%%%=:
