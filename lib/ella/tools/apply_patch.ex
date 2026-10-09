defmodule Ella.Tools.ApplyPatch do
  @behaviour Ella.Tool

  def name, do: "apply_patch"
  def description, do: "Replaces a code fragment in a file (Search & Replace)."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Relative path to the file"
        },
        "search" => %{
          "type" => "string",
          "description" => "Exact string or code snippet to search for"
        },
        "replace" => %{
          "type" => "string",
          "description" => "New string or code snippet to replace with"
        }
      },
      "required" => ["path", "search", "replace"]
    }
  end

  def execute(%{"path" => path, "search" => search, "replace" => replace}) do
    # Очищаємо від non-breaking spaces (\xA0), які іноді віддають LLM
    search_clean = String.replace(search, "\u00A0", " ")
    replace_clean = String.replace(replace, "\u00A0", " ")

    case File.read(path) do
      {:ok, content} ->
        content_clean = String.replace(content, "\u00A0", " ")

        if String.contains?(content_clean, search_clean) do
          updated = String.replace(content_clean, search_clean, replace_clean, global: false)
          File.write!(path, updated)
          {:ok, "Successfully patched #{path}."}
        else
          {:error, "Could not find target 'search' string in #{path}. Verify formatting."}
        end

      {:error, reason} ->
        {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  # Fallback для випадків, якщо аргументи пришли у нетиповому форматі
  def execute(args) do
    {:error, "Invalid arguments passed to apply_patch: #{inspect(args)}"}
  end
end
