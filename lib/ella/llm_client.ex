defmodule Ella.LlmClient do
  @moduledoc """
  Точка входу до LLM: вибір адаптера, конфігурація, повтори при
  тимчасових помилках і облік токенів.

  Повтори — тут, а не в агенті, бо агент працює синхронно через
  GenServer і не має підходячого місця для очікування.
  """

  alias Ella.Llm.{Error, Usage}

  @default_max_attempts 4
  @base_delay_ms 500
  @max_delay_ms 30_000

  @doc """
  Виконує chat completion з повторами при тимчасових помилках.

  Опції `llm_opts` розширено:
    * `:adapter`, `:config` — як раніше
    * `:max_attempts` — скільки спроб загалом (за замовчуванням 4)
    * `:retry_delay_fn` — fun(attempt) -> мілісекунди, для тестів
    * `:on_retry` — fun(attempt, error, delay) для логування
    * `:sleep_fn` — fun(ms), для тестів
    * `:on_text` — fun(fragment) для сповіщення про кожен фрагмент
      відповіді; за замовчуванням стрім увімкнено й фрагменти
      друкуються в консоль у реальному часі

  Повертає {:ok, message, usage} або {:error, Error.t()}.
  """
  def chat_completion(messages, tools, opts \\ []) do
    # Keyword.get/3 обчислює значення за замовчуванням завжди, тому
    # config беремо через fetch: інакше default_config_for викликався б
    # навіть із переданим config і падав би на кастомних адаптерах.
    adapter = Keyword.get_lazy(opts, :adapter, &default_adapter/0)

    config =
      case Keyword.fetch(opts, :config) do
        {:ok, given} -> given
        :error -> default_config_for(adapter)
      end

    config =
      Keyword.put_new_lazy(config, :request_timeout_ms, fn -> Ella.Config.request_timeout_ms() end)

    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    retry_delay_fn = Keyword.get(opts, :retry_delay_fn, &backoff/1)
    on_retry = Keyword.get(opts, :on_retry, &default_on_retry/3)
    verbose = Keyword.get(opts, :verbose, false)
    on_text = Keyword.get(opts, :on_text, &default_on_text/1)

    attempt(
      adapter,
      config,
      messages,
      tools,
      1,
      max_attempts,
      sleep_fn,
      retry_delay_fn,
      on_retry,
      on_text,
      verbose
    )
  end

  defp attempt(
         adapter,
         config,
         messages,
         tools,
         n,
         max_attempts,
         sleep_fn,
         retry_delay_fn,
         on_retry,
         on_text,
         verbose
       ) do
    if verbose do
      Owl.IO.puts(Owl.Data.tag("--- [LLM REQUEST START] ---", :magenta))
      Owl.IO.puts([Owl.Data.tag("Adapter: ", :cyan), inspect(adapter)])
      Owl.IO.puts([Owl.Data.tag("Config: ", :cyan), inspect(redact(config))])
    end

    result = invoke(adapter, messages, tools, config, on_text)

    case result do
      {:ok, message, usage} ->
        if verbose do
          Owl.IO.puts(Owl.Data.tag("--- [LLM RESPONSE SUCCESS] ---", :green))
          Owl.IO.puts([Owl.Data.tag("Tokens: ", :cyan), Usage.format(usage || Usage.empty())])
        end

        {:ok, message, usage || estimated_usage(messages)}

      {:ok, message} ->
        # Адаптер не повернув usage — оцінюємо приблизно.
        {:ok, message, estimated_usage(messages)}

      {:error, error} ->
        error = normalize(error)

        cond do
          not Error.retryable?(error) ->
            {:error, error}

          n >= max_attempts ->
            {:error, error}

          true ->
            delay = delay_for(error, retry_delay_fn, n)
            on_retry.(n, error, delay)

            if verbose do
              Owl.IO.puts(Owl.Data.tag("Retry #{n}/#{max_attempts} in #{delay}ms", :yellow))
            end

            sleep_fn.(delay)

            attempt(
              adapter,
              config,
              messages,
              tools,
              n + 1,
              max_attempts,
              sleep_fn,
              retry_delay_fn,
              on_retry,
              on_text,
              verbose
            )
        end
    end
  end

  # Адаптер без stream-підтримки отримує звичайний виклик: краще
  # показати відповідь одразу, ніж не показати її зовсім.
  defp invoke(adapter, messages, tools, config, on_text) do
    if function_exported?(adapter, :chat_completion_stream, 4) do
      adapter.chat_completion_stream(messages, tools, config, on_text)
    else
      adapter.chat_completion(messages, tools, config)
    end
  end

  defp default_on_text(fragment) do
    # Owl не переносить рядки сам, тому друкуємо фрагменти як є:
    # укороткі шматки просто зливались б в один рядок.
    if String.length(fragment) > 80 do
      Owl.IO.puts(Owl.Data.tag(fragment, :blue))
    else
      IO.write(fragment)
    end

    :ok
  end

  # Retry-After від сервера має пріоритет над власним backoff.
  defp delay_for(%Error{retry_after_ms: ms}, _retry_delay_fn, _n) when is_integer(ms) do
    min(ms, @max_delay_ms)
  end

  defp delay_for(_error, retry_delay_fn, n), do: retry_delay_fn.(n)

  @doc """
  Експоненційний backoff із jitter.

  Jitter потрібен, щоб паралельні запити не синхронно впиралися в
  той самий rate limit.
  """
  def backoff(attempt) do
    base = @base_delay_ms * Integer.pow(2, max(attempt - 1, 0))
    jitter = :rand.uniform(min(base, 1_000))
    min(base + jitter, @max_delay_ms)
  end

  defp default_on_retry(attempt, error, delay) do
    Owl.IO.puts([
      Owl.Data.tag("[LLM retry #{attempt}] ", :yellow),
      Owl.Data.tag(Error.message(error), :red),
      Owl.Data.tag(" — waiting #{delay}ms", :yellow)
    ])
  end

  defp normalize(%Error{} = error), do: error

  # Адаптери, повертающие просто текст (зокрема старий код і тести).
  defp normalize(reason) when is_binary(reason) do
    if Error.retryable?(reason), do: Error.transient(reason), else: Error.permanent(reason)
  end

  defp normalize(reason), do: Error.permanent(inspect(reason))

  defp estimated_usage(messages) do
    prompt_tokens =
      messages
      |> Enum.map(&message_text/1)
      |> Enum.map(&Usage.estimate/1)
      |> Enum.sum()

    %Usage{prompt_tokens: prompt_tokens, completion_tokens: 0}
  end

  defp message_text(%{} = message), do: message_text(Map.get(message, "content"))
  defp message_text(text) when is_binary(text), do: text
  defp message_text(_), do: ""

  # Не виводимо ключі у лог.
  defp redact(config) do
    Keyword.replace(config, :api_key, "[redacted]")
  end

  defp default_adapter do
    adapter_for(System.get_env("LLM_PROVIDER") || "openai")
  end

  @doc """
  Адаптер для заданого провайдера (без звернення до змінних середовища).
  """
  def adapter_for(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "poolside" -> Ella.Llm.Adapters.Poolside
      _ -> Ella.Llm.Adapters.OpenAI
    end
  end

  @doc """
  Конфігурація (base_url, api_key, model) для заданого провайдера.
  """
  def config_for(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "poolside" ->
        [
          base_url: System.get_env("POOLSIDE_BASE_URL") || "https://api.poolside.ai/v1",
          api_key: System.get_env("POOLSIDE_API_KEY"),
          model: System.get_env("LLM_MODEL") || "poolside-code"
        ]

      "mistral" ->
        [
          base_url: "https://api.mistral.ai/v1",
          api_key: System.get_env("MISTRAL_API_KEY"),
          model: System.get_env("LLM_MODEL") || "codestral-latest"
        ]

      "opencode" ->
        [
          base_url: System.get_env("OPENCODE_BASE_URL") || "http://localhost:4096/v1",
          api_key: System.get_env("OPENCODE_API_KEY") || "free",
          model: System.get_env("LLM_MODEL") || "opencode-recommended"
        ]

      "ollama" ->
        [
          base_url: System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434/v1",
          api_key: "ollama",
          model: System.get_env("LLM_MODEL") || "gemma4:31b-cloud"
        ]

      _ ->
        [
          base_url: System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1",
          api_key: System.get_env("OPENAI_API_KEY"),
          model: System.get_env("LLM_MODEL") || "gpt-4o"
        ]
    end
  end

  @doc """
  Готові llm_opts для заданого провайдера.
  """
  def provider_opts(provider) when is_binary(provider) do
    [
      adapter: adapter_for(provider),
      config: config_for(provider),
      max_attempts: Ella.Config.max_attempts()
    ]
  end

  defp default_config_for(Ella.Llm.Adapters.OpenAI) do
    config_for(System.get_env("LLM_PROVIDER") || "openai")
  end

  defp default_config_for(Ella.Llm.Adapters.Poolside) do
    [
      base_url: System.get_env("POOLSIDE_BASE_URL") || "https://api.poolside.ai/v1",
      api_key: System.get_env("POOLSIDE_API_KEY"),
      model: System.get_env("LLM_MODEL") || "poolside-code"
    ]
  end

  # Кастомні адаптери отримують порожній конфіг: все необхідне вони
  # мають передати самі через :config.
  defp default_config_for(_other_adapter), do: []
end
