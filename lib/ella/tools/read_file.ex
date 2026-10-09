defmodule Ella.Tools.ReadFile do
  @behaviour Ella.Tool

  def name, do: "read_file"
  def description, do: "Reads the entire content of a file at the given path."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Relative path to the file"
        }
      },
      "required" => ["path"]
    }
  end

  def execute(%{"path" => path}) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end
end
