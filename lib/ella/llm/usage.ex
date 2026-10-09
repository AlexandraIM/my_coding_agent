defmodule Ella.Llm.Usage do
  @moduledoc """
  Підрахунок токенів і вартості викликів LLM.

  API відповідає по-різному, тож нормалізуємо до спільної структури.
  Вартість рахується лише тоді, коли для моделі відома ціна за
  мільйон токенів; інакше повертаємо nil і не вигадуємо числа.
  """

  defstruct [:prompt_tokens, :completion_tokens, :model, :cost]

  @type t :: %__MODULE__{
          prompt_tokens: non_neg_integer() | nil,
          completion_tokens: non_neg_integer() | nil,
          model: String.t() | nil,
          cost: float() | nil
        }

  @doc """
  Порожній підрахунок — для адаптерів, що не повертають usage.
  """
  def empty do
    %__MODULE__{prompt_tokens: 0, completion_tokens: 0, model: nil, cost: nil}
  end

  @doc """
  Чи є в цьому підрахунку хоч щось корисне.
  """
  def known?(%__MODULE__{prompt_tokens: nil}), do: false
  def known?(%__MODULE__{prompt_tokens: 0, completion_tokens: 0}), do: false
  def known?(%__MODULE__{}), do: true

  @doc """
  Сумарна кількість токенів.
  """
  def total(%__MODULE__{prompt_tokens: p, completion_tokens: c}) do
    (p || 0) + (c || 0)
  end

  @doc """
  Сумує два підрахунки. Модель і вартість беруться з `other`,
  # якщо вона там є.
  """
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    %__MODULE__{
      prompt_tokens: (a.prompt_tokens || 0) + (b.prompt_tokens || 0),
      completion_tokens: (a.completion_tokens || 0) + (b.completion_tokens || 0),
      model: b.model || a.model,
      cost: add_cost(a.cost, b.cost)
    }
  end

  def add(%__MODULE__{} = a, nil), do: a

  defp add_cost(nil, b), do: b
  defp add_cost(a, nil), do: a
  defp add_cost(a, b), do: a + b

  @doc """
  Витягує usage з відповіді API. Повертає nil, якщо API його не дав.
  """
  def from_response(body) when is_map(body) do
    case Map.get(body, "usage") do
      %{} = usage ->
        %__MODULE__{
          prompt_tokens: get_int(usage, "prompt_tokens"),
          completion_tokens: get_int(usage, "completion_tokens"),
          model: Map.get(body, "model")
        }

      _ ->
        nil
    end
  end

  def from_response(_), do: nil

  defp get_int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  @doc """
  Груба оцінка токенів, коли API не повернуло usage.

  Правило «4 символи = 1 токен» дає помилку ~15%, але краще, ніж
  нуль: без нього ми не бачили б, що контекст розростається.
  """
  def estimate(text) when is_binary(text) do
    div(byte_size(text), 4)
  end

  def estimate(nil), do: 0

  @doc """
  Форматує підрахунок для виводу в консолі.
  """
  def format(%__MODULE__{} = usage) do
    if known?(usage) do
      cost_part =
        case usage.cost do
          nil -> ""
          cost -> " ($" <> :erlang.float_to_binary(cost, decimals: 4) <> ")"
        end

      "#{total(usage)} tokens (#{usage.prompt_tokens || 0} in / #{usage.completion_tokens || 0} out)#{cost_part}"
    else
      "tokens unknown"
    end
  end

  @doc """
  Ціна за мільйон токенів: {:in, {:out}}.
  """
  def price_per_million(model) when is_binary(model) do
    # Орієнтовні ціни станом на 2026; для невідомих моделей nil.
    case model do
      "gpt-4o" -> {2.50, 10.00}
      "gpt-4o-mini" -> {0.15, 0.60}
      "gpt-4-turbo" -> {10.00, 30.00}
      "gpt-4.1" -> {2.00, 8.00}
      "codestral-latest" -> {0.30, 0.90}
      "poolside-code" -> {1.00, 3.00}
      _ -> nil
    end
  end

  def price_per_million(_), do: nil

  @doc """
  Обчислює вартість, якщо для моделі є ціна.
  """
  def with_cost(%__MODULE__{model: nil} = usage), do: usage

  def with_cost(%__MODULE__{} = usage) do
    case price_per_million(usage.model) do
      {in_price, out_price} ->
        cost =
          (usage.prompt_tokens || 0) / 1_000_000 * in_price +
            (usage.completion_tokens || 0) / 1_000_000 * out_price

        %{usage | cost: Float.round(cost, 6)}

      nil ->
        usage
    end
  end
end
