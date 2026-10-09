defmodule Ella.Tools.WriteFile do
  @behaviour Ella.Tool

  def name, do: "write_file"
  def description, do: "Creates or overwrites a file at the specified path with new content."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Relative path to the file"
        },
        "content" => %{
          "type" => "string",
          "description" => "Full text content to write into the file"
        }
      },
      "required" => ["path", "content"]
    }
  end

  def execute(%{"path" => path, "content" => content}) do
    with :ok <- Ella.WriteGuard.check(path, name()) do
      clean_content = String.replace(content, " ", " ")

      case Ella.Sandbox.write(path, clean_content) do
        :ok ->
          {:ok, "Successfully wrote content to #{path}."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Fallback застереження для нетипових аргументів
  def execute(args) do
    {:error, "Invalid arguments passed to write_file: #{inspect(args)}"}
  end
end
