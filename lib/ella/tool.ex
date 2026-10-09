defmodule Ella.Tool do
  @doc """
  Поведінка (Behaviour) для всіх інструментів агента.
  """

  @type name :: String.t()
  @type description :: String.t()
  @type parameters_schema :: map()
  @type args :: map()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @callback name() :: name()
  @callback description() :: description()
  @callback parameters() :: parameters_schema()
  @callback execute(args()) :: {:ok, String.t()} | {:error, String.t()}

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
