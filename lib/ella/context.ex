defmodule Ella.Context do
  @moduledoc """
  Керування розміром історії повідомлень.

  Без цього `state.messages` ростиме безмежно: кожен виклик інструмента
  додає повідомлення, і через кілька десятків кроків запит перевищить
  контекстне вікно моделі — агент зупиниться з помилкою.

  Схема проста: системний промпт і останні N повідомлень завжди
  зберігаються. Старі tool-повідомлення, які вже не впливають на
  наступні кроки, замінюються одним коротким підсумком.
  """

  alias Ella.Llm.Usage

  # Скільки останніх повідомлень не стискати нізащо.
  @keep_recent 12

  @doc """
  Чи перевищує історія допустимий розмір.
  """
  def over_budget?(messages, opts) do
    estimate(messages) > budget(opts)
  end

  @doc """
  Орієнтовний розмір історії в токенах.

  Ми не знаємо точний токенайзер моделі, тому рахуємо символи й
  ділимо на 4. Для рішення «стискати чи ні» цього достатньо.
  """
  def estimate(messages) when is_list(messages) do
    messages
    |> Enum.map(&message_size/1)
    |> Enum.sum()
  end

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
  Бюджет історії в токенах.
  """
  def budget(opts) do
    Keyword.get(opts, :context_budget, Keyword.get(opts, :max_context_tokens, 120_000))
  end

  @doc """
  Стискає історію, щоб вона вмістилась у бюджет.

  Повертає {:ok, messages} або {:error, reason}, якщо скоротити не
  вдалося — наприклад, коли сама остання частина вже не вміщається.
  """
  def compact(messages, opts \\ []) do
    budget = budget(opts)
    keep = Keyword.get(opts, :keep_recent, @keep_recent)

    if estimate(messages) <= budget do
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

      if estimate(candidate) <= budget do
        {:ok, candidate}
      else
        # Підсумок зберігаємо в будь-якому разі: без нього агент
        # втратить інформацію про те, що вже робив.
        shrink_to_fit(system, [summary | recent], budget, opts)
      end
    end
  end

  # Зменшує ліміт на довжину tool-результату, поки історія не
  # вміститься. Обрізання поступове: не витрачаємо інформацію, доки
  # це не потрібно.
  @floor_chars 200

  defp shrink_to_fit(system, rest, budget, opts) do
    initial = Keyword.get(opts, :max_tool_result_chars, 2_000)
    do_shrink(system, rest, budget, opts, initial)
  end

  defp do_shrink(system, rest, budget, opts, max_chars) do
    trimmed = trim_tool_content(rest, max_chars)
    candidate = system ++ trimmed

    cond do
      estimate(candidate) <= budget ->
        {:ok, candidate}

      max_chars <= @floor_chars ->
        # Навіть максимально стиснувши tool-вивід, не вміщаємось:
        # переходимо до відкидання найстаріших повідомлень.
        drop_oldest(system, rest, budget, opts, max_chars)

      true ->
        next = max(div(max_chars, 2), @floor_chars)
        do_shrink(system, rest, budget, opts, next)
    end
  end

  # Відкидаємо найстаріші повідомлення, доки не вмістимось. Хоча б
  # одне повідомлення зберігаємо: без нього наступний запит не матиме
  # жодного контексту.
  defp drop_oldest(system, rest, budget, _opts, max_chars) do
    trimmed = trim_tool_content(rest, max_chars)
    total = length(trimmed)

    # keep ∈ 1..total: скільки найсвіжіших повідомлень лишаємо.
    # Нуль не допускаємо: порожня історія гірша за явну помилку.
    Enum.reduce_while((total - 1)..1//-1, nil, fn keep, _acc ->
      candidate = system ++ Enum.take(trimmed, keep)

      if estimate(candidate) <= budget do
        {:halt, {:ok, candidate}}
      else
        {:cont, nil}
      end
    end) || {:error, :too_large}
  end

  defp split_system(messages) do
    Enum.split_with(messages, fn m -> get(m, "role") == "system" end)
  end

  # Підсумок будується без виклику LLM: перелічуємо, що було зроблено.
  # Це дешево, передбачувано і не витрачає токени на ще один запит.
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

    # Підсумок сам стає system-повідомленням, його не обрізає
    # trim_tool_content, тому обмежуємо його тут.
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

  # Обрізає довгі tool-результати: вони займають найбільше місця
  # і найменше впливають на наступні кроки.
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
