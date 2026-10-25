defmodule Ella.SubAgent do
  @doc """
  Universal sub-agent for executing isolated sub-tasks (research, code fixing, testing).
  """
  use GenServer

  alias Ella.Context
  alias Ella.Llm.Usage
  alias Ella.LlmClient
  alias Ella.Snapshot
  alias Ella.Tool

  # --- Client API ---

  def run_task(task_description, tools \\ all_tools(), llm_opts \\ []) do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, task: task_description, tools: tools, llm_opts: llm_opts)

    GenServer.call(pid, :execute, :infinity)
  end

  # Повний набір інструментів за замовчуванням (включаючи редагування та запис)
  def all_tools do
    [
      Ella.Tools.ReadFile,
      Ella.Tools.Grep,
      Ella.Tools.Glob,
      Ella.Tools.ListDir,
      Ella.Tools.WriteFile,
      Ella.Tools.ApplyPatch,
      Ella.Tools.SystemExec
    ]
  end

  @doc """
  Набір інструментів без права зміни стану.

  Використовується, коли головний агент у plan mode делегує завдання:
  інакше write_file/apply_patch всередині сабагента обійшли б read-only
  режим, оскільки DelegateTask доступний у plan mode.

  SystemExec свідомо відсутній: він дозволяє змінити стан через шелл
  (`> file`, `rm`), тому в plan mode недоступний ні головному агенту,
  ні сабагенту. Пошук і читання лишаються доступними.
  """
  def read_only_tools do
    [
      Ella.Tools.ReadFile,
      Ella.Tools.Grep,
      Ella.Tools.Glob,
      Ella.Tools.ListDir
    ]
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    # Снапшот-сесія глобальна: головний агент її вже підняв, але
    # сабагент може стартувати й окремо (тести, прямий виклик) —
    # тоді WriteGuard не зможе записати резервну копію і заблокує запис.
    Snapshot.ensure_started()

    task = Keyword.fetch!(opts, :task)
    tools = Keyword.get(opts, :tools, all_tools())

    system_prompt = """
    You are an autonomous sub-agent handling an isolated sub-task for the primary agent.
    Your goal is to execute the assigned task precisely, whether it involves reading files, analyzing problems, or modifying code and running tests.

    RULES:
    1. Focus strictly on the task provided. Do not modify unrelated files or perform out-of-scope actions.
    2. Locate relevant code with `grep`/`glob` and read with `read_file` using offset/limit
       for large files, rather than reading whole files.
    3. If you edit code, verify your changes using `system_exec` if applicable.
    4. Return a clear, concise summary of what was done, including modified files or findings.
    """

    state = %{
      messages: [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => task}
      ],
      tools: tools,
      tool_map: Enum.into(tools, %{}, fn t -> {t.name(), t} end),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      context_opts: Keyword.get(opts, :context_opts, context_opts_defaults()),
      usage: Usage.empty(),
      # Сабагенти отримують вужчий контекст, тому ліміт ітерацій менший
      max_iterations: Keyword.get(opts, :max_iterations, 8)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:execute, _from, state) do
    Owl.IO.puts(Owl.Data.tag("[SubAgent] Executing sub-task...", :magenta))

    case run_loop(state.messages, state, 0) do
      {:ok, summary, usage} ->
        Owl.IO.puts(Owl.Data.tag("[SubAgent] Finished sub-task.", :green))
        {:stop, :normal, {:ok, summary, usage}, state}

      {:error, reason, usage} ->
        {:stop, :normal, {:error, reason, usage}, state}

      {:ok, summary} ->
        Owl.IO.puts(Owl.Data.tag("[SubAgent] Finished sub-task.", :green))
        {:stop, :normal, {:ok, summary, Usage.empty()}, state}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  defp context_opts_defaults do
    [
      context_budget: 32_000,
      keep_recent: 8,
      max_tool_result_chars: 1_500,
      summary_max_entries: 20
    ]
  end

  # --- Agentic Loop ---

  defp run_loop(_messages, state, current_iter) when current_iter >= state.max_iterations do
    {:ok,
     "Sub-agent reached the iteration limit (#{state.max_iterations}). Work summary attached.",
     state.usage}
  end

  defp run_loop(messages, state, current_iter) do
    Process.put(:ella_streaming, false)

    case Context.compact(messages, state.context_opts) do
      {:error, :too_large} ->
        {:error,
         "Conversation exceeds the context budget even after compaction " <>
           "(#{Context.estimate(messages)} tokens, budget " <>
           "#{Context.budget(state.context_opts)}). " <> "Start a new sub-task to continue.",
         state.usage}

      {:ok, compacted} ->
        opts = streaming_opts(state.llm_opts)

        case LlmClient.chat_completion(compacted, state.tools, opts) do
          {:ok, %{"tool_calls" => tool_calls} = message, usage}
          when is_list(tool_calls) and length(tool_calls) > 0 ->
            message = Map.put_new(message, "role", "assistant")
            state = %{state | usage: Usage.add(state.usage, usage)}

            if streamed?() do
              IO.puts("")
            end

            updated_messages = messages ++ [message]

            tool_results_messages =
              Enum.map(tool_calls, fn call ->
                tool_name = call["function"]["name"]
                call_id = call["id"]

                Owl.IO.puts([
                  Owl.Data.tag("  [SubAgent Tool]: #{tool_name} ", :yellow),
                  inspect(call["function"]["arguments"])
                ])

                result_text = execute_tool_call(call, tool_name, state.tool_map)
                %{"role" => "tool", "tool_call_id" => call_id, "content" => result_text}
              end)

            run_loop(updated_messages ++ tool_results_messages, state, current_iter + 1)

          {:ok, %{"content" => content}, usage} ->
            state = %{state | usage: Usage.add(state.usage, usage)}
            finish_turn(content)
            {:ok, content || "Task completed.", state.usage}

          {:ok, message, usage} ->
            state = %{state | usage: Usage.add(state.usage, usage)}
            finish_turn(message["content"])
            {:ok, message["content"] || "Task completed.", state.usage}

          {:error, reason} ->
            {:error, Ella.Llm.Error.message(reason), state.usage}
        end
    end
  end

  defp streamed?, do: Process.get(:ella_streaming, false)

  defp finish_turn(nil), do: :ok

  defp finish_turn(content) do
    if streamed?() do
      IO.puts("")
      IO.puts("")
    else
      Owl.IO.puts([Owl.Data.tag("[SubAgent] ", :blue), content])
    end
  end

  defp streaming_opts(llm_opts) do
    Keyword.put(llm_opts, :on_text, fn fragment ->
      Process.put(:ella_streaming, true)

      if String.length(fragment) > 80 do
        Owl.IO.puts(Owl.Data.tag(fragment, :blue))
      else
        IO.write(fragment)
      end

      :ok
    end)
  end

  defp execute_tool_call(call, tool_name, tool_map) do
    case Tool.parse_args(call["function"]["arguments"]) do
      {:ok, tool_args} -> execute_tool(tool_name, tool_args, tool_map)
      {:error, reason} -> "ERROR: #{reason}"
    end
  end

  defp execute_tool(name, args, tool_map) do
    case Map.fetch(tool_map, name) do
      {:ok, tool_module} ->
        try do
          case tool_module.execute(args) do
            {:ok, output} -> output
            {:error, err} -> "ERROR: #{err}"
          end
        rescue
          e -> "ERROR executing tool '#{name}': #{Exception.message(e)}"
        end

      :error ->
        "ERROR: Tool '#{name}' is not available to this sub-agent."
    end
  end
end
