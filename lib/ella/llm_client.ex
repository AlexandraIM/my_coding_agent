defmodule Ella.LlmClient do
  @moduledoc """
  Точка входу до LLM: вибір адаптера, конфігурація, повтори при
  тимчасових помилках і облік токенів.

  Повтори — тут, а не в агенті, бо агент працює синхронно через
  GenServer і не має підходячого місця для очікування.
  """

  alias Ella.Llm.{Error, Usage, Provider}

  @default_max_attempts 4
  @base_delay_ms 500
  @max_delay_ms 30_000

  @doc """
  Список доступних моделей для заданого провайдера.
  Див. також `Ella.Llm.Provider.default_models/1`.
  """
  @spec available_models(String.t()) :: [map()]
  def available_models(provider) when is_binary(provider) do
    Provider.default_models(provider)
  end

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
    Provider.adapter_for(System.get_env("LLM_PROVIDER") || "openai")
  end

  @doc """
  Адаптер для заданого провайдера (без звернення до змінних середовища).

  Див. також `Ella.Llm.Provider.adapter_for/1`.
  """
  def adapter_for(provider) when is_binary(provider) do
    Provider.adapter_for(provider)
  end

  @doc """
  Конфігурація (base_url, api_key, model) для заданого провайдера.

  Uses environment variables for customization, falling back to Provider defaults.
  """
  def config_for(provider) when is_binary(provider) do
    provider_key = String.downcase(provider)
    selected = selected_model_for(provider)

    case provider_key do
      "openai" ->
        [
          base_url: System.get_env("OPENAI_BASE_URL") || Provider.base_url("openai"),
          api_key: System.get_env("OPENAI_API_KEY"),
          model: selected || Provider.default_model("openai")
        ]

      "poolside" ->
        [
          base_url: System.get_env("POOLSIDE_BASE_URL") || Provider.base_url("poolside"),
          api_key: System.get_env("POOLSIDE_API_KEY"),
          model: selected || Provider.default_model("poolside")
        ]

      "mistral" ->
        [
          base_url: "https://api.mistral.ai/v1",
          api_key: System.get_env("MISTRAL_API_KEY"),
          model: selected || Provider.default_model("mistral")
        ]

      "opencode" ->
        [
          base_url: System.get_env("OPENCODE_BASE_URL") || Provider.base_url("opencode"),
          api_key: System.get_env("OPENCODE_API_KEY") || "free",
          model: selected || Provider.default_model("opencode")
        ]

      "ollama" ->
        [
          base_url: System.get_env("OLLAMA_BASE_URL") || Provider.base_url("ollama"),
          api_key: "ollama",
          model: selected || Provider.default_model("ollama")
        ]

      _ ->
        [
          base_url: System.get_env("OPENAI_BASE_URL") || Provider.base_url("openai"),
          api_key: System.get_env("OPENAI_API_KEY"),
          model: selected || Provider.default_model("openai")
        ]
    end
  end

  # Обрана модель: змінна середовища LLM_MODEL має пріоритет,
  # потім — збережена у провайдері конфігурація, потім — nil.
  defp selected_model_for(provider) do
    env_model = System.get_env("LLM_MODEL")

    if env_model != nil and env_model != "" do
      env_model
    else
      case Ella.Storage.load_provider() do
        {:ok, %{provider: p, config: config}} ->
          if String.downcase(p) == String.downcase(provider) do
            Map.get(config, "model")
          else
            nil
          end

        _ ->
          nil
      end
    end
  end

  @doc """
  Перевіряє, що у конфігу є необхідні поля (api_key для провайдерів, що це вимагають).
  Повертає :ok або {:error, reason}. Не робить реальний API-виклик.
  """
  def validate(opts) when is_list(opts) do
    config = Keyword.get(opts, :config, [])
    adapter = Keyword.get(opts, :adapter)
    provider = provider_from_adapter(adapter)

    case provider do
      "ollama" -> :ok  # local, no key needed
      "opencode" -> :ok  # often local, default key provided

      _ ->
        api_key = Keyword.get(config, :api_key)
        if api_key == nil or api_key == "" do
          {:error, "API key not set for #{provider}. Set #{Provider.api_key_env(provider)} or configure via /provider."}
        else
          :ok
        end
    end
  end

  defp provider_from_adapter(Ella.Llm.Adapters.Poolside), do: "poolside"
  defp provider_from_adapter(_), do: "openai"

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
      base_url: System.get_env("POOLSIDE_BASE_URL") || Provider.base_url("poolside"),
      api_key: System.get_env("POOLSIDE_API_KEY"),
      model: System.get_env("LLM_MODEL") || Provider.default_model("poolside")
    ]
  end

  # Кастомні адаптери отримують порожній конфіг: все необхідне вони
  # мають передати самі через :config.
  defp default_config_for(_other_adapter), do: []

  @doc """
  Fetches available models from the provider's API.

  Returns `{:ok, [models]}` where each model has at least `id` and may have `object` fields.
  Returns `{:error, reason}` on failure.

  Note: Some providers (Ollama, OpenCode) may not have a standard `/models` endpoint.
  """
  @spec fetch_models_from_api(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_models_from_api(provider) when is_binary(provider) do
    provider_key = String.downcase(provider)

    # Get API key for auth
    case get_api_key(provider_key) do
      nil ->
        {:error, "No API key configured for #{provider}"}

      api_key ->
        config = config_for(provider)
        base_url = Keyword.get(config, :base_url)

        do_fetch_models(base_url, api_key, provider_key)
    end
  end

  defp get_api_key(provider_key) do
    env_var = Provider.api_key_env(provider_key)
    System.get_env(env_var)
  end

  # OpenAI-compatible API (OpenAI, Poolside, Mistral, Ollama, OpenCode)
  defp do_fetch_models(base_url, api_key, _provider_key) do
    request =
      Req.new(
        base_url: base_url,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 30_000
      )
      |> Req.get(url: "/models")

    case request do
      {:ok, %Req.Response{status: 200, body: %{
                      "data" => model_list
                    }}} ->
        # Transform API response to standard format
        models =
          Enum.map(model_list, fn m ->
            %{
              "id" => Map.get(m, "id"),
              "object" => Map.get(m, "object", "model"),
              "created" => Map.get(m, "created"),
              "owned_by" => Map.get(m, "owned_by")
            }
          end)

        {:ok, models}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "API returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Request failed: #{Exception.message(e)}"}
  end
end
