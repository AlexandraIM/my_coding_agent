defmodule Ella.Llm.Error do
  @moduledoc """
  Структурована помилка виклику LLM.

  Рядок помилки не дозволяє відрізнити тимчасовий збій (429, 503,
  обрив мережі), який варто повторити, від постійного (401, 400 з
  неправильним payload), де повтор нічого не дасть і лише витратить
  час та токени.
  """

  @enforce_keys [:message, :retryable?]
  defstruct [:message, :retryable?, :status, :retry_after_ms]

  @type t :: %__MODULE__{
          message: String.t(),
          retryable?: boolean(),
          status: integer() | nil,
          retry_after_ms: integer() | nil
        }

  @doc """
  Помилка, яку варто повторити: rate limit, server error, таймаут.
  """
  @spec transient(String.t(), keyword()) :: t()
  def transient(message, opts \\ []) do
    %__MODULE__{
      message: message,
      retryable?: true,
      status: Keyword.get(opts, :status),
      retry_after_ms: Keyword.get(opts, :retry_after_ms)
    }
  end

  @doc """
  Помилка, повтор якої не має сенсу: невірний ключ, поганий запит.
  """
  @spec permanent(String.t(), keyword()) :: t()
  def permanent(message, opts \\ []) do
    %__MODULE__{
      message: message,
      retryable?: false,
      status: Keyword.get(opts, :status)
    }
  end

  @doc """
  Чи є помилка тимчасовою.

  Приймає і структуру, і звичайний рядок — старий код міг передати
  помилку з адаптера, який повертає просто текст.
  """
  @spec retryable?(t() | String.t() | term()) :: boolean()
  def retryable?(%__MODULE__{retryable?: retryable?}), do: retryable?

  def retryable?(reason) when is_binary(reason) do
    String.contains?(reason, "429") or String.contains?(reason, "Network error")
  end

  def retryable?(_), do: false

  @doc """
  Повідомлення для користувача, незалежно від типу помилки.
  """
  @spec message(t() | term()) :: String.t()
  def message(%__MODULE__{message: message}), do: message
  def message(reason) when is_binary(reason), do: reason
  def message(reason), do: inspect(reason)
end
