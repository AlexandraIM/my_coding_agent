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
    Ella.Sandbox.read(path)
  end

  def execute(args) do
    {:error, "Invalid arguments passed to read_file: #{inspect(args)}"}
  end
end
