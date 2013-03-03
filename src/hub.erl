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

-export([start_link/0, start/0]).
-export([request/3, update/2, update/3, 
	     subscribe/2, unsubscribe/1, 
		 fetch/0, fetch/1, dump/0, dump/1, deltas/1, deltas/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%% Record Definitions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% dnodes are the core of the hub's storage and state mechanism

-record(state, { 
			gtseq 	= 0, 						% global transaction sequence #
			dtree 	= orddict:new()				% the dictionary tree
		}).				 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%  Public API %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

%% request something from the origin of this point
request(Path, Request, Auth) ->
	{ok, Origin} = gen_server:call(?MODULE, {get_origin, Path}),
	gen_server:call(Origin, {request, Request, Auth, self(), ?MODULE, Path}).

%% update the hub's dictionary tree and send notifications
update(Path, Changes, Context) ->
	gen_server:call(?MODULE, {update, Path, Changes, Context}).

update(Path, Changes) -> 	update(Path, Changes, []).

%% get informed when something happens to this point or children
subscribe(Path, Subscription) ->
	gen_server:call(?MODULE, {subscribe, Path, Subscription}).

%% remove the calling process from the subscription list for that path
unsubscribe(Path) ->
	gen_server:call(?MODULE, {unsubscribe, Path}).

dump(Path) ->			gen_server:call(?MODULE, {dump, Path}).		
dump() -> 				dump([]).
fetch(Path) ->			deltas(0, Path).
fetch() -> 				fetch([]).
deltas(Seq, Path) -> 	gen_server:call(?MODULE, {deltas, Seq, Path}).		
deltas(Seq) -> 			deltas(Seq, []).

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
	case do_subscribe(Path, {From, Opts}, State#state.dtree) of
		Tnew when is_list(Tnew) -> 
			{reply, ok, State#state{dtree=Tnew}};
		_ -> 
			{reply, error, State}
	end;

handle_call({unsubscribe, Path}, From, State) ->
	case do_unsubscribe(Path, From, State#state.dtree) of
		Tnew when is_list(Tnew) -> 
			{reply, ok, State#state{dtree=Tnew}};
		_ -> 
			{reply, error, State}
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
	
handle_call({dump, Path}, _From, State) -> 
	{reply, 
		{State#state.gtseq, do_dump(Path, State#state.dtree)}, 
		State};

handle_call({deltas, Seq, Path}, _From, State) -> 
	{reply, 
		{State#state.gtseq, do_deltas(Seq, Path, State#state.dtree)}, 
		State}.
	
%%%%%%%%%%%%%%%%%%%%%%%%%% state tree implementation %%%%%%%%%%%%%%%%%%%%%%%%%

%% do_subscribe(Path, Subscription, Tree)
%% 
%% Subscription is a {From, SubscribeParameters} tuple that is placed on
%% the subs@ key at a node in the dtree.  Adding a subscription doesn't
%% currently cause any notificaitions, although that might change.
%%
%% REVIEW: could eventually be implemented as a special form of update by
%% passing something like {append, Subscription, [notifications, false]}
%% as the value, or maybe something like a function as the value!!! cool?

do_subscribe([], {From, Opts}, Tree) ->
	{FromPid, _Ref} = From,
	Subs = case orddict:find(subs@, Tree) of 
		{ok, L} when is_list(L) -> 
			orddict:store(FromPid, Opts, L);
		_ -> 
			orddict:store(FromPid, Opts, orddict:new())
	end,
	orddict:store(subs@, Subs, Tree);
		
do_subscribe([PH|PT], {From, Opts}, Tree) -> 
	{ok, {Seq, ST}} = orddict:find(PH, Tree),
	STnew = do_subscribe(PT, {From, Opts}, ST),
	orddict:store(PH, {Seq, STnew}, Tree).

%% do_unsubscirbe(Path, Unsubscriber, Tree) -> Tree | notfound
%%
%% removes Unsubscriber from the dictionary tree

do_unsubscribe([], Unsub, Tree) ->
	{FromPid, _Ref} = Unsub,
	{ok, OldSubs} = orddict:find(subs@, Tree),
	orddict:store(subs@, orddict:erase(FromPid, OldSubs), Tree);

do_unsubscribe([PH|PT], Unsub, Tree) ->
	{ok, {Seq, ST}} = orddict:find(PH, Tree),
	STnew = do_unsubscribe(PT, Unsub, ST),
	orddict:store(PH, {Seq, STnew}, Tree).

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
            {ok, {_, Value}} ->		% already the value we are setting
				{RC, Dict};
            _Else when is_list(Value) -> 	% we're setting a proplist
				{RCsub, NewDict} = do_update([Key], Value, Dict, C),
				{(RC++RCsub), NewDict};
			_Else -> 
				{Seq, _} = C, 
				{(RC++[{Key, Value}]), orddict:store(Key, {Seq, Value}, Dict)}
        end
    end,
    { CL, Tnew } = orddict:fold(UF, {[], T}, PC),
	send_notifications(CL, Tnew, C),
	{ CL, Tnew };
	
do_update([PH|PT], PC, T, C) ->
	% we still have a path, so update a subtree of the given tree
	ST = case orddict:find(PH, T) of 
		{ok, {_Seq, L}} when is_list(L) ->  L;	% found existing subtree
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
	T1 = orddict:store(PH, {Seq, STnew}, T),
	send_notifications(RC, T1, C),
	{ RC, T1 }.

%% do_dump(Path, Tree) -> Tree
%%
%% Lookup the state dictionary tree at a given path.  Returns the entire
%% tree, including subscription and version information.

do_dump([], Tree) -> Tree;	
do_dump([PH|PT], Tree) ->
	{ok, {_Seq, SubTree}} = orddict:find(PH, Tree),
	do_dump(PT, SubTree).

%% do_deltas(Since, Path, Tree) -> ChangeTree
%%
%% returns a tree of changes that happened since the specified sequence.
%% if a non-empty path is specified, returns changes relative to that path.

do_deltas(Since, [], Tree) ->
	% FN to filter a list of nodes whose seq# is higher than Since
	% also removing subscription nodes REVIEW: likely should be an option?
	FNfilter = fun(Key, Val) ->
		case {Key, Val} of 
			{Key, {Seq, _Val}} -> (Seq > Since);
			{subs@, _} -> false;
			_ -> true
		end
	end,
    % function to map subnodes to recurse to do_deltas
	FNrecurse = fun(Key, {_Seq, Val}) ->
		case {Key, Val} of 
			{subs@, _} -> 
				Val;
			{_, L} when is_list(L) -> 
				do_deltas(Since, [], L);
			_ -> Val
		end
	end,
	orddict:map(FNrecurse, orddict:filter(FNfilter, Tree));

do_deltas(Since, [PH|PT], Tree) ->
	case orddict:find(PH, Tree) of
		{ok, {_Seq, SubTree}} -> do_deltas(Since, PT, SubTree);
		_Else -> error
	end.
	
%% send notifications about some changes to subscribers

send_notifications([], _, _) ->	pass;   % don't send empty notifications

send_notifications(Changes, Tree, Context) ->
	case orddict:find(subs@, Tree) of
		{ok, Subs} when is_list(Subs) ->
			orddict:map(fun(Pid, Opts) -> 
			    Pid ! {notify, Opts, Changes, Context}
			end, Subs);
		_ -> pass
	end.	
