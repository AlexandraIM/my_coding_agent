defmodule Ella do
  def start_cli do
    Owl.IO.puts(Owl.Data.tag("=== Привіт це Ella, твій кодінг партнер! ===", :magenta))

    Owl.IO.puts(
      "Commands: /plan, /build, /usage, /context, /skills, /protected, /rewind, /mcp <executable> <args>, /exit"
    )

    {:ok, pid} = Ella.Agent.start_link(mode: :plan)
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

      input == "/rewind" ->
        print_rewind()
        loop(pid)

      input == "/plan" ->
        Ella.Agent.set_mode(pid, :plan)
        loop(pid)

      input == "/build" || input == "/execute" ->
        Ella.Agent.set_mode(pid, :build)
        loop(pid)

      String.starts_with?(input, "/mcp ") ->
        cmd_str = String.replace_prefix(input, "/mcp ", "")

        case String.split(cmd_str, " ", trim: true) do
          [exec | args] ->
            Ella.Agent.register_mcp(pid, exec, args)

          _ ->
            Owl.IO.puts("Usage: /mcp <executable> [args...]")
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
