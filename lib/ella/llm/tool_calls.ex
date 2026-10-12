defmodule Ella.Llm.ToolCalls do
  @moduledoc """
  Збирання викликів інструментів із потокових фрагментів.

  Провайдери не надсилають виклик інструмента одним шматком: спершу
  приходить ім'я, потім аргументи — частинами, у вигляді обрізків
  JSON. Просте додавання фрагментів у список дало б N напівготових
  викликів замість одного, тому накопичуємо за стабільним індексом.

  Логіка спільна для обох адаптерів: вони отримують ті самі фрагменти
  у тій самій формі.
  """

  @doc """
  Додає фрагмент виклику до накопиченого списку.

  `index` — позиція виклику в масиві, стабільна між фрагментами.
  Фрагменти без індексу (деякі провайдери) додаються в кінець.
  """
  @spec merge([map()], map()) :: [map()]
  def merge(existing, fragment) when is_list(existing) and is_map(fragment) do
    case Map.get(fragment, "index") do
      nil -> existing ++ [fragment]
      index -> put_at_index(existing, index, fragment)
    end
  end

  defp put_at_index(existing, index, fragment) do
    case Enum.find_index(existing, &(&1["index"] == index)) do
      nil ->
        existing ++ [fragment]

      position ->
        List.replace_at(existing, position, merge_fields(Enum.at(existing, position), fragment))
    end
  end

  # Злиття має бути рекурсивним: аргументи приходять усередині
  # вкладеного об'єкта "function", і просте заміщення відкидало б
  # уже накопичену частину JSON.
  @doc false
  def merge_fields(base, addition) do
    Enum.reduce(addition, base, fn
      {key, new}, acc when is_map(new) ->
        case Map.get(acc, key) do
          current when is_map(current) -> Map.put(acc, key, merge_fields(current, new))
          _ -> Map.put(acc, key, new)
        end

      {key, new}, acc when is_binary(new) ->
        case Map.get(acc, key) do
          current when is_binary(current) -> Map.put(acc, key, current <> new)
          _ -> Map.put(acc, key, new)
        end

      _key_value, acc ->
        acc
    end)
  end

  @doc """
  Надає накопиченим фрагментам фінальну форму, яку очікує агент.

  Провайдери надсилають різні поля (`function`, `arguments` на верхньому
  рівні, іноді без `id`), а агент потребує узгодженого
  `%{"id", "type", "function" => %{"name", "arguments"}}`.
  """
  @spec render([map()]) :: [map()]
  def render(calls) do
    calls
    |> Enum.with_index(1)
    |> Enum.map(fn {call, n} -> render_one(call, n) end)
  end

  defp render_one(call, n) do
    function = Map.get(call, "function") || %{}
    name = Map.get(function, "name") || Map.get(call, "name")
    arguments = Map.get(function, "arguments") || Map.get(call, "arguments") || "{}"

    %{
      "id" => Map.get(call, "id") || "call_#{n}",
      "type" => "function",
      "function" => %{"name" => name, "arguments" => arguments}
    }
  end
end
