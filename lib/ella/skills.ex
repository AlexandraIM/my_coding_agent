defmodule Ella.Skills do
  @moduledoc """
  Навички — додаткові інструкції для агента у форматі Markdown з
  YAML-подібним frontmatter.

  ## Навіщо

  Проєкт може мати правила, які не випливають з коду: як писати тести,
  який стиль дотримуватись, які команди безпечні. Тримати їх у системному
  промпті постійно дорого — навіть якщо вони не потрібні для поточної
  задачі.

  Тому працюємо за принципом progressive disclosure: у промпт потрапляє
  лише назва й короткий опис, а повний текст навички модель відкриває
  інструментом `load_skill` лише тоді, коли він справді доречний.

  ## Формат файлу

      ---
      name: Testing conventions
      description: How tests are written and run in this project
      tools: [system_exec, read_file]
      ---
      Run the suite with `mix test`.
      Always use ExUnit describe blocks.

  Обов'язкове лише `description`: воно потрапляє в промпт. `name`
  за замовчуванням береться з імені файлу. `tools` обмежує набір
  інструментів, доступних поки навичка активна.

  ## Де шукати

  `~/.ella/skills/` — особисті навички, `~/.ella/skills/` у проєкті —
  навички репозиторію. Проєктні перевизначають особисті за назвою.
  """

  alias Ella.Sandbox

  defstruct [:name, :description, :instructions, :scope, allowed_tools: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          instructions: String.t(),
          scope: :project | :global,
          allowed_tools: [String.t()] | nil
        }

  @extension ".md"

  @doc """
  Завантажує всі навички. Проєктні мають пріоритет над особистими.
  """
  @spec load_all() :: [t()]
  def load_all do
    if Application.get_env(:ella, :seed_default_skills, true) do
      seed_defaults()
    end

    global_dir = Path.join(global_dir(), "skills")
    project_dir = Path.join(Sandbox.root(), ".ella/skills")

    global = load_dir(global_dir, :global)
    project = load_dir(project_dir, :project)

    # Порядок сохраняється: проєктні йдуть першими, глобальні доповнюють.
    (project ++ global)
    |> Enum.uniq_by(&normalise_name(&1.name))
  end

  @doc """
  Записує базові навички в глобальну директорію, якщо їх там ще немає.
  """
  def seed_defaults do
    dir = Path.join(global_dir(), "skills")
    File.mkdir_p!(dir)

    Enum.each(default_skills(), fn {name, content} ->
      path = Path.join(dir, name <> ".md")

      unless File.exists?(path) do
        File.write!(path, content)
      end
    end)

    :ok
  end

  defp default_skills do
    [
      {"verify",
       """
       ---
       name: Verify changes
       description: Run the project's checks after editing code
       tools: [system_exec, read_file]
       ---
       After changing any file, detect and run the project's test command (mix test, pytest, cargo test, go test ./..., npm test). Report real output. A change is not done until checks pass. Never weaken an assertion to go green.
       """},
      {"git",
       """
       ---
       name: Git hygiene
       description: Keep changes small and reviewable; never auto-commit
       tools: [system_exec, read_file]
       ---
       Before editing run git status and git diff --stat. After editing show git diff --stat and changed files. Do not commit, push, or branch unless asked.
       """},
      {"review",
       """
       ---
       name: Code review
       description: Structured review checklist for a change
       tools: [read_file, grep, glob, system_exec]
       ---
       Review: (1) read the diff, (2) read touched files when needed, (3) run checks. Focus on correctness, edge cases, missing tests, security. Separate blocking from nits. End with approve/request changes.
       """},
      {"plan",
       """
       ---
       name: Plan and design
       description: Discipline for planning and architecture work
       tools: [list_dir, grep, glob, read_file, delegate_task]
       ---
       Start with list_dir, then grep/glob. Name concrete files/functions in every step. Separate verified from inferred. Call out risks. Delegate isolated research. Ask approval before Build Mode.
       """}
    ]
  end

  @doc """
  Особиста директорія навичок.
  """
  def global_dir, do: Path.join(System.user_home!(), ".ella")

  @doc """
  Чи є навичка з таким ім'ям.
  """
  def exists?(skills, name) do
    Enum.any?(skills, &(normalise_name(&1.name) == normalise_name(name)))
  end

  @doc """
  Знаходить навичку за ім'ям або іменем файлу.
  """
  @spec find([t()], String.t()) :: {:ok, t()} | {:error, String.t()}
  def find(skills, name) do
    wanted = normalise_name(name)

    case Enum.find(skills, &(normalise_name(&1.name) == wanted)) do
      nil -> {:error, "No skill named #{inspect(name)}."}
      skill -> {:ok, skill}
    end
  end

  @doc """
  Каталог навичок для системного промпту: лише назва та опис.

  Повний текст не додається — інакше навички варті стільки ж
  контексту, скільки й звичайний промпт.
  """
  @spec catalog([t()]) :: String.t()
  def catalog([]), do: ""

  def catalog(skills) do
    entries =
      Enum.map_join(skills, "\n", fn skill ->
        "- #{skill.name}: #{skill.description}"
      end)

    """
    PROJECT SKILLS (available for this repository):
    Call `load_skill` with the skill name to read its full instructions
    before starting a task it applies to.
    ---
    #{entries}
    ---
    """
  end

  @doc """
  Текст навички, який повертає інструмент `load_skill`.
  """
  @spec render(t()) :: String.t()
  def render(skill) do
    header = "# Skill: #{skill.name}"

    restriction =
      case skill.allowed_tools do
        nil ->
          ""

        tools ->
          "\n\nTool restriction: while following this skill you may ONLY use: " <>
            Enum.join(tools, ", ") <>
            ". Any other tool will be unavailable."
      end

    header <> restriction <> "\n\n" <> skill.instructions
  end

  @doc """
  Чи дозволяє навичка інструмент з такою назвою.
  """
  @spec allows?(t() | nil, String.t()) :: boolean()
  def allows?(nil, _tool_name), do: true
  def allows?(%__MODULE__{allowed_tools: nil}, _tool_name), do: true

  def allows?(%__MODULE__{allowed_tools: tools}, tool_name) do
    tool_name in tools
  end

  # --- Завантаження ---

  defp load_dir(dir, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, @extension))
        |> Enum.sort()
        |> Enum.flat_map(&read_skill(Path.join(dir, &1), source))

      {:error, _} ->
        []
    end
  end

  defp read_skill(path, scope) do
    case File.read(path) do
      {:ok, content} ->
        case parse(content) do
          {:ok, skill} ->
            [%{skill | scope: scope, name: skill.name || default_name(path)}]

          {:error, reason} ->
            # Одна бита навичка не повинна ламати весь агент.
            Owl.IO.puts(
              Owl.Data.tag("[skills] skipping #{Path.basename(path)}: #{reason}", :yellow)
            )

            []
        end

      {:error, _} ->
        []
    end
  end

  defp default_name(path) do
    path
    |> Path.basename(@extension)
    |> String.replace(~r/[_-]+/, " ")
  end

  @doc """
  Розбирає Markdown з frontmatter.

  Повертає {:ok, skill} або {:error, reason}. `name` буде nil, якщо
  його немає у frontmatter — тоді викликач підставить ім'я файлу.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(content) when is_binary(content) do
    case split_frontmatter(content) do
      {:ok, frontmatter, body} ->
        fields = parse_frontmatter(frontmatter)

        case Map.get(fields, "description") do
          nil ->
            {:error, "missing required 'description' in frontmatter"}

          description ->
            {:ok,
             %__MODULE__{
               name: Map.get(fields, "name"),
               description: String.trim(description),
               instructions: String.trim(body),
               allowed_tools: Map.get(fields, "tools")
             }}
        end

      :none ->
        {:error, "file has no '---' frontmatter block"}
    end
  end

  defp split_frontmatter("---" <> rest) do
    case String.split(rest, ~r/\r?\n---[ \t]*\r?\n/, parts: 2) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      _ -> :none
    end
  end

  defp split_frontmatter(_), do: :none

  # Мінімальний YAML-підмножина: key: value та списки у вигляді
  # key: [a, b] або key:\n  - a. Повний YAML тут непотрібний і коштував
  # б зайву залежність.
  defp parse_frontmatter(frontmatter) do
    {fields, _last_key} =
      frontmatter
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, &parse_line/2)

    fields
  end

  defp parse_line(line, {fields, last_key}) do
    cond do
      String.trim(line) == "" or String.starts_with?(String.trim(line), "#") ->
        {fields, last_key}

      match = Regex.run(~r/^\s*-\s+(.+)$/, line) ->
        # Regex.run повертає плоский список [full_match | captures].
        [_, item] = match
        {append_to_list(fields, last_key, item), last_key}

      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/, line) ->
        [_, key, raw] = match
        {put_field(fields, key, raw), key}

      true ->
        {fields, last_key}
    end
  end

  defp put_field(fields, key, raw) do
    value = String.trim(raw)

    cond do
      # Порожнє значення — або ключ без значення, або початок списку
      # у наступних рядках. Не відкидаємо попередні значення.
      value == "" ->
        Map.put_new_lazy(fields, key, fn -> [] end)

      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        Map.put(
          fields,
          key,
          value
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
        )

      true ->
        Map.put(fields, key, strip_quotes(value))
    end
  end

  defp append_to_list(fields, nil, _item), do: fields

  defp append_to_list(fields, key, item) do
    existing = Map.get(fields, key)

    existing =
      case existing do
        list when is_list(list) -> list
        _ -> []
      end

    Map.put(fields, key, existing ++ [strip_quotes(String.trim(item))])
  end

  defp strip_quotes(<<?", rest::binary>>) do
    rest |> String.trim_trailing("\"")
  end

  defp strip_quotes(<<?', rest::binary>>) do
    rest |> String.trim_trailing("'")
  end

  defp strip_quotes(value), do: value

  defp normalise_name(name) when is_binary(name) do
    name |> String.trim() |> String.downcase()
  end

  defp normalise_name(_), do: ""
end
