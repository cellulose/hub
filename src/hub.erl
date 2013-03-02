%% Module "hub"
%%
%% Implements a heirarchial key-value store with publish/subscribe semanitcs
%% at each node of the heirarchy.   Plans to support timestamping, 
%% version stamping, real-time playback, security,
%%
%% The hub holds a collection of dnodes (dictionary nodes).  Each dictionary
%% node is a key/value store, where the keys are atoms, and the values
%% are any erlang term.  Sometimes the value is also a dnode, which results 
%% in a heirarchy.
%%
%% Processes publish state on a hub, subscribe to state changes,
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
%% if a value at any given path is a proplist (tested as a list whose first
%% term is a tuple, or an empty list).
%%
%% some special keys that can appea
%%
%%	useq@		sequence ID of the last update to this resource
%%	subs@		list of dependents to be informed
%%
%% LICENSE
%%
%% Repurposed from RemoteRadio, (C) Copyright 1996-2012 Garth Hitchens, KG7GA,
%% and Echo, (C) Copyright 2012-2013 Garth Hitchens, All Rights Reserved
%% 
%% License explicitly granted to Rose Point Navigation Systems, LLC, for use 
%% in the NEMO network translator box.   For other uses contact the Author.

-module(hub).
-behaviour(gen_server).

%% Exports to conform to gen_server behaviour

-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, 
		 terminate/2]).
-export([request/4, update/4, subscribe/3, lookup/2, deltas/3]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%% Record Definitions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% dnodes are the core of the hub's storage and state mechanism

-record(state, { 
			gtseq 	= 0, 						% global transaction sequence #
			dtree 	= orddict:new()				% the dictionary tree
		}).				 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%  Public API %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% request something from the origin of this point
request(Hub, Path, Request, Auth) ->
	{ok, Origin} = gen_server:call(Hub, {get_origin, Path}),
	gen_server:call(Origin, {request, Request, Auth, self(), Hub, Path}).

%% update the hub's dictionary tree and send notifications
update(Hub, Path, Changes, Auth) ->
	gen_server:call(Hub, {update, Path, Changes, Auth}).

%% get informed when something happens to this point or children
subscribe(Hub, Path, SubscriptionOpts) ->
	gen_server:call(Hub, {subscribe, Path, SubscriptionOpts}).

lookup(Hub, Path) 			-> gen_server:call(Hub, {lookup, Path}).		
deltas(Hub, Seq, Path) 		-> gen_server:call(Hub, {deltas, Seq, Path}).		

%%%%%%%%%%%%%%%%%%%%%%%%%%%% gen_server callbacks %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(_Args) -> 
	{ok, #state{}}. 

terminate(normal, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) -> 
	{ok, State}.

% handle_info/cast/call clauses, &  delegate for hub specific handlers

handle_info(Msg, State) ->
    io:format("Unexpected message: ~p~n",[Msg]),
    {noreply, State}.

handle_cast(return, State) -> 
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%% handle_call %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_call(terminate, _From, State) -> 
	{stop, normal, ok, State};

handle_call({subscribe, Path, Opts}, From, State) ->
	Seq = State#state.gtseq + 1,
	case add_subscription(Path, {From, Opts}, State#state.dtree, Seq) of
		{ok, Tnew} -> {reply, ok, State#state{dtree=Tnew, gtseq=Seq}};
		_ -> {reply, error, State}
	end;

handle_call({request, _Key, _Req}, _From, State) -> 
	{reply, ok, State};

handle_call({update, Path, ProposedChanges, Auth}, From, State) ->
	Seq = State#state.gtseq + 1,
	{ResultingChanges, NewTree} = do_update(
		Path, 
		ProposedChanges, 
		State#state.dtree, 
		{Seq, [{from, From}, {auth, Auth}]}),
	{reply, 
		{changes, ResultingChanges}, 
		State#state{dtree=NewTree, gtseq=Seq}};
	
handle_call({lookup, Path}, _From, State) -> 
	{reply, do_lookup(Path, State#state.dtree), State};

handle_call({deltas, Seq, Path}, _From, State) -> 
	{reply, do_deltas(Seq, Path, State#state.dtree), State}.
	
%%%%%%%%%%%%%%%%%%%%%%%%%% state tree implementation %%%%%%%%%%%%%%%%%%%%%%%%%

%% add_subscription(Path, Subscription, Tree)
%% 
%% Subscription is a {From, SubscribeParameters} tuple that is placed on
%% the subs@ key at a node in the dtree.  Adding a subscription doesn't
%% currently cause any notificaitions, although that might change.
%%
%% REVIEW: could eventually be implemented as a special form of update by
%% passing something like {append, Subscription, [notifications, false]}
%% as the value, or maybe something like a function as the value!!! cool?

add_subscription([], Subscription, T, Seq) ->
	Subs = case orddict:find(subs@, T) of 
		{ok, {L, _Seq}} -> L;
		_ -> orddict:new()
	end,
	{ok, orddict:store(subs@, {(Subs ++ [Subscription]), Seq}, T)};
		
add_subscription([PH|PT], Subscription, T, Seq) -> 
	case orddict:find(PH, T) of 
		{ok, {ST, _Seq}} when is_list(ST) ->
			case add_subscription(PT, Subscription, ST, Seq) of
				{ok, STnew} ->
					{ok, orddict:store(PH, {STnew, Seq}, T)};
				_ -> error
			end;
		error -> error
	end.

%% update(PathList,ProposedChanges,Tree,Context) -> {ResultingChanges,NewTree}
%%
%% Coding Abbreviations:
%%
%% PC,RC	Proposed Changes, Resulting Changes (these are trees)
%% P,PH,PT	Path/Path Head/ Path Tail
%% T,ST		Tree,SubTree
%% C		Context - of the form {Seq, Whatever} where whatever is 
%%			any erlang term - gets threaded unmodified through update
	
do_update([], PC, T, C) -> 
	%io:format("update([],~p,~p)\n\n", [PC, T]),
    UF = fun(Key, Value, {RC, Dict}) -> % {RC, Dict}
        case orddict:find(Key, Dict) of  
            {ok, {Value, _}} ->		% already the value we are setting
				{RC, Dict};
            _Else when is_list(Value) -> 	% we're setting a proplist
				{RCsub, NewDict} = do_update([Key], Value, Dict, C),
				{(RC++RCsub), NewDict};
			_Else -> 
				{Seq, _} = C, 
				{(RC++[{Key, Value}]), orddict:store(Key,{Value, Seq},Dict)}
        end
    end,
    { CL, Tnew } = orddict:fold(UF, {[], T}, PC),
	send_notifications(CL, Tnew, C),
	{ CL, Tnew };
	
do_update([PH|PT], PC, T, C) ->
	% we still have a path, so update a subtree of the given tree
	ST = case orddict:find(PH, T) of 
		{ok, {L, _}} when is_list(L) ->  L;	% found existing subtree
		{ok, _} -> 	% replace current non-list value with new subtree
			orddict:new();  
		error -> 	% add new subtree (key didn't exist before)
			orddict:new() 
	end,	
	% recurse to update the subtree 
	{RCsub, STnew} = do_update(PT, PC, ST, C),
	RC = case RCsub of
		[] -> [];
		Y ->  [{PH, Y}]
	end,	
	% store sequence number for this change
	{Seq, _} = C, 
	% store new subtree and sequence number 
	T1 = orddict:store(PH, {STnew, Seq}, T),
	send_notifications(RC, T1, C),
	{ RC, T1 }.

%% do_lookup(Path, Tree) -> Tree
%%
%% Lookup the state dictionary tree at a given path.  Returns the entire
%% tree, including subscription and version information.

do_lookup([], Tree) -> 
	Tree;
	
do_lookup([PH|PT], Tree) ->
	case orddict:find(PH, Tree) of
		{ok, {SubTree, _V}} -> do_lookup(PT, SubTree);
		_Else -> error
	end.

%% do_deltas(Since, Path, Tree) -> ChangeTree
%%
%% returns a tree of changes that happened since the specified sequence.
%% if a non-empty path is specified, returns changes relative to that path.

do_deltas(Since, [], Tree) ->
	% FN to filter a list of nodes whose seq# is higher than Since
	FNfilter = fun(_Key, {_Val, Seq}) -> (Seq > Since) end,
    % function to map subnodes to recurse to do_deltas
	FNrecurse = fun(Key, {Val, _Seq}) ->
		case {Key, Val} of 
			{subs@, _} ->  Val;
			{_, L} when is_list(L) -> do_deltas(Since, [], L);
			_ -> Val
		end
	end,
	orddict:map(FNrecurse, orddict:filter(FNfilter, Tree));

do_deltas(Since, [PH|PT], Tree) ->
	case orddict:find(PH, Tree) of
		{ok, {SubTree, _V}} -> do_deltas(Since, PT, SubTree);
		_Else -> error
	end.
	
%% send notifications about some changes to subscribers

send_notifications([], _, _) ->
	pass;

send_notifications(Changes, Tree, Context) ->
	case orddict:find(subs@, Tree) of
		{ok, {Subs, _}} when is_list(Subs) ->
			lists:map(fun(Sub)-> notify_sub(Sub, Changes, Context) end, Subs);
		_ -> pass
	end.	

%% decalled by send_notifications to notify this subscription of activity
%% that is relevant to it
notify_sub(Subscription, Changes, Context) ->
    {{ Pid, _Key }, SubscriptionInfo} = Subscription,
    Pid ! {notify, SubscriptionInfo, Changes, Context}.

