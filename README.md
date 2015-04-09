Hub
===

## Preliminary Documentation ##

Implements a gen_server that holds a heirarchial key-value store with publish/subscribe semanitcs at each node of the heirarchy.  

Processes publish state on a hub, or subscribe to watch for state changes.

The hub keeps a sequence ID for each change to state, and this is
stored as part of the state graph, so that the hub can answer the
question:  "show me all state that has changed since sequence XXX"

