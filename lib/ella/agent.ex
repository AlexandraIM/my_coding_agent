defmodule Ella.Agent do
  use GenServer

  alias Ella.LlmClient
  alias Ella.ProjectRules
  alias Ella.Mcp.ToolAdapter
  alias Ella.Storage
  alias Ella.Tool
  alias Ella.Snapshot

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  # :infinity тут свідомо: поки агент працює, користувач не може
  # нічого ввести, а передчасний timeout обривав би корисну роботу.
  # Див. обмеження ітерацій run_loop — воно реально обмежує тривалість.
  def ask(pid, user_prompt) do
    GenServer.call(pid, {:ask, user_prompt}, :infinity)
  end

  def set_mode(pid, mode) when mode in [:plan, :build] do
    GenServer.call(pid, {:set_mode, mode})
  end

  @doc """
  Реєстрація нового MCP-сервера в агента.

  На відміну від `ask/2` має таймаут: запуск зовнішнього процесу не
  повинен зависати назавжди, якщо сервер мовчить у відповідь.
  """
  def register_mcp(pid, executable, args, timeout \\ 60_000) do
    GenServer.call(pid, {:register_mcp, executable, args}, timeout)
  end

  @doc "Повертає накопичений облік токенів і вартості за сесію."
  def usage(pid), do: GenServer.call(pid, :usage)

  @doc "Скидає облік токенів."
  def reset_usage(pid), do: GenServer.call(pid, :reset_usage)

  @doc "Кількість повідомлень у поточній історії та їх орієнтовний розмір."
  def context_info(pid), do: GenServer.call(pid, :context_info)

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    Storage.ensure_storage_created!()
    {:ok, _snapshot} = Snapshot.ensure_started()

    mode = Keyword.get(opts, :mode, :plan)

    all_tools =
      Keyword.get(opts, :tools, [
        Ella.Tools.ReadFile,
        Ella.Tools.Grep,
        Ella.Tools.Glob,
        Ella.Tools.ListDir,
        Ella.Tools.WriteFile,
        Ella.Tools.ApplyPatch,
        Ella.Tools.SystemExec,
        Ella.Tools.DelegateTask,
        Ella.Tools.LoadSkill
      ])

    llm_opts =
      opts
      |> Keyword.get(:llm_opts, [])
      |> Keyword.put_new_lazy(:max_attempts, fn -> Ella.Config.max_attempts() end)

    project_rules = ProjectRules.load_rules()
    skills = Ella.Skills.load_all()

    if skills != [] do
      Owl.IO.puts(Owl.Data.tag("Loaded #{length(skills)} project skill(s)", :magenta))
    end

    # Бюджет береться з конфігу, але явна опція агента має пріоритет:
    # тести й вкладені агенти передають власні межі.
    context_opts =
      opts
      |> Keyword.take([
        :context_budget,
        :max_context_tokens,
        :keep_recent,
        :max_tool_result_chars,
        :summary_max_entries
      ])
      |> Keyword.put_new_lazy(:context_budget, fn -> Ella.Config.context_budget() end)

    state = %{
      mode: mode,
      messages: [],
      all_tools: all_tools,
      mcp_clients: [],
      mcp_tools: [],
      llm_opts: llm_opts,
      project_rules: project_rules,
      skills: skills,
      active_skill: nil,
      context_opts: context_opts,
      usage: Ella.Llm.Usage.empty(),
      max_iterations:
        Keyword.get_lazy(opts, :max_iterations, fn -> Ella.Config.max_iterations() end)
    }

    state = restore_saved_mcps(state)
    publish_context(state)

    {:ok, update_system_prompt(state)}
  end

  @impl true
  def handle_call({:set_mode, new_mode}, _from, state) do
    new_state = %{state | mode: new_mode} |> update_system_prompt()
    publish_context(new_state)
    mode_name = if new_mode == :plan, do: "PLANNING (Read-Only)", else: "BUILDING (Full Access)"

    Owl.IO.puts(Owl.Data.tag("Switched to #{mode_name} mode.", :magenta))
    {:reply, {:ok, new_mode}, new_state}
  end

  @impl true
  def handle_call({:register_mcp, executable, args}, _from, state) do
    case Ella.Mcp.Client.start_link(executable, args) do
      {:ok, mcp_pid} ->
        case Ella.Mcp.Client.list_tools(mcp_pid) do
          {:ok, %{"tools" => tools}} ->
            wrapped_tools = Enum.map(tools, &ToolAdapter.to_agent_tool(mcp_pid, &1))

            new_state = %{
              state
              | mcp_clients: [mcp_pid | state.mcp_clients],
                mcp_tools: state.mcp_tools ++ wrapped_tools
            }

            # ЗБЕРІГАЄМО У ПАПКУ .my_agent/mcp.json!
            server_name = Path.basename(executable) <> "_" <> Enum.join(args, "_")
            Storage.save_mcp_server(server_name, executable, args)

            Owl.IO.puts(
              Owl.Data.tag(
                "Зареєстровано та збережено #{length(wrapped_tools)} MCP tools",
                :green
              )
            )

            {:reply, {:ok, length(wrapped_tools)}, new_state}

          {:error, err} ->
            {:reply, {:error, err}, state}
        end

      {:error, err} ->
        {:reply, {:error, err}, state}
    end
  end

  @impl true
  def handle_call(:usage, _from, state) do
    {:reply, state.usage, state}
  end

  @impl true
  def handle_call(:reset_usage, _from, state) do
    {:reply, :ok, %{state | usage: Ella.Llm.Usage.empty()}}
  end

  @impl true
  def handle_call(:context_info, _from, state) do
    info = %{
      messages: length(state.messages),
      estimated_tokens: Ella.Context.estimate(state.messages),
      budget: Ella.Context.budget(state.context_opts)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:reload_skills, _from, state) do
    skills = Ella.Skills.load_all()
    new_state = %{state | skills: skills, active_skill: nil} |> update_system_prompt()
    publish_context(new_state)

    Owl.IO.puts(Owl.Data.tag("Reloaded #{length(skills)} project skill(s)", :magenta))
    {:reply, Enum.map(skills, & &1.name), new_state}
  end

  @impl true
  def handle_call(:skills, _from, state) do
    {:reply, Enum.map(state.skills, &{&1.name, &1.description}), state}
  end

  @impl true
  def handle_call(:active_skill, _from, state) do
    {:reply, state.active_skill && state.active_skill.name, state}
  end

  @impl true
  def handle_call({:activate_skill, name}, _from, state) do
    case Ella.Skills.find(state.skills, name) do
      {:ok, skill} ->
        new_state = %{state | active_skill: skill}
        publish_context(new_state)
        {:reply, {:ok, skill}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:ask, user_prompt}, _from, state) do
    Owl.IO.puts([Owl.Data.tag("User: ", :green), user_prompt])

    # Нова задача — нові правила: обмеження навички з минулого
    # запиту більше не діють.
    state = %{state | active_skill: nil} |> tap(&publish_context/1)

    new_messages = state.messages ++ [%{"role" => "user", "content" => user_prompt}]
    active_tools = get_active_tools(state)

    case run_loop(new_messages, active_tools, state, 0) do
      {:ok, final_messages, response_text, usage} ->
        {:reply, {:ok, response_text}, %{state | messages: final_messages, usage: usage}}

      {:error, reason, usage} ->
        {:reply, {:error, Ella.Llm.Error.message(reason)}, %{state | usage: usage}}
    end
  end

  # --- Helper & Tool Execution ---

  # У plan mode агент може читати й шукати, але не може змінювати стан.
  # system_exec тут свідомо відсутній: через шелл можна і писати
  # (`> file`), і видаляти.
  @plan_mode_tools ~w(read_file grep glob list_dir delegate_task load_skill)

  defp get_active_tools(%{mode: :plan} = state) do
    %{all_tools: tools, mcp_tools: mcp_tools} = state
    plan_local = Enum.filter(tools, fn tool -> tool.name() in @plan_mode_tools end)

    # MCP-інструменти додаються в plan mode лише тоді, коли сервер
    # явно підтвердив, що вони не змінюють стан.
    plan_mcp = Enum.filter(mcp_tools, & &1.read_only)

    dropped = length(mcp_tools) - length(plan_mcp)

    if dropped > 0 do
      Owl.IO.puts(
        Owl.Data.tag(
          "[plan mode] #{dropped} MCP tool(s) hidden: not marked read-only.",
          :yellow
        )
      )
    end

    (plan_local ++ plan_mcp)
    |> apply_skill_restriction(state)
  end

  defp get_active_tools(%{mode: :build} = state) do
    (state.all_tools ++ state.mcp_tools)
    |> apply_skill_restriction(state)
  end

  # Активна навичка може звузити набір інструментів: наприклад,
  # «лише аналіз, нічого не змінюй». Це обмеження діє до кінця
  # поточного запиту користувача.
  defp apply_skill_restriction(tools, %{active_skill: nil}), do: tools

  defp apply_skill_restriction(tools, %{active_skill: skill}) do
    Enum.filter(tools, fn tool -> Ella.Skills.allows?(skill, tool_name(tool)) end)
    |> ensure_load_skill()
  end

  # Навичку можна завантажити завжди — інакше агент, що працює за
  # нею, не зміг би зняти обмеження.
  defp ensure_load_skill(tools) do
    if Enum.any?(tools, &(tool_name(&1) == "load_skill")) do
      tools
    else
      tools ++ [Ella.Tools.LoadSkill]
    end
  end

  defp tool_name(%{name: name}), do: name
  defp tool_name(module) when is_atom(module), do: module.name()

  def build_tool_schemas(active_tools) do
    Enum.map(active_tools, fn
      %{type: :mcp, name: name, description: desc, parameters: params} ->
        %{
          "type" => "function",
          "function" => %{
            "name" => name,
            "description" => desc,
            "parameters" => params
          }
        }

      tool_module when is_atom(tool_module) ->
        Ella.Tool.to_schema(tool_module)
    end)
  end

  defp update_system_prompt(%{mode: :plan} = state) do
    prompt =
      """
      You are an AI Architect working in PLAN MODE.
      Your goal is to analyze the codebase, ask clarifying questions, and design a detailed, step-by-step implementation plan.

      STRICT RULES FOR PLAN MODE:
      1. DO NOT write or modify any files. File modification tools are DISABLED.
      2. Explore before proposing: start with `list_dir`, then use `grep` and `glob`
         to locate the relevant code, and read only the files that matter.
      3. Use `read_file` with `offset`/`limit` for large files instead of reading them whole.
      4. Output your plan in clean Markdown with numbered steps.
      5. Ask the user if they agree with the plan before proceeding to Build Mode.
      6. Always respond to the user in the language they used (e.g., Ukrainian).
      """ <> state.project_rules <> skills_catalog(state)

    set_system_message(state, prompt)
  end

  defp update_system_prompt(%{mode: :build} = state) do
    prompt =
      """
      You are an AI Software Engineer working in BUILD MODE.
      Your goal is to execute the agreed implementation plan accurately.

      STRICT RULES FOR BUILD MODE:
      1. Inspect relevant files before editing. Locate them with `grep`/`glob` rather than
         guessing paths, and use `read_file` with offset/limit for large files.
      2. Prefer precise edits using `apply_patch` instead of overwriting files.
      3. Run checks/tests via `system_exec` after edits.
      4. Always respond to the user in the language they used (e.g., Ukrainian).
      """ <> state.project_rules <> skills_catalog(state)

    set_system_message(state, prompt)
  end

  defp skills_catalog(state), do: Ella.Skills.catalog(state.skills)

  # Інструменти виконуються у процесі агента, а DelegateTask потребує
  # знати поточний режим і налаштування LLM. Process dictionary — найпростіший
  # спосіб це передати без розширення контракту інструментів.
  defp publish_context(state) do
    Process.put(:ella_agent_mode, state.mode)
    Process.put(:ella_agent_llm_opts, state.llm_opts)
    Process.put(:ella_agent_skills, state.skills)
  end

  @doc """
  Перечитує навички з диска та повертає їхні назви.
  """
  def reload_skills(pid) do
    GenServer.call(pid, :reload_skills)
  end

  @doc """
  Список доступних навичок (назва та опис).
  """
  def skills(pid), do: GenServer.call(pid, :skills)

  @doc """
  Назва навички, що обмежує інструменти в поточному кроці, або nil.
  """
  def active_skill(pid), do: GenServer.call(pid, :active_skill)

  defp set_system_message(state, prompt) do
    filtered_messages = Enum.reject(state.messages, fn m -> m["role"] == "system" end)
    %{state | messages: [%{"role" => "system", "content" => prompt} | filtered_messages]}
  end

  # --- Agentic Loop ---

  defp run_loop(messages, _active_tools, state, current_iter)
       when current_iter >= state.max_iterations do
    notice =
      "Iteration limit reached (#{state.max_iterations}). " <>
        "Stopping the loop and returning control to the user."

    Owl.IO.puts(Owl.Data.tag(notice, :yellow))

    # Форма повернення має збігатися з handle_call: історія, текст
    # відповіді та облік. Раніше тут бракувало повідомлень, тож
    # досягнення ліміту ламало весь агентський цикл.
    {:ok, messages, notice, state.usage}
  end

  defp run_loop(messages, active_tools, state, current_iter) do
    tool_map = build_tool_map(active_tools)
    Owl.IO.puts(Owl.Data.tag("Thinking (#{state.mode} mode)...", :cyan))

    prepared = prepare_context(messages, state)

    case prepared do
      {:error, reason} ->
        {:error, reason, state.usage}

      {:ok, context_messages} ->
        # Агент продовжує саме зі стиснутою історією: наступні кроки
        # додаються до неї, тож старі повідомлення не стискаються
        # вдруге на кожному кроці.
        continue_loop(
          context_messages,
          context_messages,
          active_tools,
          tool_map,
          state,
          current_iter
        )
    end
  end

  # API повертає точний prompt_tokens для запиту, який ми щойно
  # надіслали. Це найкраща можливість уточнити нашу грубу оцінку
  # «4 символи = 1 токен»: без неї агент ризикує впиратися в
  # контекстне вікно тоді, коли оцінка його недооцінює.
  defp calibrate(state, sent_messages, usage) do
    # Оцінка має бути «сирою», без уже застосованого коефіцієнта,
    # інакше калібрування підсилювало б саме себе.
    raw_opts = Keyword.delete(state.context_opts, :estimate_factor)
    estimated = Ella.Context.estimate(sent_messages, raw_opts)

    prompt_tokens =
      case usage do
        %Ella.Llm.Usage{prompt_tokens: tokens} -> tokens
        _ -> nil
      end

    updated =
      Ella.Context.calibrate(Ella.Context.factor(state.context_opts), prompt_tokens,
        last_estimate: estimated
      )

    %{state | context_opts: Keyword.put(state.context_opts, :estimate_factor, updated)}
  end

  # Стискаємо історію перед запитом, щоб вона не перевищила вікно.
  # Повертаємо also початкові повідомлення: якщо стискання неможливе,
  # краще дати помилку зрозумілою, ніж відправити запит, який API відхилить.
  defp prepare_context(messages, state) do
    case Ella.Context.compact(messages, state.context_opts) do
      {:ok, compacted} ->
        if compacted != messages do
          before = Ella.Context.estimate(messages)
          after_compact = Ella.Context.estimate(compacted)

          Owl.IO.puts(
            Owl.Data.tag(
              "[context] compacted #{before} -> #{after_compact} tokens " <>
                "(#{length(messages)} -> #{length(compacted)} messages)",
              :yellow
            )
          )
        end

        {:ok, compacted}

      {:error, :too_large} ->
        {:error,
         Ella.Llm.Error.permanent(
           "Conversation exceeds the context budget even after compaction " <>
             "(#{Ella.Context.estimate(messages)} tokens, budget " <>
             "#{Ella.Context.budget(state.context_opts)}). " <>
             "Start a new session to continue."
         )}
    end
  end

  defp continue_loop(
         context_messages,
         original_messages,
         active_tools,
         tool_map,
         state,
         current_iter
       ) do
    llm_opts = streaming_opts(state)

    case LlmClient.chat_completion(context_messages, active_tools, llm_opts) do
      {:ok, %{"tool_calls" => tool_calls} = message, usage}
      when is_list(tool_calls) and length(tool_calls) > 0 ->
        # API вимагає role у кожному повідомленні, але не всі адаптери
        # її проставлять для відповіді з викликами інструментів.
        message = Map.put_new(message, "role", "assistant")

        state =
          state
          |> calibrate(context_messages, usage)
          |> then(&%{&1 | usage: Ella.Llm.Usage.add(&1.usage, usage)})

        updated_messages = original_messages ++ [message]

        tool_results_messages =
          Enum.map(tool_calls, fn call ->
            tool_name = call["function"]["name"]
            call_id = call["id"]

            Owl.IO.puts([
              Owl.Data.tag("Tool Call [#{tool_name}]: ", :yellow),
              inspect(call["function"]["arguments"])
            ])

            result_text = execute_tool_call(call, tool_name, tool_map)

            %{"role" => "tool", "tool_call_id" => call_id, "content" => result_text}
          end)

        run_loop(
          updated_messages ++ tool_results_messages,
          active_tools,
          state,
          current_iter + 1
        )

      {:ok, %{"content" => content} = message, usage}
      when not is_nil(content) and content != "" ->
        state =
          state
          |> calibrate(context_messages, usage)
          |> then(&%{&1 | usage: Ella.Llm.Usage.add(&1.usage, usage)})

        finish_turn(content)
        {:ok, original_messages ++ [message], content, state.usage}

      {:ok, message, usage} ->
        state =
          state
          |> calibrate(context_messages, usage)
          |> then(&%{&1 | usage: Ella.Llm.Usage.add(&1.usage, usage)})

        finish_turn(message["content"] || "Done.")
        {:ok, original_messages ++ [message], message["content"] || "Done.", state.usage}

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Error calling LLM: #{Ella.Llm.Error.message(reason)}", :red))
        {:error, reason, state.usage}
    end
  end

  # Під час стріму текст уже надруковано по фрагментах, тому
  # друкуємо лише перенос рядка, щоб не продублювати його.
  defp finish_turn(content) do
    if streamed?() do
      IO.puts("")
      IO.puts("")
    else
      Owl.IO.puts([Owl.Data.tag("Agent: ", :blue), content])
    end
  end

  defp streamed?, do: Process.get(:ella_streaming, false)

  # Під час стріму друкуємо фрагменти як є: довгі рядки через Owl
  # зливались б в один, а короткі не переносилися б.
  defp streaming_opts(state) do
    Keyword.put(state.llm_opts, :on_text, fn fragment ->
      Process.put(:ella_streaming, true)

      if String.length(fragment) > 80 do
        Owl.IO.puts(Owl.Data.tag(fragment, :blue))
      else
        IO.write(fragment)
      end

      :ok
    end)
  end

  # Інструмент працює у процесі агента, тому може оновити стан
  # напряму. Повертає nil, якщо це не load_skill, і виклик іде
  # далі звичайним шляхом.
  defp activate_skill("load_skill", %{"name" => name}) when is_binary(name) do
    GenServer.call(self(), {:activate_skill, name})
  end

  defp activate_skill(_tool_name, _args), do: nil

  defp build_tool_map(tools) do
    Enum.into(tools, %{}, fn
      %{name: name} = mcp_tool -> {name, mcp_tool}
      tool_module when is_atom(tool_module) -> {tool_module.name(), tool_module}
    end)
  end

  defp execute_tool_call(call, tool_name, tool_map) do
    encoded = call["function"]["arguments"]

    case Tool.parse_args(encoded) do
      {:ok, tool_args} ->
        activate_skill(tool_name, tool_args) || execute_tool(tool_name, tool_args, tool_map)

      {:error, reason} ->
        "ERROR: #{reason}"
    end
  end

  defp execute_tool(name, args, tool_map) do
    case Map.fetch(tool_map, name) do
      {:ok, %{type: :mcp, mcp_pid: pid, raw_name: raw_name}} ->
        try do
          case ToolAdapter.execute(pid, raw_name, args) do
            {:ok, output} -> output
            {:error, err} -> "ERROR: #{err}"
          end
        rescue
          e -> "ERROR executing MCP tool '#{name}': #{Exception.message(e)}"
        end

      {:ok, tool_module} when is_atom(tool_module) ->
        try do
          case tool_module.execute(args) do
            {:ok, output} -> output
            {:error, err} -> "ERROR: #{err}"
          end
        rescue
          e -> "ERROR executing tool '#{name}': #{Exception.message(e)}"
        end

      :error ->
        "ERROR: Tool '#{name}' is disabled or not registered."
    end
  end

  # Хелпер для відновлення збережених MCP при старті
  @doc false
  # У тестах MCP не піднімається: процеси реальні, повільні й залежать від
  # локального ~/.ella/mcp.json. Продакшн-шлях не змінюється.
  def restore_mcp?, do: Application.get_env(:ella, :restore_mcp, true)

  defp restore_saved_mcps(state) do
    if restore_mcp?() do
      do_restore_saved_mcps(state)
    else
      state
    end
  end

  defp do_restore_saved_mcps(state) do
    saved_servers = Storage.load_mcp_config()

    Enum.reduce(saved_servers, state, fn {name, %{"command" => exec, "args" => args}},
                                         acc_state ->
      case Ella.Mcp.Client.start_link(exec, args) do
        {:ok, mcp_pid} ->
          case Ella.Mcp.Client.list_tools(mcp_pid) do
            {:ok, %{"tools" => tools}} ->
              wrapped_tools = Enum.map(tools, &ToolAdapter.to_agent_tool(mcp_pid, &1))

              Owl.IO.puts(
                Owl.Data.tag(
                  "Auto-restored MCP [#{name}] with #{length(wrapped_tools)} tools",
                  :green
                )
              )

              %{
                acc_state
                | mcp_clients: [mcp_pid | acc_state.mcp_clients],
                  mcp_tools: acc_state.mcp_tools ++ wrapped_tools
              }

            _ ->
              acc_state
          end

        _ ->
          acc_state
      end
    end)
  end
end
