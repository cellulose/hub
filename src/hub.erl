%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% Module "hub"
%%
%% Implements a heirarchial key-value store with publish/watch semanitcs
%% at each node of the heirarchy.   Plans to support timestamping, 
%% version stamping, real-time playback, security,
%%
%% The hub holds a collection of dnodes (dictionary nodes).  Each dictionary
%% node is a key/value store, where the keys are atoms, and the values
%% are any erlang term.  Sometimes the value is also a dnode, which results 
%% in a heirarchy.
%%
%% Processes publish state on a hub, watch to state changes,
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
%%	wch@		list of dependents to be informed
%%
%% For convenience, you can pass in keys as atoms, but they will be converted
%% to binary keys internally (all keys are stored as binaries).    They will
%% be represented as binary keys when returned.  This behavior is under review
%% so if you want to be sure, pass binary keys to begin with.
%% 
%% LICENSE
%%
%% Repurposed from RemoteRadio, (C) Copyright 1996-2012 Garth Hitchens, KG7GA,
%% and Echo, (C) Copyright 2012-2013 Garth Hitchens, All Rights Reserved
%% 
%% License explicitly granted to Rose Point Navigation Systems, LLC, for use 
%% in the NEMO network translator box.   For other uses contact the Author.
%%
%% vim:ts=4,sts=4

-module(hub).
-behaviour(gen_server).

%% Exports to conform to gen_server behaviour

-export([init/1, handle_call/3, handle_cast/2, code_change/3, handle_info/2, 
		 terminate/2]).

-export([start_link/0, start/0]).
-export([request/2, request/3, update/2, update/3, watch/2, unwatch/1, 
		 manage/2, manager/1, fetch/0, fetch/1, dump/0, dump/1, deltas/1, 
		 deltas/2, binarify/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%% Record Definitions %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% dnodes are the core of the hub's storage and state mechanism

-record(state, { 
			gtseq 	= 0, 						% global transaction sequence #
			dtree 	= orddict:new()				% the dictionary tree
		}).				 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%  Public API %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% initialization

start() ->    	gen_server:start({local, ?MODULE}, ?MODULE, [], []).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% request something from the manager of this point.  Note that requests 
%% are sent from the caller's process, so that they don't block the hub.

request(Path, Request) ->
	request(Path, Request, []).
  
request(Path, Request, Context) ->
  BinPath = binarify(Path),
	{ok, {ManagerPID, _Opts}} = gen_server:call(?MODULE, {manager, BinPath}),
	gen_server:call(ManagerPID, {request, BinPath, Request, Context}).

%% interfaces to updating state

update(Path, Changes) -> 
  update(Path, Changes, []).

update(Path, Changes, Context) ->
	gen_server:call(?MODULE, {update, binarify(Path), Changes, Context}).

%% interfaces to specify ownership and watching

manage(Path, Options) -> 
  gen_server:call(?MODULE, {manage, binarify(Path), Options}).

manager(Path) -> 
  gen_server:call(?MODULE, {manager, binarify(Path)}).

watch(Path, Options) ->	
  gen_server:call(?MODULE, {watch, binarify(Path), Options}).

unwatch(Path) -> 
  gen_server:call(?MODULE, {unwatch, binarify(Path)}).

%% interfaces to queries

dump() ->
  dump([]).

dump(Path) ->			
  gen_server:call(?MODULE, {dump, binarify(Path)}).		

fetch() ->
  fetch([]).

fetch(Path) ->
  deltas(0, Path).

deltas(Seq) -> 
  deltas(Seq, []).

deltas(Seq, Path) -> 	
  gen_server:call(?MODULE, {deltas, Seq, binarify(Path)}).		

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% helpers %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% binarify(KeyList)
%%
%% used primarily for converting keys in paths to binary keys rather than
%% atoms, which allows atoms to be used as keys.

binarify([H|T]) ->
  [binarify(H)|binarify(T)];
binarify(Atom) when is_atom(Atom) ->
  atom_to_binary(Atom, utf8);
binarify(SomethingElse) ->
  SomethingElse.
  
%%%%%%%%%%%%%%%%%%%%%%%%%%%% gen_server callbacks %%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(_Args) -> 	{ok, #state{}}. 

terminate(normal, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> 	{ok, State}.

% handle_info/cast/call clauses, &  delegate for hub specific handlers

handle_info(Msg, State) ->
    io:format("Unexpected message: ~p~n",[Msg]),
    {noreply, State}.

handle_cast(return, State) -> 
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%% handle_call %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_call(terminate, _From, State) -> 
	{stop, normal, ok, State};

handle_call({manage, Path, Opts}, From, State) ->
	case do_manage(Path, {From, Opts}, State#state.dtree) of
		Tnew when is_list(Tnew) -> 
			{reply, ok, State#state{dtree=Tnew}};
		_ -> 
			{reply, error, State}
	end;

handle_call({manager, Path}, _From, State) ->
	{reply, do_manager(Path, State#state.dtree), State};

handle_call({watch, Path, Opts}, From, State) ->
	case do_watch(Path, {From, Opts}, State#state.dtree) of
		{ok, Tnew} when is_list(Tnew) -> 
			{reply, ok, State#state{dtree=Tnew}};
		{error, Reason} -> 
			{reply, {error, Reason}, State}
	end;

handle_call({unwatch, Path}, From, State) ->
	case do_unwatch(Path, From, State#state.dtree) of
		{ok, Tnew} when is_list(Tnew) -> 
			{reply, ok, State#state{dtree=Tnew}};
		{error, Reason} -> 
			{reply, {error, Reason}, State}
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

%% manage ownership of this point
%%
%% TODO: un-manage?  handle errors if already manageed?   Security?

do_manage([], {{FromPid, _Ref}, Opts}, Tree) ->
	orddict:store(mgr@, {FromPid, Opts}, Tree);
			
do_manage([PH|PT], {From, Opts}, Tree) -> 
	{ok, {Seq, ST}} = orddict:find(PH, Tree),
	STnew = do_manage(PT, {From, Opts}, ST),
	orddict:store(PH, {Seq, STnew}, Tree).

%% do_manager(Point, Tree) -> {ok, {Process, Options}} | undefined
%%
%% return the manageling process and options for a given point on the
%% dictionary tree, if the manager was set by do_manage(...).

do_manager([], Tree) -> 
	orddict:find(mgr@, Tree);

do_manager([PH|PT], Tree) ->
	{ok, {_Seq, SubTree}} = orddict:find(PH, Tree),
	do_manager(PT, SubTree).

%% do_watch(Path, Subscription, Tree)
%% 
%% Subscription is a {From, watchParameters} tuple that is placed on
%% the wch@ key at a node in the dtree.  Adding a subscription doesn't
%% currently cause any notificaitions, although that might change.
%%
%% REVIEW: could eventually be implemented as a special form of update by
%% passing something like {append, Subscription, [notifications, false]}
%% as the value, or maybe something like a function as the value!!! cool?

do_watch([], {From, Opts}, Tree) ->
	{FromPid, _Ref} = From,
	Subs = case orddict:find(wch@, Tree) of 
		{ok, L} when is_list(L) -> 
			orddict:store(FromPid, Opts, L);
		_ -> 
			orddict:store(FromPid, Opts, orddict:new())
	end,
	{ok, orddict:store(wch@, Subs, Tree)};
		
do_watch([PH|PT], {From, Opts}, Tree) -> 
	case orddict:find(PH, Tree) of 
		{ok, {Seq, ST}} ->
			case do_watch(PT, {From, Opts}, ST) of 
				{error, Reason} -> {error, Reason};
				{ok, STnew} -> {ok, orddict:store(PH, {Seq, STnew}, Tree)}
			end;
		_ -> {error, nopoint}
	end.

%% do_unwatch(Path, releaser, Tree) -> Tree | notfound
%%
%% removes releaser from the dictionary tree

do_unwatch([], Unsub, Tree) ->
	{FromPid, _Ref} = Unsub,
	{ok, OldSubs} = orddict:find(wch@, Tree),
	{ok, orddict:store(wch@, orddict:erase(FromPid, OldSubs), Tree)};

do_unwatch([PH|PT], Unsub, Tree) ->
	case orddict:find(PH, Tree) of 
		{ok, {Seq, ST}} ->
			case do_unwatch(PT, Unsub, ST) of 
				{error, Reason} -> {error, Reason};	
				{ok, STnew} -> {ok, orddict:store(PH, {Seq, STnew}, Tree)}
			end;
		_ -> {error, nopoint}
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
            {ok, {_, Value}} ->		% already the value we are setting
				{RC, Dict};
            _Else when is_list(Value) -> 	% we're setting a proplist
				{RCsub, NewDict} = do_update(binarify([Key]), Value, Dict, C),
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
%% returns these in a jiffy-compatible structure

do_deltas(Since, [], Tree) ->
	% FN to filter a list of nodes whose seq# is higher than Since
	% also removing subscription nodes REVIEW: likely should be an option?
	FNfilter = fun(Key, Val) ->
		case {Key, Val} of 
			{mgr@, _} -> false;
			{wch@, _} -> false;
			{Key, {Seq, _Val}} -> (Seq > Since);
			_ -> true
		end
	end,
    % function to map subnodes to recurse to do_deltas
	FNrecurse = fun(Key, {_Seq, Val}) ->
		case {Key, Val} of 
			{wch@, _} -> Val;
			{mgr@, _} -> Val;
			{_, L} when is_list(L) -> 
				do_deltas(Since, [], L);
			_ -> Val
		end
	end,
	{ orddict:map(FNrecurse, orddict:filter(FNfilter, Tree)) };

do_deltas(Since, [PH|PT], Tree) ->
	case orddict:find(PH, Tree) of
		{ok, {_Seq, SubTree}} when is_list(SubTree) -> 
			do_deltas(Since, PT, SubTree);
		_Else -> error
	end.

%% called by do_update to send notification to watchers (wch@).
%%	
%% send notifications about some changes to watchrs.   If nothing changed,
%% then don't send any notifications.

send_notifications([], _, _) ->	pass;
send_notifications(Changes, Tree, Context) ->
	case orddict:find(wch@, Tree) of
		{ok, Subs} when is_list(Subs) ->
			orddict:map(fun(Pid, Opts) -> 
			    Pid ! {notify, Opts, Changes, Context}
			end, Subs);
		_ -> pass
	end.	
