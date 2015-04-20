defmodule Uuid do
  @moduledoc """
  Simple UUID generator for Hub
  """

  @doc """
  Generates a uuid

  ## Examples
  ```
  iex>Uuid.generate
  "05142fbc0511bc41D156CD4C605CF0C0"
  ```
  """
  def generate do
    now = {_, _, micro} = :erlang.now
    nowish = :calendar.now_to_universal_time(now)
    nowsecs = :calendar.datetime_to_gregorian_seconds(nowish)
    then = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})
    prefix = :io_lib.format("~14.16.0b", [(nowsecs - then) * 1000000 + micro])
    List.to_string(prefix ++ Base.encode16(:crypto.rand_bytes(9)))
  end
end
