defmodule Ella.Tools.Glob do
  @moduledoc """
  Пошук файлів за маскою (`lib/**/*.ex`, `test/**/*_test.exs`).

  Дозволяє моделі дізнатися, які файли існують, не відкриваючи
  директорію через шелл і не читаючи кожен файл.
  """

  @behaviour Ella.Tool

  alias Ella.{FileSystem, Sandbox}

  @default_limit 200
  @max_limit 1_000

  def name, do: "glob"

  def description do
    "Finds files matching a glob pattern, e.g. 'lib/**/*.ex'. Returns paths " <>
      "relative to the project root, sorted by modification time."
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Glob pattern, e.g. 'lib/**/*.ex' or '**/*_test.exs'"
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory to search in, relative to the project root. Omit for the root."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of paths to return."
        }
      },
      "required" => ["pattern"]
    }
  end

  def execute(%{"pattern" => pattern} = args) when is_binary(pattern) do
    limit = normalize_limit(args["limit"])

    if String.trim(pattern) == "" do
      {:error, "glob: 'pattern' must not be empty."}
    else
      search(pattern, args["path"], limit)
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to glob: #{inspect(args)}"}
  end

  defp search(pattern, path, limit) do
    with {:ok, base} <- resolve_base(path) do
      ignored = FileSystem.ignored_dirs()

      files =
        base
        |> FileSystem.walk_files(limit: @max_limit * 5)
        # Шаблон завжди збігається з повним шляхом від кореня проєкту,
        # незалежно від того, у якій піддиректорії шукаємо.
        |> Enum.filter(&Ella.Glob.match?(relative_to(&1), pattern))
        # Найсвіжіші файли найімовірніше потрібні: агент обычно
        # працює над тим, що змінювали останнім.
        |> Enum.sort_by(&mtime/1, :desc)

      dirs = matching_dirs(base, pattern, ignored)

      results = Enum.take(files, limit)

      {:ok, format(results, dirs, limit)}
    end
  end

  # Шаблон на кшталт "lib/*" має знаходити й каталоги: агент шукає
  # файли за шляхами і не знає наперед, які з них існують.
  defp matching_dirs(base, pattern, ignored) do
    collect_dirs(base, base, pattern, ignored, [], 0)
    |> Enum.reverse()
  end

  defp collect_dirs(_dir, _root, _pattern, _ignored, acc, depth) when depth > 8 do
    acc
  end

  defp collect_dirs(dir, root, pattern, ignored, acc, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.reject(&Ella.Sandbox.symlink?(Path.join(dir, &1)))
        |> Enum.reject(&FileSystem.ignored?(Path.join(dir, &1), ignored))
        |> Enum.flat_map(fn entry ->
          absolute = Path.join(dir, entry)

          rest =
            if Ella.Glob.match?(relative_to(absolute), pattern),
              do: [absolute],
              else: []

          rest ++ collect_dirs(absolute, root, pattern, ignored, acc, depth + 1)
        end)
        |> then(&(&1 ++ acc))

      {:error, _} ->
        acc
    end
  end

  defp resolve_base(nil), do: {:ok, Sandbox.root()}

  defp resolve_base(""), do: {:ok, Sandbox.root()}

  defp resolve_base(path) when is_binary(path) do
    with {:ok, absolute} <- Sandbox.resolve(path) do
      if File.dir?(absolute) do
        {:ok, absolute}
      else
        {:error, "glob: '#{path}' is not a directory."}
      end
    end
  end

  defp relative_to(absolute) do
    case Sandbox.relativize(absolute) do
      {:ok, rel} -> rel
      {:error, _} -> absolute
    end
  end

  # Файл міг зникнути між обходом і сортуванням.
  defp mtime(absolute) do
    case File.stat(absolute, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _} -> 0
    end
  end

  defp format([], [], _limit) do
    "No files matched."
  end

  defp format(results, dirs, limit) do
    dir_names = Enum.map(dirs, fn dir -> relative_to(dir) <> "/" end)
    file_names = Enum.map(results, &relative_to/1)

    listed = Enum.join(dir_names ++ file_names, "\n")

    suffix =
      if length(results) >= limit do
        "\n\n[Showing first #{limit}. Narrow the pattern for more.]"
      else
        ""
      end

    total = length(results) + length(dirs)
    "#{total} match(es):\n\n" <> listed <> suffix
  end

  defp normalize_limit(nil), do: @default_limit
  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)
  defp normalize_limit(_), do: @default_limit
end
