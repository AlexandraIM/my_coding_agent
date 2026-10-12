defmodule Ella.Config do
  @moduledoc """
  Конфігурація проєкту: `.ella/config.json`.

  Захищені шляхи — властивість конкретного репозиторію, а не агента.
  Ella працює з довільними мовами, тому список визначає проєкт, а не
  код агента.

      {
        "protected_paths": ["mix.exs", "mix.lock", ".github/"],
        "disallowed_patterns": ["bash\\s+-c", "rm\\s+-rf"],
        "require_approval": true,
        "max_attempts": 4,
        "request_timeout_ms": 120000,
        "context_budget": 120000,
        "max_iterations": 50
      }

  Файл опціональний: без нього захист не ввімкнено.

  Ключі надійності (`max_attempts`, `request_timeout_ms`,
  `context_budget`, `max_iterations`) не захищають проєкт, а задають межі
  сесії: скільки разів повторювати тимчасову помилку LLM, скільки
  чекати на відповідь, скільки токенів тримати в історії і скільки кроків
  виконувати за один запит. За замовчуванням вони задані в @default,
  тому проєкт може змінити лише те, що йому не підходить.
  """

  alias Ella.Sandbox

  @filename ".ella/config.json"

  # Зразок для проєкту: показати користувачу, як увімкнути, але
  # нічого не захищати без явного рішення.
  @default %{
    "protected_paths" => [],
    "disallowed_patterns" => [],
    "require_approval" => true,
    "max_attempts" => 4,
    "request_timeout_ms" => 120_000,
    "context_budget" => 120_000,
    "max_iterations" => Ella.Tool.max_iterations()
  }

  @doc """
  Чи читаємо конфіг зараз (у тестах — вимикається).
  """
  def enabled?, do: Application.get_env(:ella, :load_project_config, true)

  @doc """
  Повертає розпізнаний конфіг, накладаючи його на дефолти.
  """
  @spec load() :: map()
  def load do
    if enabled?() do
      path = Path.join(Sandbox.root(), @filename)

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} when is_map(decoded) -> merge(decoded)
            _ -> @default
          end

        {:error, _} ->
          @default
      end
    else
      @default
    end
  end

  @doc """
  Список захищених шляхів або префіксів директорій.
  """
  def protected_paths(config \\ load()) do
    config
    |> Map.get("protected_paths", [])
    |> List.wrap()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Список regex-паттернів, які блокуються у `system_exec`.

  Кожен паттерн компілюється як Regex і перевіряється проти
  повного рядка команди та кожного сегмента після розбору
  ланцюжка (`;`, `&`, `|`).
  """
  def disallowed_patterns(config \\ load()) do
    config
    |> Map.get("disallowed_patterns", [])
    |> List.wrap()
  end

  @doc """
  Чи питати дозволу перед зміною захищеного файлу.

  Якщо `require_approval` вимкнено, запит не показується — зміна
  проходить, але в консолю пишеться попередження.
  """
  def require_approval?(config \\ load()) do
    Map.get(config, "require_approval", true) != false
  end

  @doc """
  Скільки спроб виклику LLM робити, перш ніж здатися.

  Значення має бути цілим > 0: конфіг проєкту не повинен уповільнювати
  агента до безкінечності, тож некоректне значення ігнорується.
  """
  def max_attempts(config \\ load()) do
    positive_int(Map.get(config, "max_attempts"), 4)
  end

  @doc """
  Таймаут очікування відповіді LLM у мілісекундах.
  """
  def request_timeout_ms(config \\ load()) do
    positive_int(Map.get(config, "request_timeout_ms"), 120_000)
  end

  @doc """
  Бюджет історії в токенах, який стискає `Ella.Context`.
  """
  def context_budget(config \\ load()) do
    positive_int(Map.get(config, "context_budget"), 120_000)
  end

  @doc """
  Скільки кроків агент може зробити за один запит користувача.
  """
  def max_iterations(config \\ load()) do
    positive_int(Map.get(config, "max_iterations"), Ella.Tool.max_iterations())
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  @doc """
  Чи захищений шлях.

  Елемент списку захищає і сам файл, і все всередині, якщо це
  директорія (закінчується на `/` або збігається як префікс).
  """
  @spec protected?(String.t(), map()) :: boolean()
  def protected?(path, config \\ load()) when is_binary(path) do
    normalized = normalize(path)

    Enum.any?(protected_paths(config), fn rule ->
      rule = normalize(rule)

      normalized == rule or String.starts_with?(normalized, rule <> "/")
    end)
  end

  # ".github/" і ".github" мають означати те саме, "./mix.exs" — те саме,
  # що "mix.exs".
  defp normalize(path) do
    path
    |> String.trim()
    |> String.trim_trailing("/")
    |> Path.expand(".")
    |> Path.relative_to_cwd()
    |> String.trim_leading("./")
  end

  defp merge(parsed) do
    Map.merge(@default, parsed, fn _key, default, given ->
      if is_nil(given), do: default, else: given
    end)
  end
end
