defmodule Ella.Tool do
  @doc """
  Поведінка (Behaviour) для всіх інструментів агента.
  """

  @max_default_iterations 30

  @type name :: String.t()
  @type description :: String.t()
  @type parameters_schema :: map()
  @type args :: map()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: name()
  @callback description() :: description()
  @callback parameters() :: parameters_schema()
  @callback execute(args()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  Максимальна кількість ітерацій агентного циклу за замовчуванням.

  Обмеження запобігає нескінченному споживанню токенів, коли модель
  продовжує викликати інструменти і не доходить до фінальної відповіді.
  """
  def max_iterations, do: @max_default_iterations

  @doc """
  Безпечно розбирає JSON-аргументи інструмента, які прийшли від моделі.

  Повертає {:ok, map} або {:error, human_readable_reason}. Ніколи не
  вибуває з винятком: невалідний JSON від LLM не повинен глушити GenServer.
  """
  def parse_args(encoded) when is_binary(encoded) do
    case Jason.decode(encoded) do
      {:ok, %{} = args} ->
        {:ok, args}

      {:ok, other} ->
        {:error, "Tool arguments must be a JSON object, got: #{inspect(other)}"}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "Invalid JSON in tool arguments: #{Exception.message(err)}"}
    end
  end

  def parse_args(encoded) do
    {:error, "Tool arguments must be a JSON string, got: #{inspect(encoded)}"}
  end

  @doc "Перетворює інструмент у стандартний формат OpenAI / Anthropic Tool Schema"
  def to_schema(tool_module) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool_module.name(),
        "description" => tool_module.description(),
        "parameters" => tool_module.parameters()
      }
    }
  end
end
