defmodule Ella do
  @doc """
  Точка входу для `escript` і для релізу.

  Ставимо явний код виходу: за замовчуванням escript завершився б з 0
  незалежно від того, чи завершилась сесія успішно, а помилка при
  старті мала б давати ненульовий код.
  """
  def main(_argv) do
    start_cli()
    :ok
  catch
    kind, reason ->
      IO.puts(:stderr, "Ella exited unexpectedly: #{Exception.format(kind, reason, [])}\n")
      :ok
  end

  @doc """
  Запускає інтерактивний CLI. Повертає :ok або {:error, reason}.
  """
  def start_cli do
    # У релізі й escript застосунок уже стартував через :mod, тож
    # застосунки, яким це потрібно, піднімаємо самі.
    {:ok, _} = Application.ensure_all_started(:ssl)

    case Ella.Storage.load_provider() do
      {:ok, %{provider: provider}} -> System.put_env("LLM_PROVIDER", provider)
      _ -> :ok
    end

    print_setup()

    unless File.exists?(Ella.Storage.provider_path()) do
      Ella.Storage.save_provider(System.get_env("LLM_PROVIDER") || "openai")
    end

    Owl.IO.puts(Owl.Data.tag("=== Привіт це Ella, твій кодінг партнер! ===", :magenta))

    Owl.IO.puts(
      "Commands: /plan, /build, /review, /setup, /usage, /context, /skills, /protected, /limits, /rewind, /init, /provider, /save [name], /load [name], /sessions, /mcp [list|executable args...], /exit"
    )

    Owl.IO.puts(Owl.Data.tag("Type /help for the full command list.", :white))

    {:ok, pid} = Ella.Agent.start_link(mode: :plan)
    loop(pid, :plan)
  end

  defp print_usage(pid) do
    usage = Ella.Agent.usage(pid)

    Owl.IO.puts([
      Owl.Data.tag("Usage this session: ", :cyan),
      Ella.Llm.Usage.format(usage)
    ])
  rescue
    _ -> Owl.IO.puts("Usage is not available.")
  end

  defp print_context(pid) do
    info = Ella.Agent.context_info(pid)

    Owl.IO.puts([
      Owl.Data.tag("Context: ", :cyan),
      "#{info.messages} messages, ~#{info.estimated_tokens} of #{info.budget} tokens"
    ])
  rescue
    _ -> Owl.IO.puts("Context info is not available.")
  end

  defp print_skills(pid) do
    case Ella.Agent.skills(pid) do
      [] ->
        Owl.IO.puts("No skills found. Add .md files to .ella/skills/ or ~/.ella/skills/.")

      skills ->
        Owl.IO.puts(Owl.Data.tag("Project skills:", :cyan))

        Enum.each(skills, fn {name, description} ->
          Owl.IO.puts("  #{name}: #{description}")
        end)
    end
  rescue
    _ -> Owl.IO.puts("Skills are not available.")
  end

  defp print_protected do
    config = Ella.Config.load()
    paths = Ella.Config.protected_paths(config)

    Owl.IO.puts([
      Owl.Data.tag("Protected paths: ", :cyan),
      "#{length(paths)}",
      "\nApproval required: #{Ella.Config.require_approval?(config)}"
    ])

    Enum.each(paths, fn path -> Owl.IO.puts("  #{path}") end)

    if paths == [] do
      Owl.IO.puts("Add them to .ella/config.json under \"protected_paths\" to enable.")
    end
  rescue
    _ -> Owl.IO.puts("Protected paths are not available.")
  end

  defp print_limits do
    config = Ella.Config.load()

    Owl.IO.puts(Owl.Data.tag("Session limits (from .ella/config.json):", :cyan))

    Owl.IO.puts("  attempts per LLM call: #{Ella.Config.max_attempts(config)}")
    Owl.IO.puts("  request timeout: #{div(Ella.Config.request_timeout_ms(config), 1_000)}s")
    Owl.IO.puts("  context budget: #{Ella.Config.context_budget(config)} tokens")
    Owl.IO.puts("  max iterations: #{Ella.Config.max_iterations(config)}")
  rescue
    _ -> Owl.IO.puts("Session limits are not available.")
  end

  defp print_rewind do
    case Ella.Snapshot.rewind() do
      {:ok, %{restored: restored, removed: removed}} ->
        if restored == [] and removed == [] do
          Owl.IO.puts("Nothing to rewind.")
        else
          Owl.IO.puts(Owl.Data.tag("Rewound agent changes:", :cyan))

          Enum.each(restored, fn path ->
            Owl.IO.puts("  restored #{path}")
          end)

          Enum.each(removed, fn path ->
            Owl.IO.puts("  removed  #{path}")
          end)
        end

      {:error, :no_snapshot_session} ->
        Owl.IO.puts("No snapshot session is running.")

      {:error, reason} ->
        Owl.IO.puts("Rewind failed: #{inspect(reason)}")
    end
  end

  defp print_save(pid, name) do
    case Ella.Agent.save_session(pid, name) do
      {:ok, path} ->
        Owl.IO.puts(Owl.Data.tag("Saved session '#{name}' to #{path}", :green))

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Save failed: #{inspect(reason)}", :red))
    end
  rescue
    _ -> Owl.IO.puts("Save is not available.")
  end

  defp print_load(pid, name) do
    case Ella.Agent.load_session(pid, name) do
      {:ok, _} ->
        Owl.IO.puts(Owl.Data.tag("Loaded session '#{name}'.", :green))

      {:error, :not_found} ->
        Owl.IO.puts(Owl.Data.tag("Session '#{name}' not found.", :red))

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Load failed: #{inspect(reason)}", :red))
    end
  rescue
    _ -> Owl.IO.puts("Load is not available.")
  end

  defp print_sessions do
    case Ella.Agent.list_sessions() do
      [] ->
        Owl.IO.puts("No saved sessions.")

      names ->
        Owl.IO.puts(Owl.Data.tag("Saved sessions:", :cyan))
        Enum.each(names, fn n -> Owl.IO.puts("  #{n}") end)
    end
  rescue
    _ -> Owl.IO.puts("Sessions are not available.")
  end

  defp print_provider(pid, []) do
    info = Ella.Agent.provider_info(pid)
    provider_key = info.provider

    provider_meta = Ella.Llm.Provider.provider_info(provider_key)
    display_name = if provider_meta, do: Map.get(provider_meta, :display_name, provider_key), else: provider_key

    Owl.IO.puts(Owl.Data.tag("Current provider:", :cyan))
    Owl.IO.puts("  provider:     #{provider_key}")
    Owl.IO.puts("  display_name: #{display_name}")
    Owl.IO.puts("  adapter:      #{inspect(info.adapter)}")
    Owl.IO.puts("  model:        #{info.model}")
    Owl.IO.puts("  base_url:     #{info.base_url}")

    # Show API key status
    case System.get_env(Ella.Llm.Provider.api_key_env(provider_key)) do
      nil -> Owl.IO.puts("  api_key:      [not set]")
      "" -> Owl.IO.puts("  api_key:      [not set]")
      key -> Owl.IO.puts("  api_key:      [set: #{String.slice(key, 0, 8)}...]")
    end
  rescue
    _ -> Owl.IO.puts("Provider info is not available.")
  end

  defp print_provider(_pid, ["list"]) do
    Owl.IO.puts(Owl.Data.tag("Available providers:", :cyan))

    Enum.each(Ella.Llm.Provider.providers(), fn p ->
      Owl.IO.puts("  #{p.name} - #{p.display_name} (default: #{p.default_model})")
    end)

    Owl.IO.puts("")
    Owl.IO.puts("Use /provider models <provider> to see models for a specific provider.")
  end

  # /provider models - fetches from API by default (like other agents)
  defp print_provider(pid, ["models"]) do
    info = Ella.Agent.provider_info(pid)
    current_provider = info.provider
    show_fetched_models(current_provider)
  end

  # /provider models/all - show all providers' known models
  defp print_provider(_pid, ["models", "all"]) do
    Owl.IO.puts(Owl.Data.tag("Known models by provider:", :cyan))

    Enum.each(Ella.Llm.Provider.providers(), fn p ->
      Owl.IO.puts("\n#{p.display_name} (##{p.name}):")
      Enum.each(p.models, fn m ->
        Owl.IO.puts("  #{m["id"]} — #{m["description"]}")
      end)
    end)
  rescue
    _ -> Owl.IO.puts("Models are not available.")
  end

  # /provider models <provider> - fetch from API
  defp print_provider(_pid, ["models", provider]) when is_binary(provider) do
    show_fetched_models(provider)
  end

  # Fetch and show models from provider's API
  defp show_fetched_models(provider) when is_binary(provider) do
    Owl.IO.puts(Owl.Data.tag("Fetching models from #{provider} API...", :cyan))

    case Ella.LlmClient.fetch_models_from_api(provider) do
      {:ok, []} ->
        Owl.IO.puts(Owl.Data.tag("No models returned from API. Showing known defaults.", :yellow))
        show_known_models(provider)

      {:ok, models} when is_list(models) ->
        Owl.IO.puts("  #{length(models)} model(s) from API:")

        Enum.each(models, fn m ->
          Owl.IO.puts("    #{m["id"]}")
        end)

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Failed to fetch models: #{reason}. Showing known defaults.", :yellow))
        show_known_models(provider)
    end
  rescue
    _ -> show_known_models(provider)
  end

  defp show_known_models(provider) when is_binary(provider) do
    models = Ella.Llm.Provider.default_models(provider)
    provider_info = Ella.Llm.Provider.provider_info(provider)
    display_name = if provider_info, do: Map.get(provider_info, :display_name, provider), else: provider

    Owl.IO.puts(Owl.Data.tag("Known models for #{display_name} (#{provider}):", :cyan))

    if Enum.empty?(models) do
      Owl.IO.puts("  No known models.")
    else
      Enum.each(models, fn m ->
        Owl.IO.puts("  #{m["id"]} — #{m["description"]}")
      end)
    end
  rescue
    _ -> Owl.IO.puts("Models are not available.")
  end

  defp print_provider(_pid, ["test", provider]) when is_binary(provider) do
    opts = Ella.LlmClient.provider_opts(provider)

    case Ella.LlmClient.validate(opts) do
      :ok ->
        Owl.IO.puts(Owl.Data.tag("Provider '#{provider}' is reachable.", :green))

      {:error, reason} ->
        Owl.IO.puts(
          Owl.Data.tag(
            "Provider '#{provider}' unreachable: #{Ella.Llm.Error.message(reason)}",
            :red
          )
        )
    end
  rescue
    _ -> Owl.IO.puts("Provider test is not available.")
  end

  defp print_provider(pid, ["model", provider, model]) when is_binary(provider) and is_binary(model) do
    # Validate model exists for provider
    case Ella.Llm.Provider.valid_model?(provider, model) do
      false ->
        valid_models = Ella.Llm.Provider.default_models(provider)
        model_names = Enum.map(valid_models, & &1["id"])
        Owl.IO.puts(Owl.Data.tag("Model '#{model}' is not valid for provider '#{provider}'.", :yellow))
        Owl.IO.puts("Valid models: #{Enum.join(model_names, ", ")}")

      true ->
        case Ella.Agent.set_model(pid, model) do
          {:ok, ^model} ->
            Owl.IO.puts(Owl.Data.tag("Model for #{provider} set to #{model}.", :green))

          {:error, reason} ->
            Owl.IO.puts(Owl.Data.tag("Failed to set model: #{inspect(reason)}", :red))
        end
    end
  rescue
    _ -> Owl.IO.puts("Model change is not available.")
  end

  defp print_provider(pid, [provider]) when is_binary(provider) do
    case Ella.Agent.set_provider(pid, provider) do
      {:ok, provider} ->
        Owl.IO.puts(Owl.Data.tag("Switched to provider '#{provider}'.", :green))

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Switch failed: #{inspect(reason)}", :red))
    end
  rescue
    _ -> Owl.IO.puts("Provider switch is not available.")
  end

  defp print_provider(_pid, _) do
    Owl.IO.puts(
      "Usage: /provider | /provider list | /provider models [all|<provider>] | /provider test <provider> | /provider model <provider> <model> | /provider <name>"
    )
  end

  defp print_help do
    Owl.IO.puts(Owl.Data.tag("Available commands:", :cyan))

    commands = [
      {"/plan", "Switch to Plan mode (read-only)"},
      {"/build", "Switch to Build mode (full access)"},
      {"/review", "Switch to Review mode (read-only + checks)"},
      {"/provider", "Show current provider info"},
      {"/provider list", "List available providers"},
      {"/provider models", "Fetch models from current provider's API"},
      {"/provider models <p>", "Fetch models from provider's API"},
      {"/provider models all", "Show all models for all providers"},
      {"/provider test <p>", "Test provider connection"},
      {"/provider model <p> <m>", "Select model for provider"},
      {"/provider <name>", "Switch provider"},
      {"/setup", "Configure provider and API key"},
      {"/init", "Initialize .ella/ and AGENTS.md"},
      {"/mcp list", "List registered MCP servers"},
      {"/mcp <cmd> [args]", "Register an MCP server"},
      {"/skills", "List project skills"},
      {"/usage", "Show token usage this session"},
      {"/context", "Show context budget and usage"},
      {"/protected", "Show protected file paths"},
      {"/limits", "Show session limits"},
      {"/rewind", "Undo agent file changes"},
      {"/sessions", "List saved sessions"},
      {"/save [name]", "Save current session"},
      {"/load [name]", "Load a saved session"},
      {"/help", "Show this help message"},
      {"/exit", "Quit Ella"}
    ]

    Enum.each(commands, fn {cmd, desc} ->
      Owl.IO.puts([
        String.pad_leading(cmd, 24),
        "  #{desc}"
      ])
    end)
  end

  defp print_mcp_servers do
    servers = Ella.Storage.load_mcp_config()

    if map_size(servers) == 0 do
      Owl.IO.puts(Owl.Data.tag("No MCP servers registered.", :yellow))
    else
      Owl.IO.puts(Owl.Data.tag("Registered MCP servers:", :cyan))

      Enum.each(servers, fn {name, config} ->
        command = Map.get(config, "command", "unknown")
        args = Map.get(config, "args", [])
        args_str = if args == [], do: "", else: " " <> Enum.join(args, " ")
        Owl.IO.puts("  #{name}: #{command}#{args_str}")
      end)
    end
  rescue
    _ -> Owl.IO.puts("MCP servers are not available.")
  end

  defp print_setup do
    # У неінтерактивному середовищі (CI, pipe) не блокуємо запуск.
    unless interactive?() do
      :ok
    else
      provider = System.get_env("LLM_PROVIDER") || "openai"

      if provider_has_key?(provider) do
        :ok
      else
        Owl.IO.puts(Owl.Data.tag("No API key found for '#{provider}'.", :yellow))
        Owl.IO.puts("Let's set up a provider.")

        available_providers = Enum.map(Ella.Llm.Provider.providers(), & &1.name)
        prompt = "Provider (#{Enum.join(available_providers, "/")})"

        choice =
          Owl.IO.input(label: prompt)
          |> String.trim()

        provider = if choice == "", do: provider, else: choice
        System.put_env("LLM_PROVIDER", provider)
        Ella.Storage.save_provider(provider)

        unless Ella.Llm.Provider.requires_api_key?(provider) do
          key_env = Ella.Llm.Provider.api_key_env(provider)

          if System.get_env(key_env) in [nil, ""] do
            key = Owl.IO.input(label: "API key for #{provider}") |> String.trim()
            System.put_env(key_env, key)
          end
        end

        case Ella.LlmClient.validate(Ella.LlmClient.provider_opts(provider)) do
          :ok ->
            Owl.IO.puts(Owl.Data.tag("Connection OK.", :green))

          {:error, reason} ->
            Owl.IO.puts(
              Owl.Data.tag("Connection failed: #{Ella.Llm.Error.message(reason)}", :red)
            )
        end

        Ella.Storage.save_provider(provider)
        :ok
      end
    end
  end

  defp interactive? do
    case :io.columns() do
      {:error, _} -> false
      _ -> true
    end
  end

  defp provider_has_key?(provider) do
    provider_key = String.downcase(provider)

    case provider_key do
      "ollama" -> true
      "opencode" -> true
      _ ->
        key_env = Ella.Llm.Provider.api_key_env(provider)
        present?(System.get_env(key_env))
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp print_init do
    root = File.cwd!()
    ella_dir = Path.join(root, ".ella")
    config_path = Path.join(ella_dir, "config.json")
    agents_path = Path.join(root, "AGENTS.md")

    unless File.exists?(config_path) do
      File.mkdir_p!(ella_dir)

      File.write!(
        config_path,
        Jason.encode!(
          %{
            "protected_paths" => ["mix.exs", "mix.lock", ".formatter.exs", ".github/"],
            "require_approval" => true,
            "max_attempts" => 4,
            "request_timeout_ms" => 120_000,
            "context_budget" => 120_000,
            "max_iterations" => 30
          },
          pretty: true
        )
      )
    end

    unless File.exists?(agents_path) do
      File.write!(agents_path, """
      # Agent instructions

      Describe project-specific rules for the coding agent here: how to run
      tests, style conventions, architecture notes. The agent reads this file
      at startup.
      """)
    end

    Owl.IO.puts(Owl.Data.tag("Initialized .ella/ and AGENTS.md", :green))
  rescue
    e -> Owl.IO.puts(Owl.Data.tag("Init failed: #{Exception.message(e)}", :red))
  end

  defp loop(pid, mode) do
    mode_label =
      case mode do
        :plan -> "PLAN"
        :build -> "BUILD"
        :review -> "REVIEW"
      end

    mode_color =
      case mode do
        :plan -> :cyan
        :build -> :green
        :review -> :yellow
      end

    IO.puts("")
    Owl.IO.puts(Owl.Data.tag("─" <> String.duplicate("─", 58), :magenta))

    Owl.IO.puts([
      Owl.Data.tag("You [", mode_color),
      Owl.Data.tag(mode_label, mode_color),
      Owl.Data.tag("] ", mode_color)
    ])

    input =
      case Owl.IO.input(label: "You") do
        nil -> ""
        value -> value
      end
      |> String.trim()

    cond do
      input == "/exit" ->
        IO.puts("")
        Owl.IO.puts(Owl.Data.tag("Бувай, повертайся!", :magenta))

      input == "/help" ->
        print_help()
        loop(pid, mode)

      input == "/usage" ->
        print_usage(pid)
        loop(pid, mode)

      input == "/context" ->
        print_context(pid)
        loop(pid, mode)

      input == "/skills" ->
        print_skills(pid)
        loop(pid, mode)

      input == "/protected" ->
        print_protected()
        loop(pid, mode)

      input == "/limits" ->
        print_limits()
        loop(pid, mode)

      input == "/rewind" ->
        print_rewind()
        loop(pid, mode)

      input == "/sessions" ->
        print_sessions()
        loop(pid, mode)

      String.starts_with?(input, "/save") ->
        name = input |> String.replace_prefix("/save", "") |> String.trim()
        name = if name == "", do: "default", else: name
        print_save(pid, name)
        loop(pid, mode)

      String.starts_with?(input, "/load") ->
        name = input |> String.replace_prefix("/load", "") |> String.trim()
        name = if name == "", do: "default", else: name
        print_load(pid, name)
        loop(pid, mode)

      String.starts_with?(input, "/provider ") ->
        arg = input |> String.replace_prefix("/provider ", "") |> String.trim()
        parts = String.split(arg, " ", trim: true)
        print_provider(pid, parts)
        loop(pid, mode)

      input == "/provider" ->
        print_provider(pid, [])
        loop(pid, mode)

      input == "/plan" ->
        Ella.Agent.set_mode(pid, :plan)
        loop(pid, :plan)

      input == "/build" || input == "/execute" ->
        Ella.Agent.set_mode(pid, :build)
        loop(pid, :build)

      input == "/review" ->
        Ella.Agent.set_mode(pid, :review)
        loop(pid, :review)

      input == "/init" ->
        print_init()
        loop(pid, mode)

      input == "/setup" ->
        print_setup()
        loop(pid, mode)

      String.starts_with?(input, "/mcp ") ->
        cmd_str = String.replace_prefix(input, "/mcp ", "")

        case String.split(cmd_str, " ", trim: true) do
          ["list"] ->
            print_mcp_servers()

          [exec | args] ->
            case Ella.Agent.register_mcp(pid, exec, args) do
              {:ok, count} ->
                Owl.IO.puts(Owl.Data.tag("Зареєстровано #{count} MCP tool(s) з #{exec}.", :green))

              {:error, reason} ->
                Owl.IO.puts(Owl.Data.tag("MCP registration failed: #{inspect(reason)}", :red))
            end

          _ ->
            Owl.IO.puts("Usage: /mcp list | /mcp <executable> [args...]")
        end

        loop(pid, mode)

      input == "" ->
        loop(pid, mode)

      true ->
        Ella.Agent.ask(pid, input)
        loop(pid, mode)
    end
  end
end
