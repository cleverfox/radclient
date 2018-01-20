-module(radius_client).
-author("Vladimir Goncharov").
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]). 
-export([handle_info/2, terminate/2, code_change/3]).

-export([start/0, stop/0, make_request/5, make_request/4]).
-export([attr2int/1, attr2addr/1]).

-record(radmux, { port, servers=[], pending=dict:new(), seq=0 }).


make_request(Pid, Type, ID, AVP) ->
    make_request(Pid,Type,ID,AVP,1).

make_request(Pid, Type, ID, AVP, Retry) ->
    case gen_server:call(Pid,fetch_req_plan) of
        {ok,Plan} -> 
            make_request(Pid, Type, ID, AVP, Retry, Plan);
        _ -> 
            {radius, error, cant_get_plan}
    end.

make_request(_, _, _, _, 0, _) -> 
    {radius, error, retry_limit_reached};

make_request(_, _, _, _, _, []) -> 
    {radius, error, server_unavailable};

make_request(Pid, Type, ID, AVP, Try, [S | Plan]) -> 
    case gen_server:call(Pid, {send,S,{Type,ID,AVP}}) of
        {radius, timeout, _, _} -> 
            make_request(Pid, Type, ID, AVP, Try-1, Plan);
        Any ->
            Any
    end.

ip2bin({A,B,C,D}) -> 
    <<A:8/integer,B:8/integer,C:8/integer,D:8/integer>>.

attr2pkt({{Vendor, Attr}, Value}) when is_binary(Value) -> 
    Vl= byte_size(Value)+2,
    Len=Vl+6,
    <<26:8, Len:8, Vendor:32, Attr:8, Vl:8, Value/binary>>;

attr2pkt({Attr, Value}) when is_binary(Value) -> 
    Len= byte_size(Value)+2,
    <<Attr:8, Len:8, Value/binary>>;

attr2pkt({Attr, Value}) when is_list(Value) -> 
    attr2pkt({Attr, binary:list_to_bin(Value)});

attr2pkt({Attr, Value}) when is_integer(Value) -> 
    attr2pkt({Attr, <<Value:32/integer>>});

attr2pkt({Attr, Value={_,_,_,_}}) ->
    attr2pkt({Attr, ip2bin(Value)}).

mxor(<<>>,_) -> <<>>;
mxor(_,<<>>) -> <<>>;
mxor(<<A:8/integer, Ra/binary>>,<<B:8/integer, Rb/binary>>) ->
    <<(A bxor B):8/integer, (mxor(Ra, Rb))/binary>>.

encPass(EKey, Pass) ->
    L=length(Pass),
    PPass=binary:list_to_bin(Pass ++ lists:duplicate(16-L, 0)),
    mxor(PPass,EKey).

attrs2pkt([],_) ->  <<>>;

attrs2pkt([Data|Rest],EKey) -> 
    P1=case Data of
        {2, Pass} -> 
               attr2pkt({2, encPass(EKey, Pass)});
           _ -> 
               attr2pkt(Data)
       end,
    P2 = attrs2pkt(Rest,EKey),
    << P1/binary, P2/binary >>.

pkt2attr(<<26,_L1:8/integer,Vendor:32/integer,Attr:8/integer,Vl:8/integer,Rest/binary>>) ->
    L2=Vl-2,
    <<Value:L2/binary,Rest2/binary>>=Rest,
    [{{Vendor,Attr},Value}] ++ pkt2attr(Rest2);

pkt2attr(<<StdAttr:8/integer,Len:8/integer,Rest/binary>>) ->
    L2=Len-2,
    <<Value:L2/binary,Rest2/binary>>=Rest,
    [{StdAttr,Value} | pkt2attr(Rest2)];

pkt2attr(<<>>) -> []; 
pkt2attr(A) -> 
    lager:error("Error: Unmatched pkt data~p",[A]),
    []. 

genAuth(0) -> <<>>;
genAuth(L) -> 
    M=genAuth(L-1),
    R=rand:uniform(4)-1,
    <<R:8/integer,M/binary>>.

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    init([[]]);

init([Server|_]) ->
%    process_flag(trap_exit, true),
    {ok,Port}=gen_udp:open(0,[{mode,binary}]),
    {ok,#radmux{port=Port,servers=Server}}.

handle_call({add_server, ID, IP, Port, Secret, Timeout, Retry}, _From, State) -> 
    Srv=lists:keydelete(ID,1,State#radmux.servers),
    Srv2=lists:append([{ID,IP,Port,Secret,Timeout,Retry}],Srv),
    {reply, ok, State#radmux{servers=Srv2}};

handle_call({del_server, ID}, _From, State) -> 
    Srv=lists:keydelete(ID,1,State#radmux.servers),
    {reply, ok, State#radmux{servers=Srv}};

handle_call(fetch_req_plan, _From, State) -> 
            {reply, {ok, 
             lists:foldl(
               fun({ID,_,_,_,_,R},A)-> lists:duplicate(R,ID) ++ A end,
               [],
               State#radmux.servers)
            }, State};


handle_call(ping, _From, State) -> 
    {reply, pong, State};

handle_call(debug, _From, State) -> 
            {reply, {debug, State}, State};

handle_call({send, SrvID, {Type, ORI, Attrs}}, From, State) -> 
    case lists:keyfind(SrvID,1,State#radmux.servers) of
        {SrvID,ServerIP,{ServerPortAuth,ServerPortAcct},Secret,Timeout,_Retry} ->
            <<RI:8/integer>>= <<ORI:8/integer>>, %ensure Request Identifier only 8 bit
            {Auth,ServerPort}=case Type of
                           auth ->
                               LAuth=genAuth(16),
                               EKey=erlang:md5_final(erlang:md5_update(erlang:md5_update(erlang:md5_init(),Secret),LAuth)),
                               BinAttr=attrs2pkt(Attrs,EKey),
                               Len=byte_size(BinAttr)+20,
                               Bin= <<1:8/integer,RI:8/integer,Len:16/integer,LAuth/binary,BinAttr/binary>>,
                               gen_udp:send(State#radmux.port,ServerIP,ServerPortAuth,Bin),
                               {LAuth,ServerPortAuth};
                           acct -> 
                               Empty= <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
                               BinAttr=attrs2pkt(Attrs,Empty),
                               Len=byte_size(BinAttr)+20,
                               MD51=erlang:md5_update(erlang:md5_init(),
                                                             <<4:8/integer,RI:8/integer,Len:16/integer,Empty:16/binary>>
                                                            ),
                               LAuth=erlang:md5_final(
                                       erlang:md5_update(
                                         erlang:md5_update(MD51,BinAttr),Secret)),
                               Bin= <<4:8/integer,RI:8/integer,Len:16/integer,LAuth/binary,BinAttr/binary>>,
                               gen_udp:send(State#radmux.port,ServerIP,ServerPortAcct,Bin),
                               {LAuth,ServerPortAcct};
                           _ -> 
                               error
                       end,
            Key={ServerIP,ServerPort,RI},
            Seq=State#radmux.seq+1,
            {ok,Timer}=timer:send_after(Timeout,{reqtimeout, Key, Seq}),
            Pend2=dict:append(Key,{Type,RI,Auth,Attrs,From, Seq, Timer, SrvID},State#radmux.pending),
            {noreply, State#radmux{pending=Pend2,seq=Seq}};
        false ->
            {reply, {error, bad_server_id}, State}
    end;

handle_call(_Message, _From, State) -> 
    {reply, error, State}.

stop() ->
    gen_server:cast(?MODULE, stop).

terminate(shutdown, _State) -> 
    ok;

terminate(normal, _State) -> 
    ok.

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Message, Dictionary) -> 
    {noreply, Dictionary}.

handle_info({reqtimeout, Key, Seq}, State) -> %request timeout
    K=dfetch(Key,State#radmux.pending),
    case K of 
        [{_OType,PRI,_OAuth,_OAttr,From, Seq, _, _SrvID}] -> 
            Res={radius, timeout, PRI,[]},
            gen_server:reply(From,Res),
            Pend2=dict:erase(Key,State#radmux.pending),
            {noreply, State#radmux{pending=Pend2}};
        _ -> 
            {noreply, State}
    end;

handle_info({udp, _, SrcIP, SrcPort, Data}, State) -> %response
    <<PType:8/integer,PRI:8/integer,PLen:16/integer,PAuth:16/binary,PAttrs/binary>>=Data,
    Key={SrcIP,SrcPort,PRI},
    K=dfetch(Key,State#radmux.pending),
    case K of 
        [{_OType,_ORI,OAuth,_OAttr,From, _Seq, Timer, SrvID}] -> 
            timer:cancel(Timer),
            Secret = case lists:keyfind(SrvID,1,State#radmux.servers) of
                         {SrvID,_,_,FSecret,_Timeout,_Retry} -> FSecret;
                         _ -> "removed_server"
                     end,
            AuthPkt= <<PType:8/integer,PRI:8/integer,PLen:16/integer>>,
            MyAuth=erlang:md5_final(
                     erlang:md5_update(
                       erlang:md5_update(
                         erlang:md5_update( 
                           erlang:md5_update(
                             erlang:md5_init(),
                             AuthPkt) ,
                           OAuth),
                         PAttrs),
                       Secret)
                    ),
            lager:debug("Response key ~n~p~nExpected~n ~p~n~p", [PAuth,MyAuth,AuthPkt]),
            case PAuth of
                MyAuth ->
                    PTypeAtom = case PType of
                                    1 -> auth;
                                    2 -> auth_accept;
                                    3 -> auth_reject;
                                    4 -> acct;
                                    5 -> acct_response
                                end,
                    Res={radius, PTypeAtom,PRI,pkt2attr(PAttrs)},
                    gen_server:reply(From,Res),
                    Pend2=dict:erase(Key,State#radmux.pending),
                    {noreply, State#radmux{pending=Pend2}};
                _ -> 
                    lager:error("Error: Bad response from ~p ~p or shared key mismatch", [SrcIP,SrcPort]),
                    {noreply, State}
            end;
        _ -> 
            %io:format("Session ~p not found~n",[Key]),
            {noreply, State}
    end;

handle_info(_Message, Dictionary) -> 
    {noreply, Dictionary}.

code_change(_OldVersion, Dictionary, _Extra) -> {ok, Dictionary}.

dfetch(Key,Dict) ->
    case dict:is_key(Key, Dict) of
        true -> dict:fetch(Key, Dict);
        _ -> false
    end.

attr2int({_Attr, Value}) when is_binary(Value) ->
    <<V:32/integer>>=Value,
    V;

attr2int({_Attr, Value}) when is_integer(Value) ->
    Value.

attr2addr({_Attr, Value}) when is_binary(Value) ->
    <<A:8/integer,B:8/integer,C:8/integer,D:8/integer>>=Value,
    {A,B,C,D};

attr2addr({_Attr, Value}) when is_integer(Value) ->
    <<A:8/integer,B:8/integer,C:8/integer,D:8/integer>> = <<Value:32/integer>>,
    {A,B,C,D};

attr2addr({_Attr, Value}) when is_tuple(Value) ->
    Value.

