defmodule Ella.Skills do
  @doc """
  Менеджер для завантаження та активації додаткових системних навичок (Skills).
  """

  defstruct [:name, :description, :system_instructions, tools: []]

  # Завантажує список навичок із папки skills/ у проєкті
  def load_available_skills(skills_dir \\ "skills") do
    if File.dir?(skills_dir) do
      skills_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.map(fn file ->
        path = Path.join(skills_dir, file)
        {:ok, content} = File.read(path)
        Jason.decode!(content)
      end)
    else
      []
    end
  end
end
