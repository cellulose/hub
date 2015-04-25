Hub
===

Central state cache and update broker

Implements a hierarchal key-value store with publish/watch semanitics
at each node of the hierarchy.   Plans to support time-stamping,
version stamping, real-time playback, security,

The hub holds a collection of dnodes (dictionary nodes).  Each dictionary
node is a key/value store, where the keys are atoms, and the values
are any Erlang term.  Sometimes the value is also a dnode, which results
in a hierarchy.

Processes publish state on a hub, watch to state changes,
request information about the state of the bus, and request changes
to the state.

A hub is a process (a gen_server, actually) that holds state for the
system, manages changes to state, and and routes notifications of
changes of state.

The hub keeps a sequence ID for each change to state, and this is
stored as part of the state graph, so that the hub can answer the
question:  "show me all state that has changed since sequence xxx"

** Limitations and areas for improvement **

Right now the store is only in memory, so a restart removes all data
from the store.   All persistence must be implemented separately (see
[HubStorage](http://github.com/cellulose/hub_storage))

There is currently no change history or playback history feature.

[{key,val},{key,val}...]

if a value at any given path is a proplist (tested as a list whose first
term is a tuple, or an empty list).

some special keys that can appear

 mgr@        list of dependents in charge of point in graph
 wch@        list of dependents to be informed about changes

For convenience, you can pass in keys as atoms, but they will be converted
to binary keys internally (all keys are stored as binaries).    They will
be represented as binary keys when returned.  This behavior is under review
so if you want to be sure, pass binary keys to begin with.

## Examples

Basic Usage:
```elixir
# Start the Hub GenServer
iex> Hub.start
{:ok, #PID<0.127.0>}

# Put [status: :online] at path [:some, :point]
iex(2)> Hub.put [:some,:point], [status: :online]
{:changes, {"05142ef7fe86a86D2471CA6869E19648", 1},
[some: [point: [status: :online]]]}

# Fetch all values at path [:some, :point]
Hub.fetch [:some, :point]
{{"05142ef7fe86a86D2471CA6869E19648", 1}, [status: :online]}

# Get particular value :status at [:some, :point]
Hub.get [:some, :point], :status
:online
```

## Contributing

We appreciate any contribution to Cellulose Projects, so check out our [CONTRIBUTING.md](CONTRIBUTING.md) guide for more information. We usually keep a list of features and bugs [in the issue tracker][2].

## Building documentation

Building the documentation requires [ex_doc](https://github.com/elixir-lang/ex_doc) to be installed. Please refer to
their README for installation instructions and usage instructions.

## License

The MIT License (MIT)

Copyright (c) 2014 Garth Hitchens

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
