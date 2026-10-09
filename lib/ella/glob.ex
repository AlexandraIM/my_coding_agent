defmodule Ella.Glob do
  @moduledoc """
  Матчинг шляхів за glob-шаблоном.

  `Path.wildcard/2` вміє розгортати шаблон у список файлів на диску,
  але не вміє перевірити вже відомий рядок, а `Path.match?/2` у
  стандартній бібліотеці відсутній. Тому конвертуємо шаблон у regex
  один раз і використовуємо його і для фільтрації під час обходу,
  і для перевірки окремих шляхів.
  """

  @doc """
  Чи збігається `path` з `pattern`.

  Підтримуються `*`, `?`, `**`, `{a,b}` та класи `[...]`.
  Повертає false, якщо шаблон скомпільований некоректно.
  """
  @spec match?(String.t(), String.t()) :: boolean()
  def match?(path, pattern) do
    case to_regex(pattern) do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _} -> false
    end
  end

  @doc """
  Конвертує glob у {:ok, regex} або {:error, reason}.
  """
  @spec to_regex(String.t()) :: {:ok, Regex.t()} | {:error, String.t()}
  def to_regex(pattern) do
    Regex.compile("^" <> translate(pattern) <> "$")
  rescue
    error -> {:error, Exception.message(error)}
  end

  # `**/` має збігатися з нулем або більше директорій:
  #   "lib/**/*.ex" має збігатися і з "lib/a.ex", і з "lib/a/b/c.ex".
  defp translate(pattern), do: translate_segment(pattern)

  defp translate_segment(<<>>), do: ""

  defp translate_segment(<<"**/", rest::binary>>) do
    # `**/` -> нуль або більше директорій
    "(?:[^/]+/)*" <> translate_segment(rest)
  end

  defp translate_segment(<<"**", rest::binary>>) do
    # `**` у кінці -> будь-що, включно з /
    ".*" <> translate_segment(rest)
  end

  defp translate_segment(<<?{, rest::binary>>) do
    {inner, rest} = take_until(rest, ?})

    alternatives =
      inner
      |> split_top_level()
      |> Enum.map_join("|", &translate_segment/1)

    "(?:" <> alternatives <> ")" <> translate_segment(rest)
  end

  defp translate_segment(<<?[, rest::binary>>) do
    {inner, rest} = take_until(rest, ?])

    inner =
      case inner do
        <<?!, tail::binary>> -> "^" <> tail
        other -> other
      end

    "[" <> inner <> "]" <> translate_segment(rest)
  end

  defp translate_segment(<<?*, rest::binary>>) do
    "[^/]*" <> translate_segment(rest)
  end

  defp translate_segment(<<??, rest::binary>>) do
    "[^/]" <> translate_segment(rest)
  end

  defp translate_segment(<<char::utf8, rest::binary>>) do
    Regex.escape(<<char::utf8>>) <> translate_segment(rest)
  end

  # Розділяє лише по комах верхнього рівня, щоб {a,b{c,d}} не зламався.
  defp split_top_level(binary), do: do_split_top(binary, "", [], 0)

  defp do_split_top(<<>>, current, acc, _depth) do
    Enum.reverse([current | acc])
  end

  defp do_split_top(<<?{, rest::binary>>, current, acc, depth) do
    do_split_top(rest, <<current::binary, "{">>, acc, depth + 1)
  end

  defp do_split_top(<<?}, rest::binary>>, current, acc, depth) do
    do_split_top(rest, <<current::binary, "}">>, acc, max(depth - 1, 0))
  end

  defp do_split_top(<<?,, rest::binary>>, current, acc, 0) do
    do_split_top(rest, "", [current | acc], 0)
  end

  defp do_split_top(<<char::utf8, rest::binary>>, current, acc, depth) do
    do_split_top(rest, <<current::binary, char::utf8>>, acc, depth)
  end

  # Зупиняємось на відповідному закривачі, рахуючи вкладеність, щоб
  # {a,{b,x}} розбирався як одна група, а не обрізалась на першій }.
  defp take_until(binary, terminator), do: do_take_until(binary, terminator, "", 0)

  defp do_take_until(<<>>, _terminator, acc, _depth) do
    {acc, ""}
  end

  defp do_take_until(<<?[, rest::binary>>, ?], acc, _depth) do
    # Клас символів не може містити вкладену "["; ігноруємо.
    do_take_until(rest, ?], <<acc::binary, "[">>, 0)
  end

  defp do_take_until(<<?], rest::binary>>, ?], acc, _depth) do
    {acc, rest}
  end

  defp do_take_until(<<?{, rest::binary>>, ?}, acc, depth) do
    do_take_until(rest, ?}, <<acc::binary, "{">>, depth + 1)
  end

  defp do_take_until(<<?}, rest::binary>>, ?}, acc, 0) do
    {acc, rest}
  end

  defp do_take_until(<<?}, rest::binary>>, ?}, acc, depth) do
    do_take_until(rest, ?}, <<acc::binary, "}">>, depth - 1)
  end

  defp do_take_until(<<char::utf8, rest::binary>>, terminator, acc, depth) do
    do_take_until(rest, terminator, <<acc::binary, char::utf8>>, depth)
  end
end
