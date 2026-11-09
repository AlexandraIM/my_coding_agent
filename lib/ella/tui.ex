defmodule Ella.Tui do
  @moduledoc """
  Terminal UI front-end for Ella, built on TermUI (Elm architecture).

  The agent core (`Ella.Agent`) is unchanged; this module is a view layer.
  Run with `Ella.Tui.run/1` or pass `--tui` to the CLI.
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Frame, Style}

  @max_output_lines 200

  def run(opts \\ []) do
    agent_opts = Keyword.get(opts, :agent_opts, [])
    {:ok, agent_pid} = Ella.Agent.start_link(agent_opts)

    info = safe_provider_info(agent_pid)

    TermUI.run(__MODULE__,
      agent: agent_pid,
      mode: :plan,
      provider: info.provider,
      model: info.model || "unknown",
      backend: Keyword.get(opts, :backend, :auto)
    )
  end

  @impl true
  def init(opts) do
    Ella.Output.set_sink({:tui, self()})

    %{
      agent: Keyword.fetch!(opts, :agent),
      dimensions: Keyword.fetch!(opts, :dimensions),
      mode: Keyword.get(opts, :mode, :plan),
      provider: Keyword.get(opts, :provider, "unknown"),
      model: Keyword.get(opts, :model, "unknown") || "unknown",
      output: ["Ella TUI ready. Type a prompt or /help."],
      input: "",
      busy: false,
      scroll: 0
    }
  end

  @impl true
  def event_to_msg(%Event.Key{key: :enter}, state), do: {:msg, {:submit, state.input}}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}
  def event_to_msg(%Event.Key{key: key, modifiers: mods}, _state) do
    ctrl = :ctrl in mods

    cond do
      ctrl and key == :up -> {:msg, :scroll_up}
      ctrl and key == :down -> {:msg, :scroll_down}
      ctrl and key in ["c", :c] -> {:msg, :quit}
      true -> :ignore
    end
  end
  def event_to_msg(%Event.Text{text: text}, _state), do: {:msg, {:text, text}}
  def event_to_msg(%Event.Resize{width: w, height: h}, _state), do: {:msg, {:resize, w, h}}
  def event_to_msg(_event, _state), do: :ignore

  @impl true
  def update(:backspace, state) do
    %{state | input: String.slice(state.input, 0, String.length(state.input) - 1)}
  end

  def update({:text, text}, state) do
    %{state | input: state.input <> text}
  end

  def update(:scroll_up, state) do
    %{state | scroll: state.scroll + 1}
  end

  def update(:scroll_down, state) do
    %{state | scroll: max(0, state.scroll - 1)}
  end

  def update({:resize, w, h}, state) do
    %{state | dimensions: {w, h}}
  end

  def update({:submit, nil}, state), do: state
  def update({:submit, ""}, state), do: state

  def update({:submit, _text}, %{busy: true} = state) do
    append(state, "[busy, please wait]")
  end

  def update({:submit, "/" <> _ = text}, state) do
    state = append(state, "> " <> text)
    state = %{state | input: ""}
    handle_slash(String.trim(text), state)
  end

  def update({:submit, text}, state) do
    state = append(state, "> " <> text)
    state = %{state | input: "", busy: true}

    agent = state.agent
    self_pid = self()

    Task.start(fn ->
      result =
        case Ella.Agent.ask(agent, text) do
          {:ok, response} -> {:agent_result, response}
          {:error, reason} -> {:agent_error, reason}
        end

      send(self_pid, result)
    end)

    state
  end

  def update(:quit, state) do
    Ella.Output.reset_sink()
    {state, [Command.shutdown()]}
  end

  def update({:agent_result, response}, state) do
    state = append(state, response)
    %{state | busy: false}
  end

  def update({:agent_error, reason}, state) do
    state = append(state, "ERROR: " <> reason)
    %{state | busy: false}
  end

  def update({:slash, cmd}, state) do
    handle_slash(cmd, state)
  end

  def update(_msg, state), do: state

  @impl true
  def handle_info({:agent_result, _} = msg, state) do
    update(msg, state)
  end

  def handle_info({:agent_error, _} = msg, state) do
    update(msg, state)
  end

  def handle_info({:output, text}, state) do
    append(state, text)
  end

  def handle_info(_msg, state), do: state

  @impl true
  def view(state) do
    {width, height} = state.dimensions
    body_height = max(1, height - 3)

    visible =
      state.output
      |> Enum.reverse()
      |> Enum.drop(state.scroll)
      |> Enum.take(body_height)
      |> Enum.reverse()

    rows = visible ++ List.duplicate("", body_height - length(visible))

    status_style = Style.new(fg: :cyan, attrs: [:bold])
    busy_tag = if state.busy, do: " [busy]", else: ""
    status = " #{mode_label(state.mode)} | #{state.provider}:#{state.model}#{busy_tag}"

    input_line = "> " <> state.input

    all_rows = rows ++ [[{status, status_style}], input_line]

    Frame.from_rows(all_rows, width, height)
  end

  defp append(state, text) do
    lines = String.split(text, "\n")
    new_output = (state.output ++ lines) |> Enum.take(-@max_output_lines)
    %{state | output: new_output}
  end

  defp mode_label(:plan), do: "PLAN"
  defp mode_label(:build), do: "BUILD"
  defp mode_label(:review), do: "REVIEW"
  defp mode_label(other), do: to_string(other) |> String.upcase()

  defp handle_slash("/help", state) do
    help = [
      "Commands: /plan /build /review /provider /usage /context /help /exit",
      "Type a prompt and press Enter."
    ]

    Enum.reduce(help, state, fn line, acc -> append(acc, line) end)
  end

  defp handle_slash("/exit", state) do
    {state, [Command.shutdown()]}
  end

  defp handle_slash("/plan", state) do
    Ella.Agent.set_mode(state.agent, :plan)
    %{state | mode: :plan} |> append("Switched to PLAN mode.")
  end

  defp handle_slash("/build", state) do
    Ella.Agent.set_mode(state.agent, :build)
    %{state | mode: :build} |> append("Switched to BUILD mode.")
  end

  defp handle_slash("/review", state) do
    Ella.Agent.set_mode(state.agent, :review)
    %{state | mode: :review} |> append("Switched to REVIEW mode.")
  end

  defp handle_slash("/provider", state) do
    info = safe_provider_info(state.agent)
    append(state, "provider: #{info.provider}  model: #{info.model}")
  end

  defp handle_slash("/provider " <> rest, state) do
    case String.split(String.trim(rest), " ", trim: true) do
      ["list"] ->
        names = Ella.Llm.Provider.providers() |> Enum.map(& &1.name)
        append(state, "providers: " <> Enum.join(names, ", "))

      [name] ->
        case Ella.Agent.set_provider(state.agent, name) do
          {:ok, ^name} ->
            info = safe_provider_info(state.agent)
            %{state | provider: info.provider, model: info.model || "unknown"}
            |> append("Switched to provider '#{name}' (model: #{info.model}).")

          {:error, reason} ->
            append(state, "Switch failed: #{inspect(reason)}")
        end

      ["model", _provider, model] ->
        case Ella.Agent.set_model(state.agent, model) do
          {:ok, ^model} ->
            info = safe_provider_info(state.agent)
            %{state | model: info.model || model} |> append("Model set to #{model}.")

          {:error, reason} ->
            append(state, "Failed to set model: #{inspect(reason)}")
        end

      _ ->
        append(state, "Usage: /provider | /provider list | /provider <name> | /provider model <provider> <model>")
    end
  end

  defp handle_slash("/usage", state) do
    usage = Ella.Agent.usage(state.agent)
    append(state, Ella.Llm.Usage.format(usage))
  rescue
    _ -> append(state, "Usage unavailable.")
  end

  defp handle_slash("/context", state) do
    info = Ella.Agent.context_info(state.agent)
    append(state, "#{info.messages} messages, ~#{info.estimated_tokens} of #{info.budget} tokens")
  rescue
    _ -> append(state, "Context info unavailable.")
  end

  defp handle_slash(other, state) do
    append(state, "Unknown command: #{other}")
  end

  defp safe_provider_info(pid) do
    Ella.Agent.provider_info(pid)
  rescue
    _ -> %{provider: "unknown", model: "unknown"}
  end
end
