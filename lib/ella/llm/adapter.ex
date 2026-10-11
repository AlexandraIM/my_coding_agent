defmodule Ella.Llm.Adapter do
  @moduledoc """
  Behaviour для всіх LLM-адаптерів.

  `chat_completion/3` повертає {:ok, message, usage} або
  {:error, Ella.Llm.Error.t()}. Структурована помилка потрібна, щоб
  клієнт міг відрізнити rate limit від помилки авторизації і вирішити,
  чи варто повторювати запит.

  `chat_completion_stream/4` додатково приймає callback, який
  викликається з кожним фрагментом тексту, щоб агент міг показувати
  відповідь у реальному часі. Callback може повернути {:halt, reason},
  щоб перервати потік.
  """

  alias Ella.Llm.{Error, Usage}

  @type message :: map()
  @type tool :: atom() | map()
  @type config :: keyword()
  @type response :: {:ok, message(), Usage.t() | nil} | {:error, Error.t()}
  @type on_text :: (String.t() -> :ok | {:halt, term()})

  @callback chat_completion(messages :: [message()], tools :: [tool()], config :: config()) ::
              response()

  @callback chat_completion_stream(
              messages :: [message()],
              tools :: [tool()],
              config :: config(),
              on_text :: on_text()
            ) :: response()

  @optional_callbacks [chat_completion_stream: 4]
end
