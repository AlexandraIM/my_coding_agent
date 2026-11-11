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

    project_tree = Ella.ProjectRules.project_tree(Ella.Sandbox.root(), 2)
    tree_lines = String.split(project_tree, "\n")

    %{
      agent: Keyword.fetch!(opts, :agent),
      dimensions: Keyword.fetch!(opts, :dimensions),
      mode: Keyword.get(opts, :mode, :plan),
      provider: Keyword.get(opts, :provider, "unknown"),
      model: Keyword.get(opts, :model, "unknown") || "unknown",
      output: ["Ella TUI ready. Type a prompt or /help."],
      input: "",
      busy: false,
      scroll: 0,
      approval: nil,
      diff: nil,
      sidebar: true,
      palette: false,
      tree_lines: tree_lines
    }
  end

  @impl true
  def event_to_msg(%Event.Key{key: key}, %{approval: %{}} = _state) when key in ["y", "Y"] do
    {:msg, :approve_yes}
  end

  def event_to_msg(%Event.Key{key: key}, %{approval: %{}} = _state) when key in ["n", "N"] do
    {:msg, :approve_no}
  end

  def event_to_msg(%Event.Text{text: text}, %{approval: %{}} = _state) when text in ["y", "Y"] do
    {:msg, :approve_yes}
  end

  def event_to_msg(%Event.Text{text: text}, %{approval: %{}} = _state) when text in ["n", "N"] do
    {:msg, :approve_no}
  end

  def event_to_msg(%Event.Key{key: key}, %{diff: diff} = _state)
      when diff != nil and key in ["d", "D", :escape] do
    {:msg, :dismiss_diff}
  end

  def event_to_msg(%Event.Key{key: :enter}, state), do: {:msg, {:submit, state.input}}
  def event_to_msg(%Event.Key{key: :backspace}, _state), do: {:msg, :backspace}

  def event_to_msg(%Event.Key{key: key, modifiers: mods}, _state) do
    ctrl = :ctrl in mods

    cond do
      ctrl and key in ["b", "B"] -> {:msg, :toggle_sidebar}
      ctrl and key in ["p", "P"] -> {:msg, :toggle_palette}
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
    new_input = String.slice(state.input, 0, String.length(state.input) - 1)

    palette =
      String.starts_with?(new_input, "/") and not String.contains?(new_input, " ") and
        new_input != ""

    %{state | input: new_input, palette: palette}
  end

  def update({:text, text}, state) do
    new_input = state.input <> text

    palette =
      state.palette or
        (String.starts_with?(new_input, "/") and not String.contains?(new_input, " "))

    %{state | input: new_input, palette: palette}
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

  def update({:submit, text}, %{palette: true} = state) do
    if String.contains?(text, " ") do
      # Full command with args typed directly (e.g. "/provider ollama")
      state = %{state | palette: false, input: ""}
      handle_slash(String.trim(text), state)
    else
      commands = [
        "/plan",
        "/build",
        "/review",
        "/provider",
        "/usage",
        "/context",
        "/help",
        "/exit"
      ]

      filter = String.downcase(text)
      matches = Enum.filter(commands, fn c -> String.contains?(String.downcase(c), filter) end)
      selected = List.first(matches) || String.trim(text)
      state = %{state | palette: false, input: ""}
      handle_slash(selected, state)
    end
  end

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

  def update(:approve_yes, %{approval: %{reply_to: pid}} = state) do
    send(pid, {:approval, :yes})
    %{state | approval: nil} |> append("Allowed.")
  end

  def update(:approve_no, %{approval: %{reply_to: pid}} = state) do
    send(pid, {:approval, :no})
    %{state | approval: nil} |> append("Denied.")
  end

  def update(:dismiss_diff, state) do
    %{state | diff: nil}
  end

  def update(:toggle_sidebar, state) do
    %{state | sidebar: !state.sidebar}
  end

  def update(:toggle_palette, state) do
    %{state | palette: !state.palette, input: ""}
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

  def handle_info({:approval_request, tool_name, path, reply_to}, state) do
    state = append(state, "PROTECTED FILE: #{path} (#{tool_name}) — allow? [y/N]")
    %{state | approval: %{tool: tool_name, path: path, reply_to: reply_to}}
  end

  def handle_info({:diff, path, before, after_text}, state) do
    widget_state =
      TermUI.Widget.DiffViewer.init(
        before: before,
        after: after_text,
        old_label: path <> " (before)",
        new_label: path <> " (after)"
      )

    %{state | diff: widget_state}
  end

  def handle_info({:tool_call, name, args}, state) do
    line = "[tool] #{name}(#{format_args(args)})"
    append(state, line)
  end

  def handle_info({:tool_result, name, result}, state) do
    truncated = result |> to_string() |> String.slice(0, 300)
    suffix = if String.length(result |> to_string()) > 300, do: "...", else: ""
    append(state, "  -> #{name}: #{truncated}#{suffix}")
  end

  def handle_info({:output_chunk, text}, state) do
    append_chunk(state, text)
  end

  def handle_info(_msg, state), do: state

  @impl true
  def view(state) do
    {width, height} = state.dimensions
    sidebar_width = if state.sidebar, do: 28, else: 0
    body_height = max(1, height - 3)
    right_width = max(1, width - sidebar_width - if(state.sidebar, do: 1, else: 0))

    visible =
      state.output
      |> Enum.reverse()
      |> Enum.drop(state.scroll)
      |> Enum.take(body_height)
      |> Enum.reverse()

    rows = visible ++ List.duplicate("", body_height - length(visible))

    status_style = Style.new(fg: :cyan, attrs: [:bold])
    busy_tag = if state.busy, do: " [busy]", else: ""
    palette_hint = if state.palette, do: " [palette]", else: ""

    status =
      " #{mode_label(state.mode)} | #{state.provider}:#{state.model}#{busy_tag}#{palette_hint} (Ctrl+P palette, Ctrl+B sidebar)"

    input_line = "> " <> state.input

    # Build two-column rows if sidebar enabled
    all_rows =
      if state.sidebar do
        Enum.map(Enum.with_index(rows), fn {r, i} ->
          left =
            Enum.at(state.tree_lines, i, "")
            |> String.slice(0, sidebar_width)
            |> String.pad_trailing(sidebar_width)

          "#{left}│#{String.slice(r, 0, right_width) |> String.pad_trailing(right_width)}"
        end)
      else
        rows
      end

    all_rows = all_rows ++ [[{status, status_style}], input_line]

    base_frame = Frame.from_rows(all_rows, width, height)

    # Overlay palette if open
    base_frame =
      if state.palette do
        commands = [
          "/plan",
          "/build",
          "/review",
          "/provider",
          "/usage",
          "/context",
          "/help",
          "/exit"
        ]

        filter = String.downcase(state.input)
        matches = Enum.filter(commands, fn c -> String.contains?(String.downcase(c), filter) end)
        matches = if matches == [], do: commands, else: matches

        palette_lines = ["Command Palette (Enter to run, Esc/Ctrl+P to close):"] ++ matches
        palette_height = min(length(palette_lines) + 2, height - 2)
        palette_width = 40
        col = div(width - palette_width, 2) + 1
        row = div(height - palette_height, 2) + 1

        palette_frame = Frame.from_rows(palette_lines, palette_width, palette_height)
        Frame.overlay(base_frame, palette_frame, col, row)
      else
        base_frame
      end

    # Overlay diff if present
    case state.diff do
      nil ->
        base_frame

      widget_state ->
        diff_frame = TermUI.Widget.DiffViewer.view(widget_state, {width, height})
        Frame.overlay(base_frame, diff_frame, 1, 1)
    end
  end

  defp append(state, text) do
    lines = String.split(text, "\n")
    new_output = (state.output ++ lines) |> Enum.take(-@max_output_lines)
    %{state | output: new_output}
  end

  defp format_args(args) when is_map(args) do
    args
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v, limit: 2, printable_limit: 40)}" end)
    |> Enum.join(", ")
  end

  defp format_args(other), do: inspect(other, limit: 2, printable_limit: 40)

  defp append_chunk(state, text) do
    new_output =
      case state.output do
        [] ->
          [text]

        lines ->
          last = List.last(lines)
          List.replace_at(lines, length(lines) - 1, last <> text)
      end

    %{state | output: new_output |> Enum.take(-@max_output_lines)}
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

      ["models"] ->
        info = safe_provider_info(state.agent)
        fetch_and_show_models(info.provider, state)

      ["models", "all"] ->
        lines =
          Ella.Llm.Provider.providers()
          |> Enum.map(fn p ->
            models = Ella.Llm.Provider.default_models(p.name)
            ids = Enum.map(models, & &1["id"]) |> Enum.join(", ")
            "#{p.name}: #{ids}"
          end)

        Enum.reduce(lines, state, fn line, acc -> append(acc, line) end)

      ["models", provider] ->
        fetch_and_show_models(provider, state)

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
        append(
          state,
          "Usage: /provider | /provider list | /provider <name> | /provider model <provider> <model>"
        )
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

  defp fetch_and_show_models(provider, state) do
    case Ella.LlmClient.fetch_models_from_api(provider) do
      {:ok, []} ->
        append(state, "No models from API; showing known defaults.")
        show_known_models(provider, state)

      {:ok, models} when is_list(models) ->
        lines =
          ["#{length(models)} model(s) from #{provider} API:"] ++
            Enum.map(models, fn m -> "  #{m["id"]}" end)

        Enum.reduce(lines, state, fn line, acc -> append(acc, line) end)

      {:error, reason} ->
        append(state, "Failed to fetch: #{reason}. Showing known defaults.")
        show_known_models(provider, state)
    end
  rescue
    _ -> show_known_models(provider, state)
  end

  defp show_known_models(provider, state) do
    models = Ella.Llm.Provider.default_models(provider)

    if Enum.empty?(models) do
      append(state, "No known models for #{provider}.")
    else
      lines =
        ["Known models for #{provider}:"] ++
          Enum.map(models, fn m -> "  #{m["id"]} — #{m["description"]}" end)

      Enum.reduce(lines, state, fn line, acc -> append(acc, line) end)
    end
  end

  defp safe_provider_info(pid) do
    Ella.Agent.provider_info(pid)
  rescue
    _ -> %{provider: "unknown", model: "unknown"}
  end
end
