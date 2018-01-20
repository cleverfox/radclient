-module(radius_client_test).
-author("Vladimir Goncharov").
-export([test/2,test1/2,test2/2,test3/2]).

test(IPAddr,Passwd) ->
    io:format("Test 1: Only one radius_client~n"),
    [T1a,T1b,T1c]=test1(IPAddr,Passwd),
    io:format("Test 1 result: ~nAuth ~p~nAuth2 ~p~nAcct ~p~n",[T1a,T1b,T1c]),
    io:format("Test 2: radius_client over radius_dispatcher~n"),
    T2=test2(IPAddr,Passwd),
    io:format("Test 2 result: Auth ~p~n",[T2]),
    ok.

test1(IPAddr,Passwd) ->
    %{ok,Pid}=gen_server:start_link({local, rad_test}, radius_client, [], []),
    io:format("Start single client~n"),
    {ok,Pid}=radius_client:start(),
    io:format("Add server~n"),
    gen_server:call(Pid,
                    {add_server, 0, {127,0,0,1}, {1812,1813}, "bsrdev", 100, 2} %bad server
                   ),
    io:format("Add one more server~n"),
    gen_server:call(Pid,
                    {add_server, 2, IPAddr, {1812,1813}, Passwd, 2000, 3}
                   ),
    RID=1,
    io:format("Plan ~p~n",[ gen_server:call(Pid,fetch_req_plan)]),
    AVP2=[{1,"IPoE_172.20.82.51"},{{12344,1},{172,20,82,51}},{61,15},{7,10} ],
    AVP=[{1,"testuser"},
	 {2,"testpass"},
	 {61,15},{7,10}],
    io:format("Make auth request ~p~n",[AVP]),
    %Res=gen_server:call(Pid, {send,0,{1,1,AVP}}),
    Res=radius_client:make_request(Pid,auth,RID,AVP,8),
    io:format("Make auth request ~p~n",[AVP2]),
    Res2=radius_client:make_request(Pid,auth,RID,AVP2,8),

    AVPacct=[{1,"testuser"},{40,3},{45,2},{46,100},{42,1000},{47,10},{43,2000},{48,20},{8,{10,10,10,10}},
	     {4,{10,0,0,1}} ],
    io:format("Make acct request ~p~n",[AVPacct]),
    Res3=radius_client:make_request(Pid,acct,RID,AVPacct,8),
    io:format("Stop client~n"),
    gen_server:cast(Pid,stop),
    [{auth_check,Res},{auth_check2,Res2},{acct_check,Res3}].

test2(IPAddr,Passwd) ->
    io:format("Start dispatcher~n"),
    radius_dispatcher:start(),
    io:format("Add server~n"),
    gen_server:call(radius_dispatcher,{add_server, 300,
                                       IPAddr, {1812,1813},
                                       Passwd, 1000, 2}),
    io:format("Alloc ID~n"),
    gen_server:call(radius_dispatcher,alloc),
    io:format("Add another server~n"),
    gen_server:call(radius_dispatcher,{add_server, 3, IPAddr,
                                       {1812,1813}, Passwd, 1000,
                                       2}),
    AVP=[{1,"testuser"},{2,"testpass"},{61,15},{7,10}],
    io:format("Make auth request ~p~n",[AVP]),
    Res=radius_dispatcher:radius_request(auth,AVP,5),
    gen_server:cast(radius_dispatcher,stop),
    Res.
    
test3(IPAddr,Passwd) ->
    %{ok,Pid}=gen_server:start_link({local, rad_test}, radius_client, [], []),
    io:format("Start single client~n"),
    {ok,Pid}=radius_client:start(),
    io:format("Add one more server~n"),
    gen_server:call(Pid,
                    {add_server, 2, IPAddr, {1812,1813}, Passwd, 2000, 3}
                   ),
    RID=1,
    AVP2=[{1,"IPoE_172.20.82.51"},{{12344,1},{172,20,82,51}},{61,15},{7,10}],
    io:format("Make auth request ~p~n",[AVP2]),
    Res=radius_client:make_request(Pid,auth,RID,AVP2,8),
    io:format("Stop client~n"),
    gen_server:cast(Pid,stop),
    Res.


