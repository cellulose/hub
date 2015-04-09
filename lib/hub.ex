defmodule Hub do

  @moduledoc """
  Stub for an Elixir rewite of Echo's Hub (formerly written in Erlang).
  For now, delegates mainly to the Erlang implementation, but adds some
  new features, and changes the semantics of how the hub is used slightly,
  so new code can begin to use a newer style Hub API.
  """

  require Logger

  @proc_path_key {:agent, :path}

  def start, do: :hub.start
  def start_link, do: :hub.start_link


  @doc """
  Associate the currrent process as the primary agent for the given
  path.  This binds/configures this process to the hub, and also sets
  the path as the "agent path" in the process dictionary
  """
  def master(path) do
    Process.put @proc_path_key, path
    :hub.master(path)
  end

  @doc """
  Returns the result of:
  gen_server:call(ManagerPID, {request, AtomicPath, Request, Context}).
  """
  def request(path, changes) do
    :hub.request(path, changes)
  end

  def put(path, keys_and_values) do
    update(path, keys_and_values)
  end

  def update(path, keys_and_values, opts \\ []) do
    :hub.update(path, Dict.to_list(keys_and_values), opts)
  end

  def get(path, key) do
    {_vers, dict} = :hub.fetch(path)
    Dict.get dict, key
  end

  def fetch(path \\ []) do
    :hub.fetch(path)
  end

  @doc "Returns the controlling agent for this path, or nil if none"
  def agent(path) do
    case :hub.manager(path) do
      {:ok, {pid, _opts} } -> pid
      _ -> nil
    end
  end

  @doc "Converts a point in the hub to a path (url) in the hub"
  def pt_to_url(pt) do
    "/" <> Enum.map_join(pt, "/", &(Atom.to_string(&1)))
  end

end
