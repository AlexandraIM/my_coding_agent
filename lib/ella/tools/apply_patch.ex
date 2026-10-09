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

    with {:ok, content} <- Ella.Sandbox.read(path) do
      content_clean = String.replace(content, "\u00A0", " ")

      occurrences = count_occurrences(content_clean, search_clean)

      case occurrences do
        0 ->
          {:error, "Could not find target 'search' string in #{path}. Verify formatting."}

        1 ->
          updated = String.replace(content_clean, search_clean, replace_clean, global: false)

          case Ella.Sandbox.write(path, updated) do
            :ok -> {:ok, "Successfully patched #{path}."}
            {:error, reason} -> {:error, reason}
          end

        _ ->
          {:error,
           "Ambiguous patch: the 'search' string occurs #{occurrences} times in #{path}. " <>
             "Include more surrounding context to make it unique."}
      end
    end
  end

  # Fallback для випадків, якщо аргументи пришли у нетиповому форматі
  def execute(args) do
    {:error, "Invalid arguments passed to apply_patch: #{inspect(args)}"}
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle, parts: :infinity)
    |> length()
    |> Kernel.-(1)
  end
end
