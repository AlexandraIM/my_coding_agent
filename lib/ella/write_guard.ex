defmodule Ella.WriteGuard do
  @moduledoc """
  Гейт перед будь-якою зміною файлу на диску.

  Спільна точка для `write_file` і `apply_patch`: обидва мають однаково
  перевіряти захист, інакше правило легко обійти тим інструментом,
  про який забули.

  Тут же робиться резервна копія файлу, щоб `/rewind` мав з чим
  працювати. Копіювання мусить бути до запису, а не після: після
  запису оригіналу вже немає.
  """

  alias Ella.{Approve, Config, Snapshot}

  @doc """
  Чи можна змінювати `path`.

  Повертає :ok або {:error, message} з текстом для моделі.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, String.t()}
  def check(path, tool_name) do
    with :ok <- approve(path, tool_name) do
      Snapshot.record_write(path)
      :ok
    end
  end

  defp approve(path, tool_name) do
    if Config.protected?(path) do
      case Approve.ask(tool_name, path) do
        :yes -> :ok
        :no -> {:error, Approve.refusal(path)}
        :unavailable -> {:error, Approve.unavailable(path)}
      end
    else
      :ok
    end
  end
end
