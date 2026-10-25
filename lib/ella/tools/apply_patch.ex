defmodule Ella.Tools.ApplyPatch do
  @behaviour Ella.Tool

  @moduledoc """
  Replaces a code fragment in a file (Search & Replace).

  Підтримує три стратегії збігання, застосовується послідовно:

  1. Точний збіг (після нормалізації non-breaking пробілів);
  2. Збіг з нормалізацією whitespace (trim trailing, collapse blank lines);
  3. Fuzzy збіг з відносними відступами (ігнорує leading whitespace).

  Додатково підтримує формат блоків `<<<< SEARCH / ==== / >>>>` у параметрі
  `search` для множинних патчів у одному виклику.
  """

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
          "description" =>
            "Exact string or code snippet to search for. Can also be a SEARCH/REPLACE block format."
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
    with :ok <- Ella.WriteGuard.check(path, name()) do
      do_patch(path, search, replace)
    end
  end

  # Fallback для випадків, якщо аргументи пришли у нетиповому форматі
  def execute(args) do
    {:error, "Invalid arguments passed to apply_patch: #{inspect(args)}"}
  end

  # --- Normalізація ---

  # Очищаємо від non-breaking spaces (\xA0), які іноді віддають LLM
  defp normalize_nbsp(text), do: String.replace(text, "\u00A0", " ")

  # Trims trailing whitespace per line and collapses consecutive blank lines.
  defp normalize_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  # Returns the leading whitespace prefix of a line.
  defp leading_whitespace(line) do
    trimmed = String.trim_leading(line)
    String.slice(line, 0, byte_size(line) - byte_size(trimmed))
  end

  # --- Main dispatch ---

  defp do_patch(path, search, replace) do
    search_clean = normalize_nbsp(search)
    replace_clean = normalize_nbsp(replace)

    with {:ok, content} <- Ella.Sandbox.read(path) do
      content_clean = normalize_nbsp(content)

      if has_search_replace_block?(search_clean) do
        apply_blocks(path, content_clean, parse_blocks(search_clean))
      else
        apply_single(path, content_clean, search_clean, replace_clean)
      end
    end
  end

  # --- Single search/replace ---

  defp apply_single(path, content, search, replace) do
    case count_occurrences(content, search) do
      0 ->
        case fuzzy_replace(content, search, replace) do
          {:ok, updated} ->
            write_patch(path, updated)

          :error ->
            {:error, "Could not find target 'search' string in #{path}. Verify formatting."}
        end

      1 ->
        updated = String.replace(content, search, replace, global: false)
        write_patch(path, updated)

      n when n > 1 ->
        {:error,
         "Ambiguous patch: the 'search' string occurs #{n} times in #{path}. " <>
           "Include more surrounding context to make it unique."}
    end
  end

  # --- Block format: <<<< SEARCH / ==== / >>>> ---

  @block_start_regex ~r/<<<<+\s*SEARCH\n/s

  defp has_search_replace_block?(text) do
    Regex.match?(@block_start_regex, text)
  end

  # Parses <<<< SEARCH ... ==== ... >>>> blocks into [{old, new}] pairs.
  defp parse_blocks(text) do
    ~r/<<<<+\s*SEARCH\n(.*?)\n=+\n(.*?)\n>>>>+/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [old, new] -> {String.trim_trailing(old), String.trim_trailing(new)} end)
  end

  defp apply_blocks(_path, _content, []) do
    {:error, "No SEARCH/REPLACE blocks found in the 'search' parameter."}
  end

  defp apply_blocks(path, content, blocks) do
    case apply_blocks_fold(content, blocks) do
      {:ok, updated} -> write_patch(path, updated)
      :error -> {:error, "Could not find one of the search blocks in #{path}. Verify formatting."}
    end
  end

  defp apply_blocks_fold(content, blocks) do
    Enum.reduce_while(blocks, {:ok, content}, fn {old, new}, {:ok, acc} ->
      old_clean = normalize_nbsp(old)
      new_clean = normalize_nbsp(new)

      case count_occurrences(acc, old_clean) do
        1 ->
          {:cont, {:ok, String.replace(acc, old_clean, new_clean, global: false)}}

        0 ->
          case fuzzy_replace(acc, old_clean, new_clean) do
            {:ok, updated} -> {:cont, {:ok, updated}}
            :error -> {:halt, :error}
          end

        _ ->
          {:halt, :error}
      end
    end)
  end

  # --- Fuzzy matching strategies ---

  defp fuzzy_replace(content, search, replace) do
    # Strategy 1: Normalize whitespace (trim trailing per line, collapse blank lines)
    case strategy_whitespace(content, search, replace) do
      {:ok, result} ->
        {:ok, result}

      :error ->
        # Strategy 2: Strip leading indentation per line (relative indentation)
        strategy_relative_indent(content, search, replace)
    end
  end

  defp strategy_whitespace(content, search, replace) do
    content_norm = normalize_whitespace(content)
    search_norm = normalize_whitespace(search)

    if count_occurrences(content_norm, search_norm) == 1 do
      replace_norm = normalize_whitespace(replace)
      {:ok, String.replace(content_norm, search_norm, replace_norm, global: false)}
    else
      :error
    end
  end

  # Matches lines ignoring leading whitespace, then replaces the matched
  # span in the original content while preserving indentation.
  # E.g., search "def foo" matches "  def foo" and the replacement
  # inherits the original 2-space indent plus any relative indent from replace.
  defp strategy_relative_indent(content, search, replace) do
    content_lines = String.split(content, "\n")

    # Trim blank lines from start/end and strip leading whitespace for comparison
    search_lines =
      search
      |> String.trim()
      |> String.split("\n")

    content_stripped = Enum.map(content_lines, &String.trim_leading/1)
    search_stripped = Enum.map(search_lines, &String.trim_leading/1)

    case find_line_subsequence(content_stripped, search_stripped) do
      [{start_idx, end_idx}] ->
        {before, rest} = Enum.split(content_lines, start_idx)
        {_, after_lines} = Enum.split(rest, end_idx - start_idx + 1)

        # Original indentation where the match was found.
        orig_indent = leading_whitespace(Enum.at(content_lines, start_idx))
        # Indentation of the first search line (usually "").
        search_indent = leading_whitespace(hd(search_lines))
        search_len = String.length(search_indent)

        adjusted =
          Enum.map(String.split(replace, "\n"), fn line ->
            trimmed = String.trim_leading(line)
            line_indent = leading_whitespace(line)

            if trimmed == "" do
              ""
            else
              # Compute the indent relative to the search block's first line,
              # then apply the original indentation as a base.
              rel_indent =
                if String.starts_with?(line_indent, search_indent) do
                  String.slice(line_indent, search_len, String.length(line_indent))
                else
                  line_indent
                end

              orig_indent <> rel_indent <> trimmed
            end
          end)

        {:ok, Enum.join(before ++ adjusted ++ after_lines, "\n")}

      _ ->
        :error
    end
  end

  # Finds 0-based (start, end) index pairs where `needle` appears as a
  # contiguous subsequence in `haystack`.
  defp find_line_subsequence(haystack, needle) do
    needle_len = length(needle)
    total = length(haystack)

    if needle_len == 0 or needle_len > total do
      []
    else
      haystack
      |> Enum.chunk_every(needle_len, 1, :discard)
      |> Enum.with_index()
      |> Enum.filter(fn {chunk, _} -> chunk == needle end)
      |> Enum.map(fn {_, idx} -> {idx, idx + needle_len - 1} end)
    end
  end

  # --- Utilities ---

  defp write_patch(path, content) do
    case Ella.Sandbox.write(path, content) do
      :ok -> {:ok, "Successfully patched #{path}."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle, parts: :infinity)
    |> length()
    |> Kernel.-(1)
  end
end
