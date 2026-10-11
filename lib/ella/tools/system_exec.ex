defmodule Ella.Tools.SystemExec do
  @behaviour Ella.Tool

  @default_timeout_ms 120_000
  @max_output_chars 30_000

  # Команди, які руйнують стан поза межами робочого проєкту або незворотні.
  # Агент сам їх не запускає — повертає помилку з поясненням.
  @denied_commands ~w(
    rm shutdown halt poweroff reboot mkfs dd
    sudo su doas launchctl systemctl killall
  )

  # Інтерпретори, які можуть обійти чорний список через -c / -e / -p.
  # При їх використанні перевіряємо аргументи на згадки заборонених команд.
  @denied_interpreters ~w(
    bash sh dash zsh ksh
    python python3 perl ruby node php
  )

  # Підкоманди, які ламають git-стан без можливості відкотитись.
  @denied_git_subcommands ~w(reset clean filter-branch push force)

  def name, do: "system_exec"

  def description,
    do:
      "Executes a terminal command through a shell (e.g., 'mix test', 'git status', " <>
        "'rg foo lib/ | head -20'). Supports pipes (&&, |, >) and runs in the project root."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "The full shell command to execute (e.g., 'mix test')"
        }
      },
      "required" => ["command"]
    }
  end

  def execute(%{"command" => full_command}) when is_binary(full_command) do
    case check_allowed(full_command) do
      :ok ->
        run(full_command)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to system_exec: #{inspect(args)}"}
  end

  defp run(command) do
    timeout = Application.get_env(:ella, :exec_timeout_ms, @default_timeout_ms)
    opts = [stderr_to_stdout: true, cd: Ella.Sandbox.root()]

    task = Task.async(fn -> System.cmd(shell(), ["-c", command], opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, format_output("Success", 0, output)}

      {:ok, {output, exit_code}} ->
        {:error, format_output("Command failed", exit_code, output)}

      nil ->
        {:error,
         "Command timed out after #{timeout}ms and was killed. " <>
           "Consider running a narrower command."}
    end
  end

  defp shell do
    case :os.type() do
      {:win32, _} -> System.get_env("COMSPEC") || "cmd.exe"
      _ -> "/bin/sh"
    end
  end

  defp format_output(label, exit_code, output) do
    truncated = truncate(output)

    "#{label} (exit code #{exit_code}):\n#{truncated}"
  end

  defp truncate(output) do
    if String.length(output) > @max_output_chars do
      shown = String.slice(output, 0, @max_output_chars)

      shown <>
        "\n\n... [truncated #{String.length(output) - @max_output_chars} characters. " <>
        "The full output was too large for the context window.]"
    else
      output
    end
  end

  # Спочатку перевіряємо весь рядок команди проти конфіг-паттернів,
  # потім — кожен сегмент після розбору ланцюжка команд.
  defp check_allowed(command) do
    case check_disallowed_patterns(command) do
      {:error, _} = error ->
        error

      :ok ->
        segments = split_segments(command)

        result =
          Enum.reduce_while(segments, :ok, fn segment, _acc ->
            case first_token(segment) do
              nil ->
                {:cont, :ok}

              cmd ->
                case check_command(cmd, segment) do
                  :ok -> {:cont, :ok}
                  {:error, _} = error -> {:halt, error}
                end
            end
          end)

        # Другий прохід: якщо жоден сегмент не пройшов перевірку, але
        # серед сегментів є інтерпретор (bash, python, ...), додатково
        # перевіряємо ВСІй рядок команди на заборонені токени. Це ловить
        # випадки, де `;` всередині рядка розбиває команду на сегменти
        # (наприклад, `python3 -c 'import os; os.system("rm")'`).
        case result do
          :ok -> check_interpreter_bypass(command, segments)
          {:error, _} = error -> error
        end
    end
  end

  # Колад інтерпретор використовується в будь-якому сегменті, перевіряємо
  # повну команду на наявність заборонених команд.
  defp check_interpreter_bypass(command, segments) do
    has_interpreter =
      Enum.any?(segments, fn seg ->
        case first_token(seg) do
          nil -> false
          cmd -> Path.basename(cmd) in @denied_interpreters
        end
      end)

    if has_interpreter do
      Enum.find(@denied_commands, fn denied ->
        Regex.match?(~r/\b#{Regex.escape(denied)}\b/, command)
      end)
      |> case do
        nil -> :ok
        found -> {:error, "Interpreter invocation with denied command '#{found}' detected. Ask the user to run it manually."}
      end
    else
      :ok
    end
  end

  # Перевіряємо перший токен кожного сегмента ланцюга, щоб `ls && rm -rf`
  # не пройшов повз перевірку тільки першої команди.
  defp split_segments(command) do
    command
    |> String.split(~r/[;&|]+/)
    |> Enum.map(&String.trim/1)
  end

  defp first_token(segment) do
    segment |> String.split(~r/\s+/, trim: true) |> List.first()
  end

  defp check_command(cmd, segment) do
    base = Path.basename(cmd)

    cond do
      base in @denied_commands ->
        {:error,
         "Command '#{cmd}' is blocked by the agent's safety policy. " <>
           "Ask the user to run it manually."}

      base in @denied_interpreters ->
        check_interpreter(cmd, segment)

      base == "git" and destructive_git?(segment) ->
        {:error,
         "Destructive git command blocked: '#{segment}'. " <>
           "Use 'git status'/'git diff' to inspect state, and let the user handle resets."}

      true ->
        check_disallowed_patterns(segment)
    end
  end

  # Перевіряємо, чі містять аргументи інтерпретора заборонені команди.
  # Це блокує обхід типу `bash -c "rm -rf /"` чи `python -c "import os; os.system('rm')"`.
  defp check_interpreter(cmd, segment) do
    tokens = segment |> String.split(~r/\s+/, trim: true)
    args = Enum.drop(tokens, 1) |> Enum.join(" ")

    found =
      Enum.find(@denied_commands, fn denied ->
        Regex.match?(~r/\b#{Regex.escape(denied)}\b/, args)
      end)

    if found do
      {:error,
       "Interpreter '#{cmd}' with denied command '#{found}' detected in arguments. " <>
         "Ask the user to run it manually."}
    else
      check_disallowed_patterns(segment)
    end
  end

  # Перевіряє текст проти regex-паттернів із конфігу (`.ella/config.json`).
  # Повертає {:error, reason} або :ok.
  defp check_disallowed_patterns(text) do
    patterns = Ella.Config.disallowed_patterns()

    Enum.find_value(patterns, :ok, fn pattern ->
      case Regex.compile(pattern) do
        {:ok, regex} ->
          if Regex.match?(regex, text) do
            {:error, "Command matches disallowed pattern: #{pattern}"}
          else
            nil
          end

        {:error, _} ->
          nil
      end
    end)
  end

  defp destructive_git?(segment) do
    segment
    |> String.split(~r/\s+/)
    |> Enum.map(&Path.basename/1)
    |> Enum.any?(&(&1 in @denied_git_subcommands or String.starts_with?(&1, "--hard")))
  end
end
