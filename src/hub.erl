%% Module "hub"
%%
%% The system core that distributes that ", which is the core of the system
%% Processes can publish state on the bus, sPathubscribe to state changes,
%% request information about the state of the bus, and request changes
%% to the state.

node:inform_dependents(Tree, Node, OldValue, NewValue)
bus:request_changes(Bus, {kg7ga, kw, vfoa}, 14100)

% bus:subscribe(Bus, {kg7ga, kw})
% subscribes the calling process to the bus at the specified node, with

subscribe(Bus, Path) ->
	subscribe(Bus, Path, []).

subscribe(Bus, Path, Options) ->
	ets:set(Bus, cons(Path, [subscribers], self()).
	
request(Bus, Path, value) ->
	set(Bus, Path, '_request', Value).

# 
set(Hub, Path, value) ->
	ets:set()

	