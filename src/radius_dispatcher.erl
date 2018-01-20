-module(radius_dispatcher).
-author("Vladimir Goncharov").
-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2]). 
-export([handle_info/2, terminate/2, code_change/3]).
-export([start/0, stop/0, radius_request/3]).

-record(rad_disp,{free_slots=[],used_slots=dict:new(),servers=[],workers=[]}).

start() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    gen_server:cast(self(),read_config),
    {ok,#rad_disp{}}.

new_worker(State) ->
    {ok,Pid} = gen_server:start_link(radius_client, [State#rad_disp.servers], []),
    NewSlots = [{Pid, X} || X <- lists:seq(1,254)],
    State#rad_disp{free_slots=State#rad_disp.free_slots ++ NewSlots,
                   workers=State#rad_disp.workers ++ [Pid] }.

radius_request(Type,AVP,Retry) ->
    radius_request(Type,AVP,Retry,3).

radius_request(Type,AVP,Retry,Restart) ->
    {ok, {Pid,ID}}=case get(current_radius_client) of
        undefined -> 
            P=gen_server:call(radius_dispatcher,alloc),
            put(current_radius_client,P),
            P;
        P1 -> P1
    end,
    case catch radius_client:make_request(Pid,Type,ID,AVP,Retry) of
       {'EXIT',{noproc,_}} -> erase(current_radius_client),
                     radius_request(Type,AVP,Retry,Restart-1);
        N -> N
    end.
    

cleanup_worker(Pid,State) ->
    %Clean up free and used slots, beacuse worker dead
    NewFree=lists:filter(
              fun(V)-> 
                      case V of 
                          {Pid,_} -> false; 
                          _ -> true 
                      end end, 
                      State#rad_disp.free_slots),
    NewWrk=lists:filter(
              fun(V)-> 
                      case V of 
                          Pid -> false; 
                          _ -> true 
                      end end, 
                      State#rad_disp.workers),
    NewDict=dict:filter(
              fun(_,V)-> 
                      case V of 
                          [{Pid,_}] -> false; 
                          _ -> true
                      end end, 
              State#rad_disp.used_slots),
    State#rad_disp{free_slots=NewFree,used_slots=NewDict,workers=NewWrk}.

handle_call(AS={add_server, _ID, _IP, _Port, _Secret, _Timeout, _Retry}, _From, State) -> 
    Srv2=add_server(AS,State#rad_disp.servers,State#rad_disp.workers),
    {reply, ok, State#rad_disp{servers=Srv2}};

handle_call(AS={del_server, ID}, _From, State) -> 
    Srv=lists:keydelete(ID,1,State#rad_disp.servers),
    lists:foreach(fun(WPid) -> 
                          case catch gen_server:call(WPid,AS) of
                              {'EXIT', _, _} -> fail;
                              _ -> ok
                          end
                  end,State#rad_disp.workers),
    {reply, ok, State#rad_disp{servers=Srv}};

handle_call(ping, _From, State) -> 
    {reply, pong, State};

handle_call(debug, _From, State) -> 
    {reply, {debug,State}, State};

handle_call(alloc, {Pid, Ref}, State) -> 
    case dict:is_key(Pid, State#rad_disp.used_slots) of 
        true ->
            [{Wrk,RID}] = dict:fetch(Pid, State#rad_disp.used_slots),
            case is_process_alive(Wrk) of
                true -> 
                    {reply, {ok, {Wrk,RID}}, State};
                false ->
                    %State2=State#rad_disp{used_slots=dict:erase(Pid,State#rad_disp.used_slots)},
                    State3=cleanup_worker(Wrk,State),
                    handle_call(alloc, {Pid, Ref}, State3)
            end;
        _ ->
            State2 = case length(State#rad_disp.free_slots) of
                         0 -> new_worker(State);
                         _ -> State
                     end,
            case length(State2#rad_disp.free_slots) of
                0 -> 
                    {reply, error, State2};
                _ -> 
                    {[ Pop ], LWrk}=lists:split(1,State2#rad_disp.free_slots),
                    D2=dict:append(Pid,Pop,State2#rad_disp.used_slots),
                    {reply, {ok, Pop}, State2#rad_disp{free_slots=LWrk,used_slots=D2}}
            end
    end;


handle_call(_Message, _From, State) -> 
    {reply, error, State}.

stop() ->
    gen_server:cast(?MODULE, stop).

terminate(shutdown, _State) -> 
    lager:info("Terminate shutdown ~s~n",[?MODULE]),
    ok;

terminate(normal, _State) -> 
    ok.

handle_cast(read_config, State) ->
    case application:get_env(obsrd,radius_server) of
        {ok, CONF} ->
            Srv1=lists:foldl(fun({ID,IP,Port,Secret,Timeout,Retry},Sr0) ->
                               add_server({add_server, ID, IP, Port,
                                           Secret, Timeout,
                                           Retry},Sr0,State#rad_disp.workers)
                       end,
                       State#rad_disp.servers,
                       CONF),
            {noreply, State#rad_disp{servers=Srv1}};
        _ -> {noreply, State}
    end;

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Message, State) -> 
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, State) -> 
    State2=cleanup_worker(Pid,State),
    {noreply, State2};

handle_info(_Message, State) -> 
    {noreply, State}.

code_change(_OldVersion, State, _Extra) -> 
    {ok, State}.


add_server(AS={add_server, ID, IP, Port, Secret, Timeout, Retry},Srv0,Wrk) ->
    Srv=lists:keydelete(ID,1,Srv0),
    lists:foreach(fun(WPid) -> 
                          case catch gen_server:call(WPid,AS) of
                              {'EXIT', _, _} -> fail;
                              _ -> ok
                          end
                  end,Wrk),
    Srv ++ [{ID,IP,Port,Secret,Timeout,Retry}].


