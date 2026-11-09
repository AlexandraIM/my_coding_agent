defmodule Ella.Output do
  @moduledoc """
  Centralized output sink for Ella.

  All user-facing output should go through this module instead of calling
  `Owl.IO.puts` / `IO.puts` directly. The sink can be swapped (e.g. to a TUI
  process) without touching call sites.
  """

  @sink_key {__MODULE__, :sink}

  @doc "Set the active sink. `:stdio` (default) prints to the terminal."
  def set_sink(sink) do
    :persistent_term.put(@sink_key, sink)
    :ok
  end

  @doc "Reset the sink to the default stdio output."
  def reset_sink do
    :persistent_term.erase(@sink_key)
    :ok
  end

  @doc "Return the current sink."
  def sink do
    :persistent_term.get(@sink_key, :stdio)
  end

  @doc "Print a line (or list of lines)."
  def puts(message) do
    case sink() do
      :stdio ->
        Owl.IO.puts(message)

      {:tui, pid} when is_pid(pid) ->
        send(pid, {:output, to_text(message)})
        :ok

      other ->
        send(other, {:output, to_text(message)})
        :ok
    end
  end

  @doc "Print a blank line."
  def blank do
    puts("")
  end

  @doc "Wrap text in an Owl tag (returns a tagged value for stdio; plain text for TUI)."
  def tag(text, color) do
    case sink() do
      :stdio -> Owl.Data.tag(text, color)
      _ -> text
    end
  end

  @doc "Convert a message to plain text."
  def to_text(message) when is_binary(message), do: message

  def to_text(message) when is_list(message) do
    message
    |> Enum.map(&to_text/1)
    |> Enum.join("")
  end

  def to_text(%Owl.Tag{data: data}) do
    data |> Owl.Data.untag() |> to_text()
  end

  def to_text(other), do: to_string(other)
end
PYEOF