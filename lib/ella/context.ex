defmodule Ella.Context do
  @moduledoc """
  Manages the size of the message history.

  Without this, `state.messages` grows without bound: every tool call
  adds messages, and after a few dozen steps the request exceeds the
  model's context window — the agent stops with an error.

  The scheme is simple: the system prompt and the last N messages are
  always kept. Older tool messages that no longer affect subsequent
  steps are replaced with a single short summary.
  """

  alias Ella.Llm.Usage

  # How many of the most recent messages never to compact.
  @keep_recent 12

  # Calibration "how many tokens per unit of our estimate", derived from
  # real API data: 1.0 means the estimate is exact, 1.5 means we were
  # off by half.
  @min_factor 0.5
  @max_factor 4.0
  @calibration_smoothing 0.3

  @doc """
  Whether the history exceeds the allowed size.
  """
  def over_budget?(messages, opts) do
    estimate(messages, opts) > budget(opts)
  end

  @doc """
  Calibration factor applied to the estimate.
  """
  def factor(opts), do: Keyword.get(opts, :estimate_factor, 1.0)

  @doc """
  Refines the estimate factor using real token counts from the API response.

  The "4 characters = 1 token" rule is off by tens of percent
  depending on language and model. The API returns an exact
  `prompt_tokens` for the same request — an ideal calibration point.

  The factor is smoothed: a single outlier (e.g. a request with an
  unusual prompt) should not abruptly shift all subsequent estimates.
  Values are clamped to sane bounds, otherwise one bad usage report
  could force the agent to compact an empty history.
  """
  @spec calibrate(number(), non_neg_integer() | nil, keyword()) :: number()
  def calibrate(current_factor, prompt_tokens, opts \\ [])
      when is_number(current_factor) do
    smoothing = Keyword.get(opts, :calibration_smoothing, @calibration_smoothing)
    estimated = Keyword.get(opts, :last_estimate)

    if is_integer(prompt_tokens) and prompt_tokens > 0 and
         is_number(estimated) and estimated > 0 do
      observed = prompt_tokens / estimated
      blended = current_factor * (1 - smoothing) + observed * smoothing

      clamp_factor(blended)
    else
      current_factor
    end
  end

  defp clamp_factor(value) when value < @min_factor, do: @min_factor
  defp clamp_factor(value) when value > @max_factor, do: @max_factor
  defp clamp_factor(value), do: value

  @doc """
  Approximate size of the history in tokens.

  We don't know the model's exact tokenizer, so we count characters
  and divide by 4. For the decision "compact or not" this is enough.

  With the `:estimate_factor` option the result is multiplied by the
  calibration factor — see `calibrate/3`.
  """
  def estimate(messages, opts \\ []) when is_list(messages) do
    messages
    |> Enum.map(&message_size/1)
    |> Enum.sum()
    |> scale(factor(opts))
  end

  defp scale(tokens, factor), do: round(tokens * factor)

  defp message_size(%{} = message) do
    base =
      [
        get(message, "role"),
        get(message, "name"),
        get(message, "tool_call_id")
      ]
      |> Enum.map(&size_of/1)
      |> Enum.sum()

    base + content_size(get(message, "content")) + calls_size(get(message, "tool_calls"))
  end

  defp message_size(_), do: 0

  defp content_size(nil), do: 0
  defp content_size(text) when is_binary(text), do: Usage.estimate(text)

  defp content_size(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} -> Usage.estimate(text)
      other -> size_of(inspect(other))
    end)
    |> Enum.sum()
  end

  defp content_size(other), do: size_of(inspect(other))

  defp calls_size(nil), do: 0

  defp calls_size(calls) when is_list(calls) do
    calls
    |> Enum.map(fn call ->
      fn_map = get(call, "function")
      size_of(get(fn_map, "name")) + size_of(get(fn_map, "arguments"))
    end)
    |> Enum.sum()
  end

  defp calls_size(_), do: 0

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp size_of(nil), do: 0
  defp size_of(value) when is_binary(value), do: Usage.estimate(value)
  defp size_of(value), do: Usage.estimate(inspect(value))

  @doc """
  History budget in tokens.
  """

  def budget(opts) do
    Keyword.get(opts, :context_budget, Keyword.get(opts, :max_context_tokens, 120_000))
  end

  @doc """
  Compacts the history so it fits the budget.

  Returns {:ok, messages} or {:error, reason} if compaction failed —
  for example, when even the most recent part no longer fits.
  """
  def compact(messages, opts \\ []) do
    budget = budget(opts)
    keep = Keyword.get(opts, :keep_recent, @keep_recent)

    if estimate(messages, opts) <= budget do
      {:ok, messages}
    else
      do_compact(messages, keep, budget, opts)
    end
  end

  defp do_compact(messages, keep, budget, opts) do
    {system, rest} = split_system(messages)

    if length(rest) <= keep do
      shrink_to_fit(system, rest, budget, opts)
    else
      {old, recent} = Enum.split(rest, length(rest) - keep)
      summary = summary_message(summarize(old, opts))

      candidate = system ++ [summary] ++ recent

      if estimate(candidate, opts) <= budget do
        {:ok, candidate}
      else
        # Keep the summary in any case: without it the agent would lose
        # information about what it already did.
        shrink_to_fit(system ++ [summary], recent, budget, opts)
      end
    end
  end

  # Reduces the tool-result length limit until the history fits.
  # Trimming is gradual: don't drop information until necessary.
  @floor_chars 200

  defp shrink_to_fit(system, rest, budget, opts) do
    initial = Keyword.get(opts, :max_tool_result_chars, 2_000)
    do_shrink(system, rest, budget, opts, initial)
  end

  defp do_shrink(system, rest, budget, opts, max_chars) do
    trimmed = trim_tool_content(rest, max_chars)
    candidate = system ++ trimmed

    cond do
      estimate(candidate, opts) <= budget ->
        {:ok, candidate}

      max_chars <= @floor_chars ->
        # Even with tool output maximally trimmed, we still don't fit:
        # fall back to dropping the oldest messages.
        drop_oldest(system, rest, budget, opts, max_chars)

      true ->
        next = max(div(max_chars, 2), @floor_chars)
        do_shrink(system, rest, budget, opts, next)
    end
  end

  # Drop the oldest messages until we fit. Keep at least one message:
  # without it the next request would have no context at all.
  defp drop_oldest(system, rest, budget, opts, max_chars) do
    trimmed = trim_tool_content(rest, max_chars)
    total = length(trimmed)

    # keep ∈ 1..total: how many of the most recent messages to keep.
    # Zero is not allowed: an empty history is worse than an explicit error.
    Enum.reduce_while((total - 1)..1//-1, nil, fn keep, _acc ->
      recent = Enum.take(trimmed, -keep)
      candidate = system ++ recent

      if estimate(candidate, opts) <= budget do
        {:halt, {:ok, candidate}}
      else
        {:cont, nil}
      end
    end) || {:error, :too_large}
  end

  defp split_system(messages) do
    Enum.split_with(messages, fn m -> get(m, "role") == "system" end)
  end

  # The summary is built without calling the LLM: we just enumerate what
  # was done. This is cheap, predictable, and spends no tokens on an
  # extra request.
  defp summarize(old, opts) do
    max_entries = Keyword.get(opts, :summary_max_entries, 40)
    max_chars = Keyword.get(opts, :summary_max_chars, 1_500)

    lines =
      old
      |> Enum.flat_map(&describe/1)
      |> Enum.uniq()
      |> Enum.take(max_entries)

    text =
      case lines do
        [] -> "Earlier conversation: no tool activity recorded."
        list -> Enum.join(list, "\n")
      end

    # The summary becomes a system message itself; trim_tool_content does
    # not trim it, so we limit it here.
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n[summary truncated]"
    else
      text
    end
  end

  defp describe(message) do
    case get(message, "role") do
      "user" ->
        case get(message, "content") do
          content when is_binary(content) ->
            ["user asked: " <> first_line(content)]

          _ ->
            []
        end

      "tool" ->
        name = get(message, "tool_call_id") || "?"
        content = get(message, "content") || ""
        ["tool #{name}: #{truncate(normalize(content), 120)}"]

      _ ->
        []
    end
  end

  defp first_line(text) do
    text
    |> String.split("\n")
    |> List.first()
    |> case do
      nil -> ""
      line -> truncate(normalize(line), 200)
    end
  end

  defp normalize(text) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp normalize(_), do: ""

  defp truncate(text, length), do: String.slice(text, 0, length)

  defp summary_message(text) do
    %{
      "role" => "system",
      "content" => "Summary of earlier conversation (older messages were compacted):\n" <> text
    }
  end

  # Trim long tool results: they take the most space and influence
  # subsequent steps the least.
  defp trim_tool_content(messages, max_chars) do
    Enum.map(messages, fn message ->
      case get(message, "role") do
        "tool" ->
          content = get(message, "content")

          if is_binary(content) and String.length(content) > max_chars do
            Map.put(message, "content", String.slice(content, 0, max_chars) <> "\n[truncated]")
          else
            message
          end

        _ ->
          message
      end
    end)
  end
end
