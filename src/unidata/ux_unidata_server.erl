%%% @doc This module provides the access to the store of default files.
%%%      When client runs a function from the ux_unidata module:
%%%      1. Code from ux_unidata_filelist module check the process dict 
%%%         and the application enviroments. If they are unefined, then
%%%         it call this server.
%%%      2. If this server already loaded this data, it returns it, and
%%%         the client code put it to the process dictionary.
%%%      3. If requested data is not loaded, then this server runs
%%%         an other server (ux_unidata_store), which parsed a default 
%%%         UNIDATA file.
%%% @end
%%%
%%% @private
-module(ux_unidata_server).
-include("ux.hrl").

-export([start_link/0]).
-export([init/1, terminate/2, 
    handle_call/3, handle_info/2, handle_cast/2]).
-export([set_default/1, get_default/1]).

% spawn export.
-export([spawn_waiter/2]).

-behavior(gen_server).

%% Exported Client Functions
%% Operation & Maintenance API
start_link() ->
    Arguments = [],
    Opts = [],
    gen_server:start_link({local, ?MODULE}, ?MODULE, Arguments, Opts).

init([]) ->
    ?DBG("~w~w: All default types were generated. ~n",
        [?MODULE, self()]),
    {ok, []}.

terminate(_Reason, _LoopData) ->
    ok.

%% Spawns process which waits result from ux_unidata_store.
spawn_waiter(LoaderFn, Key) ->
    ok = LoaderFn(),
    Reply = ux_unidata_filelist:get_source_from(process, Key),
    % Reply to ux_unidata_server.
    gen_server:cast(?MODULE, {waiter_reply, Key}),
    % Reply to clients.
    spawn_waiter_reply(Reply).

spawn_waiter_reply(ReplyVal) ->
    receive
    {reply_to, Pid} ->
        Pid ! {reply, ReplyVal},
        spawn_waiter_reply(ReplyVal)
    after 5000 ->
        ok
    end.

%% Runs from a client process.
wait_respond(WaiterPid) ->
    WaiterPid ! {reply_to, self()},
    {ok, Result} = 
        receive
        {reply, Val} -> {ok, Val}
        after 20000 -> 
            {error, timeout}
        end,
    Result.
    
check_key(Key) ->
    case erlang:get(Key) of
    Pid when is_pid(Pid) ->
        case erlang:is_process_alive(Pid) of
        true -> ok; % still working.
        false ->
        % a spawn_waiter process failed and dead.
        erlang:erase(Key),
        ok
        end;
    Fun when is_function(Fun) -> ok
    end.

% Ref stores Key.
% Key stores Pid of a waiter or Fun.
% Delete pid from dict. FromPid is a pid of ux_unidata_store server.
handle_info({'DOWN', Ref, process, FromPid, _Reason}, LoopData) ->
    ?DBG("~w: Delete Pid = ~w from the process dictionary. ~n", 
        [?MODULE, FromPid]),

    case erlang:get(Ref) of
    undefined -> ok;
    Key -> erlang:erase(Ref), check_key(Key)
    end,
    {noreply, LoopData}.

handle_cast({waiter_reply, Key}, LoopData) ->
    ok = load_default(Key),
    {noreply, LoopData}.

handle_call({get_default, Key} = V, From, LoopData) ->
    case ux_unidata_filelist:get_source_from(process, Key) of
    undefined -> 
        LoaderFn = fun() -> 
            load_default(Key) 
            end,
        {WaiterPid, Ref} = spawn_monitor(?MODULE, 
                'spawn_waiter', [LoaderFn, Key]),
        put(Key, WaiterPid),
        put(Ref, Key),
        Reply = WaiterPid,
        {reply, Reply, LoopData};
    Reply when is_function(Reply) -> 
        case Reply('test') of
        true ->
            {reply, Reply, LoopData};

        % Restart the "dead" function
        false ->
            LoaderFn = fun() -> 
                Reply('reload')
                end,
            {WaiterPid, Ref} = spawn_monitor(?MODULE, 
                    'spawn_waiter', [LoaderFn, Key]),
            put(Key, WaiterPid),
            put(Ref, Key),
            Reply2 = WaiterPid,
            {reply, Reply2, LoopData}
        end
    end;

handle_call({set_default, Key}, _From, LoopData) ->
    Reply = ux_unidata_filelist:set_source(process, Key),
    {reply, Reply, LoopData}.

%%
%% API
%%

%% If cannot load data from default sources, then return undefined.
get_default(Key) ->
    Reply = gen_server:call(?MODULE, {get_default, Key}, 60000),
    case Reply of
    Fun when is_function(Fun) -> 
        put(Key, Fun), % Registrate in the dict of the local process.
        Fun;
    WaiterPid when is_pid(WaiterPid) ->
        wait_respond(WaiterPid)
    end.

set_default(Key) ->
    gen_server:call(?MODULE, {set_default, Key}, 60000).


%%
%% Private helpers
%% 
load_default({Parser, Type} = _Key) ->
    FileName = ux_unidata:get_source_file(Parser),
%   Types = [Type],
    Types = all,
    ux_unidata_filelist:set_source(process, Parser, Types, FileName).

