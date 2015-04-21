defmodule Hub do
  @moduledoc """
   Central state cache and update broker

   Implements a heirarchial key-value store with publish/watch semanitcs
   at each node of the heirarchy.   Plans to support timestamping,
   version stamping, real-time playback, security,

   The hub holds a collection of dnodes (dictionary nodes).  Each dictionary
   node is a key/value store, where the keys are atoms, and the values
   are any erlang term.  Sometimes the value is also a dnode, which results
   in a heirarchy.

   Processes publish state on a hub, watch to state changes,
   request information about the state of the bus, and request changes
   to the state.

   A hub is a process (a gen_server, actually) that holds state for the
   system, manages changes to state, and and routes notifications of
   changes of state.

   The hub keeps a sequence ID for each change to state, and this is
   stored as part of the state graph, so that the hub can answer the
   question:  "show me all state that has changed since sequence XXX"

   ** Limitations and areas for improvement **

   Right now the store is only in memory, so a restart removes all data
   from the store.   All persistence must be implemented separately

   There is currently no change history or playback history feature.

   [{key,val},{key,val}...]

   if a value at any given path is a proplist (tested as a list whose first
   term is a tuple, or an empty list).

   some special keys that can appea

    mgr@        list of dependents in charge of point in graph
    wch@        list of dependents to be informed about changes

   For convenience, you can pass in keys as atoms, but they will be converted
   to binary keys internally (all keys are stored as binaries).    They will
   be represented as binary keys when returned.  This behavior is under review
   so if you want to be sure, pass binary keys to begin with.

   ## Examples

   Basic Usage:

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
  """

  require Logger
  require Record

  use GenServer

  defmodule State do
    @moduledoc false
    @derive [Access]
    defstruct gtseq: 0, vlock: Uuid.generate, dtree: :orddict.new
  end

  @proc_path_key {:agent, :path}

  @doc false
  def start() do
    start([],[])
  end

  @doc false
  def start_link() do
    start_link([], [])
  end

  @doc false
  def start(_,_) do
    GenServer.start(__MODULE__, [], name: __MODULE__)
  end

  @doc false
  def start_link(_,_) do
    GenServer.start(__MODULE__, [], name: __MODULE__)
  end

  ############################### PUBLIC API ###################################

  @doc """
  Request a change to the path in the hub. The Manager is forwarded the request
  and is responsible for handling it. If no manager is found a timeout will
  occur.

  ## Examples

  ```
  iex> Hub.request [:some, :point], [useful: :info]
  {:changes, {"0513b7725c5436E67975FB3A13EB3BAA", 2},
   [some: [point: [useful: :info]]]}
  ```
  """
  def request(path, request, context \\ []) do
    atomic_path = atomify(path)
    {:ok, {manager_pid, _opts}} = GenServer.call(__MODULE__, {:manager, atomic_path})
    GenServer.call(manager_pid, {:request, atomic_path, request, context})
  end

  @doc """
  Updates the path with the changes provided.

  ## Examples
  ```
  iex> Hub.update [:some, :point], [some: :data]
  {:changes, {"05142ef7fe86a86D2471CA6869E19648", 1},
   [some: [point: [some: :data]]]}
  ```
  """
  def update(path, changes, context \\ []) do
    GenServer.call(__MODULE__, {:update, atomify(path), changes, context})
  end

  @doc """
  Same as `update/3` except no context argument. See `update/3` for more
  information
  """
  def put(path, changes) do
    update(path, changes)
  end

  @doc """
  Associate the currrent process as the primary agent for the given
  path.  This binds/configures this process to the hub, and also sets
  the path as the "agent path" in the process dictionary.

  *Note:* The path provided must exist and have values stored before trying
  to master it.

  ## Examples

  ```
  iex> Hub.master [:some, :point]
  :ok
  """
  def master(path, options \\ []) do
    Process.put @proc_path_key, path
    update(path, [])
    manage(path, options)
    watch(path, [])
  end

  @doc """
  Similar to `master/2` but does not `watch` the path.

  ## Examples

  ```
  iex> Hub.manage [:some, :point], []
  :ok
  ```
  """
  def manage(path, options \\ []) do
    GenServer.call(__MODULE__, {:manage, atomify(path), options})
  end

  @doc """
  Retrieves the manager with options for the provided path.

  ## Examples

  ```
  iex> Hub.manager [:some, :point]
  {:ok, {#PID<0.125.0>, []}}
  ```
  """
  def manager(path) do
    GenServer.call(__MODULE__, {:manager, atomify(path)})
  end

  @doc """
  Returns the controlling agent for this path, or nil if none

  ## Examples
  ```
  iex> Hub.agent [:some, :point]
  #PID<0.125.0>
  ```
  """
  def agent(path) do
    case manager(path) do
      {:ok, {pid, _opts} } -> pid
      _ -> nil
    end
  end

  @doc """
  Adds the calling process to the @wch list of process to get notified of
  changes to the path specified.

  ## Examples
  ```
  iex> Hub.watch [:some, :point]
  :ok
  ```
  """
  def watch(path, options \\ []) do
    GenServer.call(__MODULE__, {:watch, atomify(path), options})
  end

  @doc """
  Removes the calling process from the @wch list of process to stop getting
  notified of changes to the path specified.

  ## Examples
  ```
  iex> Hub.unwatch [:some, :point]
  :ok
  ```
  """
  def unwatch(path) do
    GenServer.call(__MODULE__, {:unwatch, atomify(path)})
  end

  @doc """
  Dumps the entire contents of the hub graph, including "non human" information.

  ## Examples
  ```
  iex> Hub.dump
  {{"05142ef7fe86a86D2471CA6869E19648", 1},
    [some: {1, [point: {1, [mgr@: {#PID<0.125.0>, []}, some: {1, :data}]}]}]}
  ```
  """
  def dump(path \\ []) do
    GenServer.call(__MODULE__, {:dump, atomify(path)})
  end

  @doc """
  Gets the value at the specified path with the specified key.

  ## Examples
  ```
  iex> Hub.get [:some, :point], :status
  :online
  ```
  """
  def get(path, key) do
    {_vers, dict} = fetch(path)
    Dict.get dict, key
  end

  @doc """
  Gets all the "human readable" key values pairs at the specified path.

  ## Examples
  ```
  iex>Hub.fetch [:some, :point]
  {{"05142ef7fe86a86D2471CA6869E19648", 1}, [some: :data]}
  ```
  """
  def fetch(path \\ []), do: deltas({:unknown, 0}, path)

  @doc """
  Gets the changes from the provided sequence counter on the path to its current
  state.

  The sequence counter is retured on calls to `get/1`, `put/2`, `update/3`,
  `dump/1`, `fetch/1`

  ## Examples
  ```
  iex> Hub.deltas 2, [:some, :path]
  {{"05142f977e209de63a768684291be964", 2}, [some: :new_data]}
  ```
  """
  def deltas(seq, path \\ []) do
    GenServer.call(__MODULE__, {:deltas, seq, atomify(path)})
  end

  ########################## GenServer Callbacks ###############################
  @doc false
  def init(_args), do: {:ok, %State{}}

  @doc false
  def terminate(:normal, _state), do: :ok
  def terminate(reason, _state), do: reason

  @doc false
  def code_change(_old_ver, state, _extra), do: {:ok, state}

  @doc false
  def handle_info(msg, state) do
    Logger.debug "#{__MODULE__} got unexpected message: #{inspect msg}"
    {:noreply, state}
  end

  @doc false
  def handle_cast(:return, state), do: {:noreply, state}

  ############################## handle_call ###################################

  @doc false
  def handle_call(:terminate, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @doc false
  def handle_call({:manage, path, opts}, from, state) do
    case do_manage(path, {from, opts}, state.dtree) do
      tnew when is_list(tnew) ->
        {:reply, :ok, %State{state | dtree: tnew}}
      _ ->
        {:reply, :error, state}
    end
  end

  @doc false
  def handle_call({:manager, path}, _from, state) do
    {:reply, do_manager(path, state.dtree), state}
  end

  @doc false
  def handle_call({:watch, path, opts}, from, state) do
    case do_watch(path, {from, opts}, state.dtree) do
      {:ok, tnew} when is_list(tnew) ->
        {:reply, :ok, %State{state | dtree: tnew}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc false
  def handle_call({:unwatch, path}, from, state) do
    case do_unwatch(path, from, state.dtree) do
      {:ok, tnew} when is_list(tnew) ->
        {:reply, :ok, %State{state | dtree: tnew}}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc false
  def handle_call({:request, _key, _req}, _from, state) do
    {:reply, :ok, state}
  end

  @doc false
  def handle_call({:update, path, proposed, auth}, from, state) do
    seq = state.gtseq + 1
    ctx = {seq, [from: from, auth: auth]} #REVIEW .erl 233
    case do_update(path, proposed, state.dtree, ctx) do
      {[], _} ->
        {:reply, {:nochanges, {state.vlock, state.gtseq}, []}, state}
      {changed, new_tree} ->
        state = %State{state | dtree: new_tree, gtseq: seq}
        {:reply, {:changes, {state.vlock, seq}, changed}, state}
    end
  end

  @doc false
  def handle_call({:dump, path}, _from, state) do
    {:reply, {{state.vlock, state.gtseq}, do_dump(path, state.dtree)},state}
  end

  @doc false
  def handle_call({:deltas, seq, path}, _from, state) do
    {:reply, {{state.vlock, state.gtseq}, handle_vlocked_deltas(seq, path, state)}, state}
  end

  # Breaks apart the vlock information and calls do_deltas with the version
  # found or since the start (version 0)
  defp handle_vlocked_deltas({cur_vlock, since}, path, state) do
    case state.vlock do
      vlock when vlock == cur_vlock -> do_deltas(since, path, state.dtree)
      _ -> do_deltas(0, path, state.dtree)
    end
  end

  ####################### state tree implementation ############################

  ## manage ownership of this point
  ##
  ## TODO: un-manage?  handle errors if already manageed?   Security?

  defp do_manage([], {{from_pid, _ref}, opts}, tree) do
    :orddict.store(:mgr@, {from_pid, opts}, tree)
  end

  defp do_manage([h|t], {from, opts}, tree) do
    {:ok, {seq, st}} = :orddict.find(h, tree)
    stnew = do_manage(t, {from, opts}, st)
    :orddict.store(h, {seq, stnew}, tree)
  end

  ## do_manager(Point, Tree) -> {ok, {Process, Options}} | undefined
  ##
  ## return the manageling process and options for a given point on the
  ## dictionary tree, if the manager was set by do_manage(...).

  defp do_manager([], tree), do: :orddict.find(:mgr@, tree)

  defp do_manager([h|t], tree) do
    {:ok, {_seq, sub_tree}} = :orddict.find(h, tree)
    do_manager(t, sub_tree)
  end

  ## do_watch(Path, Subscription, Tree)
  ##
  ## Subscription is a {From, watchParameters} tuple that is placed on
  ## the wch@ key at a node in the dtree.  Adding a subscription doesn't
  ## currently cause any notificaitions, although that might change.
  ##
  ## REVIEW: could eventually be implemented as a special form of update by
  ## passing something like {append, Subscription, [notifications, false]}
  ## as the value, or maybe something like a function as the value!!! cool?

  defp do_watch([], {from, opts}, tree) do
    {from_pid, _ref} = from
    subs = case :orddict.find(:wch@, tree) do
      {:ok, l} when is_list(l) ->
        :orddict.store(from_pid, opts, l)
      _ ->
        :orddict.store(from_pid, opts, :orddict.new())
    end
    {:ok, :orddict.store(:wch@, subs, tree)}
  end

  defp do_watch([h|t], {from, opts}, tree) do
    case :orddict.find(h, tree) do
      {:ok, {seq, st}} ->
        case do_watch(t, {from, opts}, st) do
          {:ok, stnew} ->
            {:ok, :orddict.store(h, {seq, stnew}, tree)}
          {:error, reason} -> {:error, reason}
        end
      _ -> {:error, :nopoint}
    end
  end

  ## do_unwatch(Path, releaser, Tree) -> Tree | notfound
  ##
  ## removes releaser from the dictionary tree
  defp do_unwatch([], unsub, tree) do
    {from_pid, _ref} = unsub
    case :orddict.find(:wch@, tree) do
      {:ok, old_subs} ->
        {:ok, :orddict.store(:wch@, :orddict.erase(from_pid, old_subs), tree)}
      _ -> {:error, :no_wch}
    end
  end

  defp do_unwatch([h|t], unsub, tree) do
    case :orddict.find(h, tree) do
      {:ok, {seq, st}} ->
        case do_unwatch(t, unsub, st) do
          {:ok, stnew} ->
            {:ok, :orddict.store(h, {seq, stnew}, tree)}
          {:error, reason} -> {:error, reason}
        end
      _ -> {:error, :nopoint}
    end
  end

  ## update(PathList,ProposedChanges,Tree,Context) -> {ResultingChanges,NewTree}
  ##
  ## Coding Abbreviations:
  ##
  ## PC,RC    Proposed Changes, Resulting Changes (these are trees)
  ## P,PH,PT  Path/Path Head/ Path Tail
  ## T,ST     Tree,SubTree
  ## C        Context - of the form {Seq, Whatever} where whatever is
  ##          any erlang term - gets threaded unmodified through update
  defp do_update([], pc, t, c) do
    uf = fn(key, value, {rc, dict}) ->
      case :orddict.find(key, dict) do
        {:ok, {_, val}} when val == value ->
          {rc, dict}
        _ when is_list(value) ->
          {rcsub, new_dict} = do_update(atomify(key), value, dict, c)
          {(rc ++ rcsub), new_dict}
        _ ->
          {seq, _} = c
          {rc ++ [{key, value}], :orddict.store(atomify(key), {seq, value}, dict)}
      end
    end
    {cl, tnew} = :orddict.fold(uf, {[], t}, pc)
    send_notifications(cl, tnew, c)
    {cl, tnew}
  end

  defp do_update([head|tail], pc, t, c) do
    st = case :orddict.find(head, t) do
      {:ok, {_seq, l}} when is_list(l) -> l
      {:ok, _} -> :orddict.new
      :error -> :orddict.new
    end
    {rcsub, stnew} = do_update(tail, pc, st, c)
    case rcsub do
      [] -> {[], t}
      y ->
        rc = [{head, y}]
        {seq, _} = c
        t = :orddict.store(head, {seq, stnew}, t)
        send_notifications(rc, t, c)
        {rc, t}
    end
  end

  defp do_dump([], tree), do: tree

  defp do_dump([h|t], tree) do
    {:ok, {_seq, sub_tree}} = :orddict.find(h, tree)
    do_dump(t, sub_tree)
  end

  defp do_deltas(since, [], tree) do
    fn_filter = fn(key, val) ->
      case {key, val} do
        {:wch@, _} -> false
        {:mgr@, _} -> false
        {_key, {seq, _val}} -> (seq > since)
        _ -> true
      end
    end
    fn_recurse = fn(key, {_seq, val}) ->
      case {key, val} do
        {:wch@, _} -> val
        {:mgr@, _} -> val
        {_, l} when is_list(l) ->
          do_deltas(since, [], l)
        _ -> val
      end
    end
    :orddict.map(fn_recurse, :orddict.filter(fn_filter, tree))
  end

  defp do_deltas(since, [h|t], tree) do
    case :orddict.find(h, tree) do
      {:ok, {_seq, sub_tree}} when is_list(sub_tree) ->
        do_deltas(since, t, sub_tree)
      _ -> :error
    end
  end

  # Send notification to all watchers who called `watch/1`
  defp send_notifications([], _, _), do: :pass
  defp send_notifications(changes, tree, context) do
    case :orddict.find(:wch@, tree) do
      {:ok, subs} when is_list(subs) ->
        :orddict.map(fn(pid, opts) ->
          send(pid, {:notify, opts, changes, context})
        end, subs)
      _ -> :pass
    end
  end

  # Converts a point (path) to a url
  defp pt_to_url(pt) do
    "/" <> Enum.map_join(pt, "/", &(Atom.to_string(&1)))
  end

  # converts an atom (or list of atoms) to binaries
  defp binarify([h|t]), do: [binarify(h) | binarify(t)]
  defp binarify(a) when is_atom(a), do: Atom.to_string(a)
  defp binarify(o), do: o

  # converts a binary (or list of binaries) to atoms
  defp atomify([h|t]), do: [atomify(h) | atomify(t)]
  defp atomify(s) when is_binary(s), do: String.to_atom(s)
  defp atomify(o), do: o
end
