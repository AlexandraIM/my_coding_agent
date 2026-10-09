defmodule Ella.Tools.ListDir do
  @moduledoc """
  Вміст директорії у вигляді дерева з обмеженою глибиною.

  Це перший виклик, який робить агент перед читанням файлів: він
  показує структуру проєкту одним запитом замість десятків `ls`.
  """

  @behaviour Ella.Tool

  alias Ella.{FileSystem, Sandbox}

  @default_depth 2
  @max_depth 6
  @max_entries 300

  def name, do: "list_dir"

  def description do
    "Lists a directory as a tree with file sizes. Use this first to understand " <>
      "project structure before reading files. Increase depth to descend further."
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Directory to list, relative to the project root. Omit for the root."
        },
        "depth" => %{
          "type" => "integer",
          "description" => "How many levels to descend. Defaults to 2."
        }
      }
    }
  end

  def execute(args) when is_map(args) do
    depth =
      case args["depth"] do
        value when is_integer(value) and value > 0 -> min(value, @max_depth)
        _ -> @default_depth
      end

    case resolve_dir(args["path"] || ".") do
      {:ok, absolute} -> {:ok, render(absolute, depth)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to list_dir: #{inspect(args)}"}
  end

  defp resolve_dir(path) when is_binary(path) do
    with {:ok, absolute} <- Sandbox.resolve(path) do
      cond do
        not Sandbox.exists?(absolute) ->
          {:error, "list_dir: path does not exist: #{path}"}

        not File.dir?(absolute) ->
          {:error, "list_dir: '#{path}' is a file, not a directory. Use read_file instead."}

        true ->
          {:ok, absolute}
      end
    end
  end

  defp resolve_dir(path) do
    {:error, "list_dir: 'path' must be a string, got #{inspect(path)}"}
  end

  defp render(absolute, depth) do
    ignored = FileSystem.ignored_dirs()
    lines = render_dir(absolute, depth, ignored, 1, @max_entries)

    header =
      case Sandbox.relativize(absolute) do
        {:ok, "."} -> "Project root:"
        {:ok, rel} -> "#{rel}/:"
        {:error, _} -> "Contents:"
      end

    header <> "\n" <> Enum.join(lines, "\n")
  end

  # level — поточний рівень вкладеності, budget — скільки рядків
  # залишилося до @max_entries.
  defp render_dir(dir, depth, ignored, level, budget) do
    if depth < 0 or budget <= 0 do
      []
    else
      case File.ls(dir) do
        {:ok, entries} ->
          # Директорії спершу: вони визначають структуру краще,
          # ніж перелік файлів на тому ж рівні.
          {dirs, files} = Enum.split_with(entries, &is_dir?(Path.join(dir, &1)))

          pad = String.duplicate("  ", level - 1)

          dir_lines =
            dirs
            |> Enum.reject(&FileSystem.ignored?(Path.join(dir, &1), ignored))
            |> Enum.map(&(pad <> &1 <> "/"))

          file_lines = Enum.map(files, &(pad <> file_line(dir, &1)))

          lines = dir_lines ++ file_lines
          {shown, _dropped} = Enum.split(lines, budget)
          remaining = budget - length(shown)

          nested =
            dirs
            |> Enum.reject(&FileSystem.ignored?(Path.join(dir, &1), ignored))
            |> Enum.flat_map(fn entry ->
              render_dir(Path.join(dir, entry), depth - 1, ignored, level + 1, remaining)
            end)

          shown ++ nested

        {:error, _} ->
          []
      end
    end
  end

  defp is_dir?(absolute) do
    File.dir?(absolute) and not Sandbox.symlink?(absolute)
  end

  defp file_line(dir, entry) do
    size =
      case File.stat(Path.join(dir, entry)) do
        {:ok, %File.Stat{size: size}} -> humanize(size)
        {:error, _} -> "?"
      end

    "#{entry} (#{size})"
  end

  defp humanize(bytes) when bytes < 1_000, do: "#{bytes}B"

  defp humanize(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)}K"

  defp humanize(bytes) when bytes < 1_000_000_000, do: "#{Float.round(bytes / 1_000_000, 1)}M"

  defp humanize(bytes), do: "#{Float.round(bytes / 1_000_000_000, 1)}G"
end
