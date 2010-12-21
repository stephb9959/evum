%% Copyright (c) 2010, Michael Santos <michael.santos@gmail.com>
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%%
%% Redistributions of source code must retain the above copyright
%% notice, this list of conditions and the following disclaimer.
%%
%% Redistributions in binary form must reproduce the above copyright
%% notice, this list of conditions and the following disclaimer in the
%% documentation and/or other materials provided with the distribution.
%%
%% Neither the name of the author nor the names of its contributors
%% may be used to endorse or promote products derived from this software
%% without specific prior written permission.
%%
%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
%% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
%% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
%% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
%% COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
%% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
%% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
%% POSSIBILITY OF SUCH DAMAGE.
-module(evum_ctl).
-behaviour(gen_server).

-include("procket.hrl").
-include("evum.hrl").

-export([start/0, start/1, stop/1]).
-export([data/3]).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
            terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-define(SWITCH_MAGIC, 16#feedface).
-define(UML_VERSION, 3).
-define(REQ_NEW_CONTROL, 0).

-record(state, {
    uml_dir = ?UML_DIR,
    pid,
    path,
    sun,
    s
}).


start() ->
    start_link(self() ).
start(Pid) when is_pid(Pid) ->
    start_link(Pid).

stop(Ref) ->
    gen_server:call(Ref, stop).

data(Ref, Socket, Data) ->
    gen_server:call(Ref, {data, Socket, Data}).

start_link(Pid) ->
    gen_server:start_link(?MODULE, [Pid], []).

init([Pid]) ->
    process_flag(trap_exit, true),
    Path = ?UML_DIR ++ "/evum.ctl",

    {ok, Socket} = procket:socket(?PF_LOCAL, ?SOCK_STREAM, 0),
    ok = procket:setsockopt(Socket, ?SOL_SOCKET, ?SO_REUSEADDR, <<1:32/native>>),

    Sun = list_to_binary([
            <<?PF_LOCAL:16/native>>,
            Path,
            <<0:((?UNIX_PATH_MAX-length(Path))*8)>>
        ]),

    ok = procket:bind(Socket, Sun),
    ok = procket:listen(Socket, 5),

    Server = self(),
    spawn_link(fun() -> accept(Server, Socket) end),

    {ok, #state{
        path = Path,
        s = Socket,
        sun = Sun,
        pid = Pid
        }}.


handle_call({data, Socket, Data}, _From, #state{s = _Socket, sun = _Sun} = State) ->
    error_logger:info_report({ctl, Socket, Data}),
    {reply, ok, State};

handle_call(stop, {Pid,_}, #state{pid = Pid} = State) ->
    {stop, shutdown, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{s = Socket, path = Path}) ->
    procket:close(Socket),
    file:delete(Path).
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------
%% Stream data from the ctl socket
%%--------------------------------------------------------------------
handle_info(Info, State) ->
    error_logger:error_report([{wtf, Info}]),
    {noreply, State}.


%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

% XXX this will leak the listener and accepted fd's
accept(Server, Listen) ->
    case procket:accept(Listen) of
        {error, eagain} ->
            timer:sleep(1000);
        {ok, Socket} ->
            spawn(fun() -> recv(Server, Socket) end)
    end,
    accept(Server, Listen).

% struct request_v3 {
%     uint32_t magic;
%     uint32_t version;
%     enum request_type type;
%     struct sockaddr_un sock;
% };
recv(Server, Socket) ->
    case procket:recvfrom(Socket, 16#FFFF) of
        eagain ->
            timer:sleep(10),
            recv(Server, Socket);
        {ok, <<>>} ->
            procket:close(Socket);
        {ok, <<?SWITCH_MAGIC:32/native, ?UML_VERSION:32/native, ?REQ_NEW_CONTROL:32/native, Sun/binary>>} ->
            error_logger:info_report([{connect_from, Sun}]),
            Data = evum_data:name(),
            case procket:sendto(Socket, Data, 0, <<>>) of
                ok ->
%                    data(Server, Socket, Buf),
                    recv(Server, Socket);
                _ ->
                    procket:close(Socket)
            end;
        % Unknown request
        {ok, <<Magic:32/native, Version:32/native, Type:32/native, Sun/binary>>} ->
            error_logger:info_report([
                    {unknown_request, evum_ctl},
                    {magic, Magic},
                    {magic, Magic},
                    {version, Version},
                    {type, Type},
                    {sun, Sun}
                ]),
            procket:close(Socket);
        Error ->
            error_logger:info_report([{error, Error}]),
            procket:close(Socket)
    end.


