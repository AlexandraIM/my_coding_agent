defmodule Ella.Llm.RetryAfter do
  @moduledoc """
  Розбір заголовка `Retry-After`.

  Сервер має право відповісти двома способами: кількістю секунд
  (`Retry-After: 30`) або HTTP-датою (`Retry-After: Wed, 21 Oct 2015
  07:28:00 GMT`). Другий варіант ігнорувати не можна — тоді клієнт
  повторить запит надто рано й знову отримає 429.

  Значення, яке розібрати не вдалося, дає nil: краще повторити за
  власним backoff, ніж не повторити взагалі.
  """

  @max_retry_after_ms 300_000

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc """
  Перетворює значення заголовка на мілісекунди очікування.

  Повертає nil, якщо значення відсутнє або не розпізнане.
  """
  @spec parse(String.t() | integer() | term()) :: integer() | nil
  def parse(value) when is_integer(value) and value >= 0, do: clamp(value * 1_000)

  # Req віддає значення заголовка списком: %{"retry-after" => ["3"]}.
  def parse([value | _rest]), do: parse(value)

  def parse(value) when is_binary(value) do
    value = String.trim(value)

    # Integer.parse/1 ігнорує хвіст, тому збіг має бути на всьому
    # рядку: інакше з "Wed, 21 Oct..." ми взяли б перші цифри.
    case Integer.parse(value) do
      {seconds, ""} -> clamp(seconds * 1_000)
      _ -> parse_http_date(value)
    end
  end

  def parse(_value), do: nil

  # Провайдери надсилають дату у форматі HTTP (RFC 1123):
  # "Wed, 21 Oct 2015 07:28:00 GMT". Деякі сервери — в ISO 8601,
  # тому підтримуємо обидва.
  defp parse_http_date(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> ms_until(datetime)
      _ -> parse_rfc1123(value)
    end
  end

  defp parse_rfc1123(value) do
    case String.split(value, ~r/[\s,]+/, trim: true) do
      [_weekday, day, month, year, time | _] ->
        with {:ok, naive} <- build_naive(day, month, year, time) do
          naive |> DateTime.from_naive!("Etc/UTC") |> ms_until()
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp build_naive(day, month, year, time) do
    month_number = Enum.find_index(@months, &(&1 == month))

    with month_index when is_integer(month_index) <- month_number,
         {day_number, ""} <- Integer.parse(day),
         {year_number, ""} <- Integer.parse(year),
         {hour, minute, second} <- split_time(time) do
      NaiveDateTime.new(year_number, month_index + 1, day_number, hour, minute, second)
    else
      _ -> {:error, :invalid_date}
    end
  end

  defp split_time(time) do
    case String.split(time, ":") do
      [hour, minute, second] ->
        with {h, ""} <- Integer.parse(hour),
             {m, ""} <- Integer.parse(minute),
             {s, ""} <- Integer.parse(second) do
          {h, m, s}
        else
          _ -> {nil, nil, nil}
        end

      _ ->
        {nil, nil, nil}
    end
  end

  # Дата в минулому (розбіжність годинників) не має дати від'ємного
  # очікування.
  defp ms_until(datetime) do
    clamp(DateTime.diff(datetime, DateTime.utc_now(), :millisecond))
  end

  defp clamp(ms) when ms < 0, do: 0
  defp clamp(ms) when ms > @max_retry_after_ms, do: @max_retry_after_ms
  defp clamp(ms), do: ms

  @doc """
  Читає `Retry-After` із заголовків відповіді.

  Req віддає заголовки і як `%Req.Response{}`, і звичайною мапою або
  списком пар — читаємо всі три, щоб одна функція працювала і для
  звичайного, і для стрімінгового виклику.
  """
  @spec from_headers(map() | struct() | keyword() | nil) :: integer() | nil
  def from_headers(nil), do: nil
  def from_headers(%{headers: headers}), do: from_headers(headers)

  def from_headers(headers) when is_map(headers) or is_list(headers) do
    headers
    |> Enum.find_value(fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "retry-after", do: value

      _ ->
        nil
    end)
    |> parse()
  end

  def from_headers(_headers), do: nil
end
