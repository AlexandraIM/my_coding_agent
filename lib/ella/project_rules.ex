defmodule Ella.ProjectRules do
  @doc """
  Шукає локальні файли інструкцій у корені проєкту та повертає їхній вміст.
  """

  # Список файлів у порядку пріоритету
  @rule_files ["AGENTS.md", "AGENT.md", ".cursorrules", ".agentrules", "CLAUDE.md"]

  def load_rules(root_dir \\ File.cwd!()) do
    @rule_files
    |> Enum.map(&Path.join(root_dir, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        ""

      file_path ->
        filename = Path.basename(file_path)
        Owl.IO.puts(Owl.Data.tag("Loaded project rules from #{filename}", :magenta))

        case File.read(file_path) do
          {:ok, content} ->
            """

            PROJECT SPECIFIC INSTRUCTIONS & RULES (from #{filename}):
            ---
            #{content}
            ---
            """

          {:error, _} ->
            ""
        end
    end
  end
end
