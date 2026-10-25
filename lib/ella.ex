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
      "Commands: /plan, /build, /review, /setup, /usage, /context, /skills, /protected, /limits, /rewind, /init, /provider [list|models <p>|test <p>|model <p> <m>|<name>], /save [name], /load [name], /sessions, /mcp list|<executable> [args...], /exit"
    )

    {:ok, pid} = Ella.Agent.start_link(mode: :plan)
    print_setup()
    loop(pid)
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

    Owl.IO.puts(Owl.Data.tag("Current provider:", :cyan))
    Owl.IO.puts("  provider: #{info.provider}")
    Owl.IO.puts("  adapter:  #{inspect(info.adapter)}")
    Owl.IO.puts("  model:    #{info.model}")
    Owl.IO.puts("  base_url: #{info.base_url}")
  rescue
    _ -> Owl.IO.puts("Provider info is not available.")
  end

  defp print_provider(_pid, ["list"]) do
    Owl.IO.puts(Owl.Data.tag("Available providers:", :cyan))

    Enum.each(["openai", "poolside", "mistral", "ollama", "opencode"], fn p ->
      Owl.IO.puts("  #{p}")
    end)
  end

  defp print_provider(_pid, ["models", provider]) do
    models = Ella.LlmClient.available_models(provider)

    if models == [] do
      Owl.IO.puts(Owl.Data.tag("No known models for '#{provider}'.", :yellow))
    else
      Owl.IO.puts(Owl.Data.tag("Available models for #{provider}:", :cyan))

      Enum.each(models, fn m ->
        Owl.IO.puts("  #{m["id"]} — #{m["description"]}")
      end)
    end
  rescue
    _ -> Owl.IO.puts("Models are not available.")
  end

  defp print_provider(_pid, ["test", provider]) do
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

  defp print_provider(pid, ["model", provider, model]) do
    case Ella.Agent.set_model(pid, model) do
      {:ok, ^model} ->
        Owl.IO.puts(Owl.Data.tag("Model for #{provider} set to #{model}.", :green))

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Failed to set model: #{inspect(reason)}", :red))
    end
  rescue
    _ -> Owl.IO.puts("Model change is not available.")
  end

  defp print_provider(pid, [provider]) do
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
      "Usage: /provider | /provider list | /provider models <provider> | /provider test <provider> | /provider model <provider> <model> | /provider <name>"
    )
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

        choice =
          Owl.IO.input(label: "Provider (openai/poolside/mistral/ollama/opencode)")
          |> String.trim()

        provider = if choice == "", do: provider, else: choice
        System.put_env("LLM_PROVIDER", provider)
        Ella.Storage.save_provider(provider)

        unless provider in ["ollama", "opencode"] do
          key_env = key_env_for(provider)

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
    case String.downcase(provider) do
      "ollama" -> true
      "opencode" -> true
      "openai" -> present?(System.get_env("OPENAI_API_KEY"))
      "poolside" -> present?(System.get_env("POOLSIDE_API_KEY"))
      "mistral" -> present?(System.get_env("MISTRAL_API_KEY"))
      _ -> true
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp key_env_for("poolside"), do: "POOLSIDE_API_KEY"
  defp key_env_for("mistral"), do: "MISTRAL_API_KEY"
  defp key_env_for(_), do: "OPENAI_API_KEY"

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

  defp loop(pid) do
    input = Owl.IO.input(label: "You") |> String.trim()

    cond do
      input == "/exit" ->
        Owl.IO.puts("Бувай, повертайся!")

      input == "/usage" ->
        print_usage(pid)
        loop(pid)

      input == "/context" ->
        print_context(pid)
        loop(pid)

      input == "/skills" ->
        print_skills(pid)
        loop(pid)

      input == "/protected" ->
        print_protected()
        loop(pid)

      input == "/limits" ->
        print_limits()
        loop(pid)

      input == "/rewind" ->
        print_rewind()
        loop(pid)

      input == "/sessions" ->
        print_sessions()
        loop(pid)

      String.starts_with?(input, "/save") ->
        name = input |> String.replace_prefix("/save", "") |> String.trim()
        name = if name == "", do: "default", else: name
        print_save(pid, name)
        loop(pid)

      String.starts_with?(input, "/load") ->
        name = input |> String.replace_prefix("/load", "") |> String.trim()
        name = if name == "", do: "default", else: name
        print_load(pid, name)
        loop(pid)

      String.starts_with?(input, "/provider ") ->
        arg = input |> String.replace_prefix("/provider ", "") |> String.trim()
        parts = String.split(arg, " ", trim: true)
        print_provider(pid, parts)
        loop(pid)

      input == "/provider" ->
        print_provider(pid, [])
        loop(pid)

      input == "/plan" ->
        Ella.Agent.set_mode(pid, :plan)
        loop(pid)

      input == "/build" || input == "/execute" ->
        Ella.Agent.set_mode(pid, :build)
        loop(pid)

      input == "/review" ->
        Ella.Agent.set_mode(pid, :review)
        loop(pid)

      input == "/init" ->
        print_init()
        loop(pid)

      input == "/setup" ->
        print_setup()
        loop(pid)

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

        loop(pid)

      input == "" ->
        loop(pid)

      true ->
        Ella.Agent.ask(pid, input)
        loop(pid)
    end
  end
end
