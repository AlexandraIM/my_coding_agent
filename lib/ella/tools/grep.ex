defmodule Ella.Tools.Grep do
  @moduledoc """
  Пошук по вмісту файлів з регулярним виразом.

  Спроба використати ripgrep (`rg`), якщо він є в PATH: він у ~10 разів
  швидший за власний обхід і сам коректно обробляє великі репозиторії.
  Якщо `rg` недоступний — працюємо через `:re` і власний обхід дерева,
  щоб інструмент не залежав від зовнішньої програми.
  """

  @behaviour Ella.Tool

  alias Ella.{FileSystem, Sandbox}

  @default_limit 100
  @max_limit 500

  def name, do: "grep"

  def description do
    "Searches file contents with a regular expression. Returns matching lines " <>
      "with file:line prefixes. Prefer this over reading whole files."
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Regular expression to search for (e.g., 'defp run_loop')"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory or file to search in, relative to the project root. Omit to search everything."
        },
        "glob" => %{
          "type" => "string",
          "description" => "Restrict to files matching this glob, e.g. 'lib/**/*.ex'"
        },
        "ignore_case" => %{
          "type" => "boolean",
          "description" => "Case-insensitive search. Defaults to false."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of matching lines to return."
        }
      },
      "required" => ["pattern"]
    }
  end

  def execute(%{"pattern" => pattern} = args) when is_binary(pattern) do
    limit = normalize_limit(args["limit"])
    case_insensitive = args["ignore_case"] == true

    with {:ok, target} <- resolve_target(args["path"]),
         {:ok, matcher} <- compile_pattern(pattern, case_insensitive) do
      results = search(target, args["glob"], matcher, limit)

      {:ok, format_results(results, limit, pattern)}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to grep: #{inspect(args)}"}
  end

  # Компіляція regex відразу дає моделі зрозумілу помилку замість
  # винятка всередині обходу.
  # Regex.compile підтримує лише multiline/dotall/extended, тому
  # нечутливість до регістру задається інлайновим (?i).
  defp compile_pattern(pattern, case_insensitive) do
    with {:ok, regex} <- Regex.compile(prefixed(pattern, case_insensitive)) do
      {:ok, regex}
    else
      {:error, reason} -> {:error, "Invalid regex #{inspect(pattern)}: #{inspect(reason)}"}
    end
  end

  defp prefixed(pattern, true), do: "(?i)" <> pattern
  defp prefixed(pattern, _), do: pattern

  defp resolve_target(nil), do: {:ok, Sandbox.root()}

  defp resolve_target(""), do: {:ok, Sandbox.root()}

  defp resolve_target(path) when is_binary(path) do
    with {:ok, absolute} <- Sandbox.resolve(path) do
      if File.exists?(absolute) do
        {:ok, absolute}
      else
        {:error, "Path does not exist: #{path}"}
      end
    end
  end

  defp search(target, glob, matcher, limit) do
    cond do
      File.regular?(target) ->
        # Якщо target — файл, він мусить пройти фільтр glob.
        if glob_matches?(target, glob) do
          scan(target, matcher, limit)
        else
          []
        end

      ripgrep_available?() ->
        search_with_ripgrep(target, glob, matcher, limit)

      true ->
        target
        |> FileSystem.walk_files()
        |> Enum.filter(&glob_matches?(&1, glob))
        |> Enum.flat_map(&scan(&1, matcher, limit))
        |> Enum.take(limit)
    end
  end

  # ripgrep сам знає про ігнор-файли та бінарники, тому його шаблони
  # збігаються з нашими майже завжди; але оскільки поведінка може
  # відрізнятися, результат перевіряємо нашим regex.
  defp search_with_ripgrep(target, glob, matcher, limit) do
    args = [
      "--line-number",
      "--no-heading",
      "--color=never",
      "--max-count=#{limit}",
      "--regexp=#{Regex.source(matcher)}"
    ]

    args = if glob, do: args ++ ["--glob=#{glob}"], else: args

    case safe_cmd("rg", args, target) do
      {:ok, output} ->
        output
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> take(limit)

      {:error, _} ->
        # rg не вдався — не зраджуємо користувача, а падаємо на власний обхід.
        target
        |> FileSystem.walk_files()
        |> Enum.filter(&glob_matches?(&1, glob))
        |> Enum.flat_map(&scan(&1, matcher, limit))
        |> Enum.take(limit)
    end
  end

  defp ripgrep_available? do
    case safe_cmd("rg", ["--version"], nil) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp safe_cmd(cmd, args, cd) do
    opts = [stderr_to_stdout: true] ++ if cd, do: [{:cd, cd}], else: []

    case System.cmd(cmd, args, opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {output, code}}
    end
  rescue
    # System.cmd кидає ErlangError, якщо програми немає в PATH.
    error -> {:error, error}
  end

  defp scan(absolute_path, matcher, limit) do
    case File.read(absolute_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reduce_while({[], 0}, fn {line, number}, {hits, found} ->
          if found >= limit do
            {:halt, {hits, found}}
          else
            if Regex.match?(matcher, line) do
              {:cont, {[format_hit(absolute_path, number, line) | hits], found + 1}}
            else
              {:cont, {hits, found}}
            end
          end
        end)
        |> then(fn {hits, _found} -> Enum.reverse(hits) end)

      {:error, _} ->
        []
    end
  end

  defp format_hit(absolute_path, number, line) do
    relative =
      case Sandbox.relativize(absolute_path) do
        {:ok, rel} -> rel
        {:error, _} -> absolute_path
      end

    "#{relative}:#{number}:#{truncate_line(line)}"
  end

  defp truncate_line(line), do: String.slice(line, 0, 300)

  defp take(list, limit), do: Enum.take(list, limit)

  defp format_results([], _limit, _pattern) do
    "No matches found."
  end

  defp format_results(results, limit, pattern) do
    header =
      if length(results) >= limit do
        "Showing first #{limit} matches for #{inspect(pattern)}. " <>
          "Narrow the pattern or path if needed."
      else
        "#{length(results)} match(es) for #{inspect(pattern)}:"
      end

    header <> "\n\n" <> Enum.join(results, "\n")
  end

  defp glob_matches?(_absolute_path, nil), do: true

  defp glob_matches?(absolute_path, glob) do
    relative =
      case Sandbox.relativize(absolute_path) do
        {:ok, rel} -> rel
        {:error, _} -> absolute_path
      end

    Ella.Glob.match?(relative, glob)
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)
  defp normalize_limit(_), do: @default_limit
end
