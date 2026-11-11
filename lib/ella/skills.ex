defmodule Ella.Skills do
  @moduledoc """
  Skills — additional instructions for the agent in Markdown format with
  YAML-like frontmatter.

  ## Why

  A project may have rules that don't follow from the code: how to write
  tests, which style to follow, which commands are safe. Keeping them in
  the system prompt all the time is expensive — even when they aren't
  needed for the current task.

  So we work on the principle of progressive disclosure: only the name
  and a short description make it into the prompt, and the full text of
  a skill is opened by the model via the `load_skill` tool only when it
  is truly relevant.

  ## File format

      ---
      name: Testing conventions
      description: How tests are written and run in this project
      tools: [system_exec, read_file]
      ---
      Run the suite with `mix test`.
      Always use ExUnit describe blocks.

  Only `description` is required: it goes into the prompt. `name`
  defaults to the file name. `tools` restricts the set of tools
  available while the skill is active.

  ## Where to look

  `~/.ella/skills/` — personal skills, `.ella/skills/` in the project —
  repository skills. Project skills override personal ones by name.
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
  Loads all skills. Project skills take priority over personal ones.
  """
  @spec load_all() :: [t()]
  def load_all do
    maybe_seed_defaults()

    global_dir = global_dir()
    project_dir = Path.join(Sandbox.root(), ".ella/skills")

    global = load_global(global_dir)
    project = load_dir(project_dir, :project)

    # Order is preserved: project skills come first, global ones supplement.
    (project ++ global)
    |> Enum.uniq_by(&normalise_name(&1.name))
  end

  defp load_global(dir) do
    skills_sub = Path.join(dir, "skills")

    skills_in_sub =
      if File.dir?(skills_sub) do
        load_dir(skills_sub, :global)
      else
        []
      end

    skills_in_root = load_dir(dir, :global)

    (skills_in_sub ++ skills_in_root)
    |> Enum.uniq_by(&normalise_name(&1.name))
  end

  defp maybe_seed_defaults do
    if Application.get_env(:ella, :seed_default_skills, false) and
         not Application.get_env(:ella, :default_skills_seeded, false) do
      try do
        seed_defaults()
        Application.put_env(:ella, :default_skills_seeded, true)
        Ella.Output.puts(Ella.Output.tag("Seeded default skills to ~/.ella/skills/", :magenta))
      rescue
        e ->
          Ella.Output.puts(
            Ella.Output.tag("Failed to seed default skills: #{Exception.message(e)}", :yellow)
          )
      end
    end
  end

  @doc """
  Writes the base skills into the global directory if they aren't there yet.
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

  @doc """
  Seeds default skills to a specific directory (for testing).
  """
  def seed_defaults_to(dir) do
    case Application.get_env(:ella, :seed_default_skills, false) do
      true ->
        File.mkdir_p!(dir)

        Enum.each(default_skills(), fn {name, content} ->
          path = Path.join(dir, name <> ".md")

          unless File.exists?(path) do
            File.write!(path, content)
          end
        end)

        :ok

      false ->
        :ok
    end
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
       If the user has not stated what to plan, ask them first. Start with list_dir, then grep/glob. Name concrete files/functions in every step. Separate verified from inferred. Call out risks. Delegate isolated research. Ask approval before Build Mode.
       """}
    ]
  end

  @doc """
  Personal skills directory.
  """
  def global_dir do
    case Application.get_env(:ella, :global_skills_dir) do
      nil -> Path.join(System.user_home!(), ".ella")
      dir -> dir
    end
  end

  @doc """
  Whether a skill with this name exists.
  """
  def exists?(skills, name) do
    Enum.any?(skills, &(normalise_name(&1.name) == normalise_name(name)))
  end

  @doc """
  Finds a skill by name or file name.
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
  Skill catalog for the system prompt: only name and description.

  The full text is not added — otherwise skills would cost as much
  context as an ordinary prompt.
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
  Skill text returned by the `load_skill` tool.
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
  Whether the skill allows a tool with this name.
  """
  @spec allows?(t() | nil, String.t()) :: boolean()
  def allows?(nil, _tool_name), do: true
  def allows?(%__MODULE__{allowed_tools: nil}, _tool_name), do: true

  def allows?(%__MODULE__{allowed_tools: tools}, tool_name) do
    tool_name in tools
  end

  # --- Loading ---

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
            # One broken skill must not break the whole agent.
            Ella.Output.puts(
              Ella.Output.tag("[skills] skipping #{Path.basename(path)}: #{reason}", :yellow)
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
  Parses Markdown with frontmatter.

  Returns {:ok, skill} or {:error, reason}. `name` will be nil if it is
  absent from the frontmatter — then the caller substitutes the file name.
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

  # Minimal YAML subset: key: value and lists as key: [a, b] or key:
  #   - a. Full YAML is unnecessary here and would cost an extra
  # dependency.
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
        # Regex.run returns a flat list [full_match | captures].
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
      # Empty value — either a key without a value or the start of a list
      # on following lines. Don't discard previous values.
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
