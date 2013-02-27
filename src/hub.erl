%% Module "hub"
%%
%% Repurposed from RemoteRadio and Echo (C) 1995-2013 Garth Hitchens, KG7GA
%% All Rights Reserved (for now).
%% 
%% License granted to Rose Point Navigation Systems for use in their 
%% network interface translator box. 
%%
%% The system core that distributes that ", which is the core of the system
%% Processes can publish state on the bus, sPathubscribe to state changes,
%% request information about the state of the bus, and request changes
%% to the state.
%%
%% A hub is a process (a gen_server, actually) that holds state for the
%% system, manages changes to state, and and routes notifications of 
%% changes of state.
%%
%% The hub keeps a sequence ID for each change to state, and this is 
%% stored as part of the state graph, so that the hub can answer the
%% question:  "show me all state that has changed since sequence XXX"
%%
%%
%% ** Limitations and areas for improvement **
%%
%% Right now the store is only in memory, so a restart removes all data
%% from the store.
%%
%% There is currently no change history or playback history feature.
%%
%% [{key,val},{key,val}...]
%%
%% some special keys that can appear on any resource
%%
%%	_useq		sequence ID of the last update to this resource
%%	_deps		list of dependents to be informed

-module(hub).
-behaviour(gen_server).

%% Exports to conform to gen_server behaviour

-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, 
		 terminate/2]).

%% record definitions for hub's state tree %%

-record(state, { 
	tseq 	= 0, 						% transaction sequence id
	store 	= orddict:new()				% the storage tree
	}).				 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%  gen_server callbacks %%%%%%%%%%%%%%%%%%%%%%%%%%%

init() -> 
	{ok, #store{}}. 

terminate(normal, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) -> 
	{ok, State}.

% handle_info/cast/call clauses delegate for hub specific handlers

handle_info({notify, Msg}, State) -> 
	handle_notify(Msg, State);
handle_info(Msg, State) ->
    io:format("Unexpected message: ~p~n",[Msg]),
    {noreply, State}.

handle_cast(return, State) -> 
	{noreply, State}.

handle_call(getstate, _From, State) -> 
	{reply, { state, State}, State};
handle_call(terminate, _From, State) -> 
	{stop, normal, ok, State};
handle_call({subscribe, Key}, From, State) ->
	handle_subscribe(Key, From, State);
handle_call({request, Key, Req}, From, State) -> 
	handle_request(Key, Req, From, State).
	
%%%%%%%%%%%%%%%%%%%%%%%% hub specific call requests %%%%%%%%%%%%%%%%%%%%%%%%%%%

%% request
%%
%% ask a node to do something, like change a value for a key, delete a key,
%% whatever.  This is forwarded to the node origin.

handle_request(Key, Req, From, State) when is_atom(Key) ->
    case orddict:find(Key, State#state.dd) of 
        {ok, Ref} when is_pid(Ref) -> 
             gen_server:call({setprop, Ref, NewValue)
        _Else ->        {reply, {error, badkey}}
 
handle_subscribe_call(subscribe, From, State) -> % { reply, Reply, NewState }
    {reply, ok, State#state{subscriptions=tattle_event:subscribe(
        State#state.subscriptions, From)}};
       

%%%%%%%%%%%%%%%%%%%%%%%%%% state tree implementation %%%%%%%%%%%%%%%%%%%%%%%%%

subscribe(Ref) ->
	gen_server:call(Ref, subscribe).

%% store(Node, foo, bar)				[{foo,bar}]
%% store(Node, [foo, bar], baz)			[{foo,[{bar,baz}]}]
%% returns {status, {tree, ....}}
store(_Tree, [], _Value) -> true;
store(Tree, [Key|Kr], Value) ->
	{tree, Dict} = Tree,
	% if a subtree already exists then use it otherwise create a new one
	SubTree = case orddict:find(Key, Dict) of
		error -> new();
		{ok, X} -> X
	end,
	% store the new key/value
	case Kr of
		[] -> {ok, nil};
		_ ->			
			{_Status, NewSubTree} = store(SubTree, Kr, Value),
			store(Tree, Key, NewSubTree)
	end;
store(Hub, Key, NewValue) -> 
	{tree, Dict} = Tree,
	case orddict:find(Key, Dict) of
		{ok, NewValue} -> 
			{unchanged, Tree};
		{ok, OldValue} ->
			{changed, {tree, orddict:store(Key, NewValue, Dict)}};
		error -> 
			{created, {tree, orddict:store(Key, NewValue, Dict)}}
	end.		

%% {request, Request}
%% {setprop, Key, Value}
%% 
%% Try to set the property Key 


%% handle_call callbacks 





%%
%% given a list of proposed changes, update the state and only notify the
%% client about attributes that actually change state!
%% If no attribute actually changes, don't send any event at all.
%%

update_dd_and_inform(Proposed, State) -> % State
    UF = fun(Key, Value, {Changes, Dict}) -> % {Changes, Dict}
        case orddict:find(Key, Dict) of  
            {ok, Value} ->      {Changes, Dict};
            _Else ->            {(Changes++[{Key, Value}]), 
                                 orddict:store(Key,Value,Dict)}
        end
    end,
    {Actual, NewDict} = orddict:fold(UF, {[], State#state.dd}, Proposed),
    case Actual of 
        [] -> State; 
        _Else -> 
            tattle_event:deliver({ddupdate, Actual}, State#state.subscriptions),
            State#state{dd=NewDict} 
    end.

%% NOTIFICATIONS %%

handle_notify({rxframe, Frame}, State) -> % {noreply, State}
    {ok, Changes} = handle_device_frame(Frame),
    {noreply, update_dd_and_inform(Changes, State)};

handle_notify(SomeOtherMessage, State) -> 
    tattle_event:deliver(SomeOtherMessage, State#state.subscriptions),
    {noreply, State}.

----

-module(tattle_event).
-export([subscriber_collection/0, subscribe/2, deliver/2]).

%% SUBSCRIBERS (MUST SUPPORT GEN_SERVER) %%

subscriber_collection() -> [].

subscribe(Subscriptions, From) -> 
    Subscriptions ++ [From].

deliver(_, []) -> true;
deliver(Message, [H|T]) ->
    { Pid, _Key } = H,
    Pid ! {notify, Message},
    deliver(Message, T).


