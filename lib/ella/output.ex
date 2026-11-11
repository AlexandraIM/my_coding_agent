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

  @doc "Emit a diff between before/after (TUI renders DiffViewer; stdio prints summary)."
  def diff(path, before, after_text) do
    case sink() do
      {:tui, pid} ->
        send(pid, {:diff, path, before, after_text})
        :ok

      _ ->
        # In stdio mode, keep it minimal.
        :ok
    end
  end

  @doc "Emit a tool invocation (TUI renders as a block; stdio prints a line)."
  def tool_call(name, args) do
    case sink() do
      {:tui, pid} ->
        send(pid, {:tool_call, name, args})
        :ok

      _ ->
        puts([tag("Tool Call [#{name}]: ", :yellow), inspect_args(args)])
    end
  end

  @doc "Emit a tool result (TUI renders as a block; stdio is silent)."
  def tool_result(name, result) do
    case sink() do
      {:tui, pid} ->
        send(pid, {:tool_result, name, result})
        :ok

      _ ->
        :ok
    end
  end

  defp inspect_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v, limit: 3, printable_limit: 60)}" end)
    |> Enum.join(", ")
  end

  defp inspect_args(other), do: inspect(other, limit: 3, printable_limit: 60)

  @doc "Write text without a trailing newline (for streaming)."
  def write(text) do
    case sink() do
      {:tui, pid} ->
        send(pid, {:output_chunk, text})
        :ok

      _ ->
        IO.write(text)
        :ok
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
