defmodule Ella.Tools.ReadFile do
  @moduledoc """
  Читання файлу з можливістю взяти лише потрібний фрагмент.

  Читати файл цілком — погана ідея для великих файлів: `mix.lock`,
  згенеровані артефакти чи CSV можуть умістити десятки тисяч рядків
  і вичерпати контекстне вікно за один виклик.
  """

  @behaviour Ella.Tool

  @default_limit 2_000
  @max_limit 10_000

  def name, do: "read_file"

  def description do
    "Reads a file. Use offset/limit for large files to read a specific range of lines " <>
      "(1-indexed lines, like sed)."
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file, relative to the project root"
        },
        "offset" => %{
          "type" => "integer",
          "description" =>
            "1-indexed line number to start reading from. Omit to start at the beginning."
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read. Omit for the default."
        }
      },
      "required" => ["path"]
    }
  end

  def execute(%{"path" => path} = args) when is_binary(path) do
    with {:ok, offset} <- positive_integer(args["offset"], 1, "offset"),
         {:ok, limit} <- positive_integer(args["limit"], @default_limit, "limit") do
      limit = min(limit, @max_limit)

      with {:ok, absolute} <- Ella.Sandbox.resolve(path),
           {:ok, content} <- File.read(absolute) do
        {:ok, format_slice(content, offset, limit, path)}
      else
        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "Failed to read #{path}: #{inspect(reason)}"}
      end
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to read_file: #{inspect(args)}"}
  end

  defp format_slice(content, offset, limit, path) do
    lines = String.split(content, "\n")
    total = length(lines)
    start = offset - 1

    cond do
      start >= total ->
        "File #{path} has #{total} lines. Offset #{offset} is past the end."

      start < 0 ->
        "Offset must be >= 1, got #{offset}."

      true ->
        taken = Enum.slice(lines, start, limit)
        rest = total - start - length(taken)

        body =
          taken
          |> Enum.with_index(start + 1)
          |> Enum.map_join("\n", fn {line, number} -> "#{number}\t#{line}" end)

        header = "Showing lines #{start + 1}-#{start + length(taken)} of #{total} in #{path}"

        footer =
          if rest > 0,
            do: "\n\n[#{rest} more lines. Continue with offset=#{start + length(taken) + 1}.]",
            else: ""

        header <> "\n\n" <> body <> footer
    end
  end

  defp positive_integer(nil, default, _name), do: {:ok, default}

  defp positive_integer(value, _default, _name) when is_integer(value) and value >= 1 do
    {:ok, value}
  end

  defp positive_integer(value, _default, name) do
    {:error, "read_file: '#{name}' must be a positive integer, got #{inspect(value)}"}
  end
end
