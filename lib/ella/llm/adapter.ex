defmodule Ella.Llm.Adapter do
  @doc """
  Behaviour for all LLM-adapters
  """

  @type message :: map()
  @type tool_schema :: map()
  @type config :: keyword()
  @type responce :: {:ok, message()} | {:error, String.t()}

  @callback chat_completion(messages :: [message()], tools :: [tool_schema()], config :: config()) ::
              responce()
end
