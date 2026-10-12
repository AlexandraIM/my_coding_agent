defmodule Ella.Llm.RetryAfterTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.RetryAfter

  defp to_rfc1123(datetime) do
    %{
      "day_name" => day_name(datetime),
      "day" => pad(datetime.day),
      "month" => month(datetime),
      "year" => datetime.year,
      "hour" => pad(datetime.hour),
      "minute" => pad(datetime.minute),
      "second" => pad(datetime.second)
    }
    |> then(
      &"#{&1["day_name"]}, #{&1["day"]} #{&1["month"]} #{&1["year"]} #{&1["hour"]}:#{&1["minute"]}:#{&1["second"]} GMT"
    )
  end

  defp day_name(datetime) do
    ~w(Mon Tue Wed Thu Fri Sat Sun) |> Enum.at(Date.day_of_week(datetime) - 1)
  end

  defp month(datetime),
    do: ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) |> Enum.at(datetime.month - 1)

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)

  describe "parse/1 — кількість секунд" do
    test "переводить секунди в мілісекунди" do
      assert RetryAfter.parse("30") == 30_000
      assert RetryAfter.parse("1") == 1_000
    end

    test "приймає вже перетворене значення" do
      assert RetryAfter.parse(2) == 2_000
    end

    test "терпить пробіли" do
      assert RetryAfter.parse("  5  ") == 5_000
    end
  end

  describe "parse/1 — HTTP-дата" do
    test "рахує час до майбутньої дати" do
      future = DateTime.utc_now() |> DateTime.add(45, :second) |> DateTime.to_iso8601()

      ms = RetryAfter.parse(future)

      assert is_integer(ms)
      assert ms > 40_000
      assert ms <= 45_000
    end

    test "дата в минулому не дає від'ємного очікування" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      assert RetryAfter.parse(past) == 0
    end

    test "не більше п'яти хвилин" do
      far = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()

      assert RetryAfter.parse(far) == 300_000
    end

    test "розуміє формат HTTP (RFC 1123), який надсилають провайдери" do
      future =
        DateTime.utc_now()
        |> DateTime.add(60, :second)
        |> DateTime.truncate(:second)
        |> to_rfc1123()

      ms = RetryAfter.parse(future)

      assert is_integer(ms)
      assert ms > 50_000
      assert ms <= 60_000
    end

    test "нерозпізнаний HTTP-формат не ламає розбір" do
      assert RetryAfter.parse("Wed, 99 Xxx 2015 07:28:00 GMT") == nil
      assert RetryAfter.parse("21 Oct") == nil
    end
  end

  describe "parse/1 — нерозбірливе значення" do
    test "повертає nil, щоб працював власний backoff" do
      assert RetryAfter.parse("завтра") == nil
      assert RetryAfter.parse("") == nil
      assert RetryAfter.parse(nil) == nil
      assert RetryAfter.parse(%{}) == nil
    end
  end

  describe "from_headers/1" do
    test "читає заголовок зі списку пар" do
      assert RetryAfter.from_headers([{"retry-after", "12"}]) == 12_000
    end

    test "не залежить від регістру" do
      assert RetryAfter.from_headers(%{"Retry-After" => "12"}) == 12_000
    end

    test "читає з %Req.Response{}" do
      response = %Req.Response{status: 429, headers: %{"retry-after" => "7"}}

      assert RetryAfter.from_headers(response) == 7_000
    end

    test "відсутній заголовок — nil" do
      assert RetryAfter.from_headers(%{"content-type" => "application/json"}) == nil
      assert RetryAfter.from_headers(nil) == nil
      assert RetryAfter.from_headers(%Req.Response{status: 500, headers: %{}}) == nil
    end
  end
end
