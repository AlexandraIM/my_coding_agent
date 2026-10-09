defmodule Ella.Stream do
  @moduledoc """
  Накопичувач SSE-подій для стрімінгових відповідей LLM.

  Провайдери надсилають Server-Sent Events пошматочками: один TCP-пакет
  може містити пів-події або навпаки три події разом. Парсер тримає
  буфер і віддає повні події, ігноруючи коментарі (`: keep-alive`) та
  ігноруючи події без `data:`.
  """

  @done "[DONE]"

  @type event :: %{data: String.t(), event: String.t() | nil, id: String.t() | nil}

  @doc """
  Новий порожній буфер.
  """
  def new, do: %{}

  @doc """
  Чи даний фрагмент містить завершення потоку.
  """
  def done?(data), do: String.trim(data) == @done

  @doc """
  Обробляє шматок тексту, повертаючи {:ok, events, new_state}.

  Порожній список events означає, що подія була неповною і ми
  зберегли її в буфері для наступного виклику.
  """
  @spec feed(String.t(), map()) :: {:ok, [event()], map()}
  def feed(chunk, state) when is_binary(chunk) do
    state = Map.put(state, :buffer, Map.get(state, :buffer, "") <> chunk)

    {events, rest} = take_complete(state.buffer)

    state = Map.put(state, :buffer, rest)

    events =
      events
      |> Enum.filter(&(&1.data != ""))
      |> Enum.reject(&(&1.data == @done))
      |> Enum.map(&normalise/1)

    {:ok, events, state}
  end

  # SSE розділяє події порожнім рядком (CRLF теж допустимий).
  # Один шматок може містити кілька подій, тому розбираємо поки
  # залишаються повні сегменти, а не лише перший.
  defp take_complete(buffer), do: take_complete(buffer, [])

  defp take_complete(buffer, acc) do
    case String.split(buffer, ~r/\r?\n\r?\n/, parts: 2) do
      [_only_partial] ->
        {acc, buffer}

      [complete, rest] ->
        take_complete(rest, acc ++ parse_events(complete))
    end
  end

  defp parse_events(block) do
    block
    |> String.split(~r/\r?\n/)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_line(line) do
        :skip -> acc
        {key, value} -> Map.put(acc, key, value)
      end
    end)
    |> case do
      %{data: _data} = acc ->
        [acc]

      _ ->
        # Подія без data: (наприклад, лише event: повідомлення) —
        # переносимо на наступний блок.
        []
    end
  end

  defp parse_line(""), do: :skip
  defp parse_line(":" <> _comment), do: :skip

  defp parse_line(line) do
    case String.split(line, ":", parts: 2) do
      [field, value] -> {String.to_atom(String.trim(field)), trim_value(value)}
      [_only_field] -> {String.to_atom(String.trim(line)), ""}
    end
  end

  defp trim_value(value) do
    value
    |> String.trim_leading()
    |> String.trim_trailing()
  end

  defp normalise(event) do
    %{
      data: Map.get(event, :data, ""),
      event: Map.get(event, :event),
      id: Map.get(event, :id)
    }
  end

  @doc """
  Акумулятор для `into:` у Req.

  Req передає станом пару `{req, resp}`, тому наш буфер тримає
  окремо: кожен виклик приносить свій буфер, а наприкінці ми
  повертаємо стан Req недоторканим.

  `on_event` викликається для кожної розпізнаної SSE-події. Якщо
  вона поверне `{:halt, reason}`, акумулятор поверне `{:halt, ...}`
  у Req і з'єднання закриється — сервер перестане надсилати чанки,
  а не просто припиниться їхня обробка.

  Повертає :halt, якщо `on_event` повернула {:halt, reason}.
  """
  def accumulator(on_event) do
    fn
      {:data, data}, acc ->
        {:ok, events, new_state} = feed(data, %{buffer: read_sse_buffer(acc)})

        case reduce_events(events, on_event, acc) do
          {:halt, _reason} -> {:halt, put_sse_buffer(acc, new_state.buffer)}
          {:cont, next_acc} -> {:cont, put_sse_buffer(next_acc, new_state.buffer)}
        end

      {:done, acc}, _resp ->
        {:done, acc}
    end
  end

  defp reduce_events([], _on_event, acc), do: {:cont, acc}

  defp reduce_events([event | rest], on_event, acc) do
    case on_event.(event) do
      {:halt, reason} -> {:halt, reason}
      _ -> reduce_events(rest, on_event, acc)
    end
  end

  defp read_sse_buffer(acc) when is_map(acc) and not is_struct(acc),
    do: Map.get(acc, :sse_buffer, "")

  defp read_sse_buffer({req, _resp}) when is_struct(req),
    do: Map.get(req.private, :sse_buffer, "")

  defp read_sse_buffer(_acc), do: ""

  defp put_sse_buffer(acc, buffer) when is_map(acc) and not is_struct(acc) do
    Map.put(acc, :sse_buffer, buffer)
  end

  defp put_sse_buffer({req, resp}, buffer) when is_struct(req) do
    {Req.Request.put_private(req, :sse_buffer, buffer), resp}
  end

  defp put_sse_buffer(acc, _buffer), do: acc

  @doc """
  Розбирає JSON із data-поля події.
  """
  def decode_data(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end
end
