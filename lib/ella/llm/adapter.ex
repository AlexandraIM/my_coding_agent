defmodule Ella.Llm.Adapter do
  @moduledoc """
  Behaviour для всіх LLM-адаптерів.

  `chat_completion/3` повертає {:ok, message, usage} або
  {:error, Ella.Llm.Error.t()}. Структурована помилка потрібна, щоб
  клієнт міг відрізнити rate limit від помилки авторизації і вирішити,
  чи варто повторювати запит.
  """

  alias Ella.Llm.{Error, Usage}

  @type message :: map()
  @type tool :: atom() | map()
  @type config :: keyword()
  @type response :: {:ok, message(), Usage.t() | nil} | {:error, Error.t()}

  @callback chat_completion(messages :: [message()], tools :: [tool()], config :: config()) ::
              response()
end
