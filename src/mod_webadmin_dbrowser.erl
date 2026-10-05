%%%----------------------------------------------------------------------
%%% File    : mod_webadmin_dbrowser.erl
%%% Author  :
%%% Purpose : DBrowser pages for WebAdmin
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
%%%----------------------------------------------------------------------

%%%% definitions

%% @format-begin

-module(mod_webadmin_dbrowser).

-behaviour(gen_mod).

-export([start/2, stop/1, mod_doc/0, mod_options/1, depends/2]).
-export([web_menu_node/3, web_page_node/3]).
-export([web_menu_host/3, web_page_host/3]).

-include("logger.hrl").

-include_lib("xmpp/include/xmpp.hrl").

-include("ejabberd_http.hrl").
-include("ejabberd_web_admin.hrl").
-include("mod_privacy.hrl").
-include("translate.hrl").

-callback init(binary(), gen_mod:opts()) -> any().
-callback web_menu_node(list(), atom(), [binary()]) -> list().
-callback web_page_node(list(), atom(), [binary()]) -> list().

-optional_callbacks([web_menu_node/3, web_page_node/3]).

%%%==================================
%%%% gen_mod

start(Host, Opts) ->
    {ok, MnesiaList} = mod_webadmin_dbrowser_mnesia:init(Host, Opts),
    {ok, SqlList} = mod_webadmin_dbrowser_sql:init(Host, Opts),
    {ok, MnesiaList ++ SqlList}.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

mod_doc() ->
    #{desc =>
          [?T("This module adds pages to WebAdmin to browse the Mnesia and SQL databases:"
              "viw the list of tables, their size, schema, and content.")]}.

%%%==================================
%%%% WebAdmin

web_menu_node(Acc, Node, Lang) ->
    mod_webadmin_dbrowser_mnesia:web_menu_node(Acc, Node, Lang).

web_page_node(Acc, Node, Lang) ->
    mod_webadmin_dbrowser_mnesia:web_page_node(Acc, Node, Lang).

web_menu_host(Acc, Node, Lang) ->
    mod_webadmin_dbrowser_sql:web_menu_host(Acc, Node, Lang).

web_page_host(Acc, Node, Lang) ->
    mod_webadmin_dbrowser_sql:web_page_host(Acc, Node, Lang).

%%%==================================

%%% vim: set foldmethod=marker foldmarker=%%%%,%%%=:
