defmodule Ella.Snapshot do
  @moduledoc """
  Точки відкоту для змін, зроблених агентом.

  ## Чому не git stash

  Ідеальним виглядало б `git stash create` перед build-сесією, але воно
  не працює у двох випадках, які трапляються саме тоді, коли відкат
  потрібен:

  * не включає нові файли, які агент створив;
  * `git checkout <sha> -- .` відновлює змінені файли, але не видаляє
    створені — тобто вони залишаються назавжди.

  Тому робимо резервну копію кожного файлу перед першою його зміною.
  Це працює і без git, відновлює стан точно, і не торкається робочого
  дерева — тобто не затирає незбережені зміни користувача.

  ## Життєвий цикл

  `record_write/1` викликається перед кожним записом. Для файлу, який
  змінюється вперше, зберігається копія поточного вмісту; для створеного
  з нуля файлу записується сам факт створення.

  `rewind/0` повертає всі записані файли до початкового стану і видаляє
  створені.
  """

  use GenServer

  alias Ella.Sandbox

  @name __MODULE__

  @doc """
  Запускає сесію снапшотів, якщо вона ще не працює.

  Викликається агентом при старті; інструменти — на льоту.
  """
  def ensure_started do
    case GenServer.start(@name, nil, name: @name) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Чи активна сесія снапшотів.
  """
  def running?, do: is_pid(GenServer.whereis(@name))

  @doc """
  Записує стан файлу перед його зміною.

  Повертає {:ok, :backed_up} або {:ok, :created}, або {:error, reason}.
  """
  @spec record_write(String.t()) :: {:ok, :backed_up | :created} | {:error, term()}
  def record_write(path) do
    case GenServer.whereis(@name) do
      nil -> {:error, :no_snapshot_session}
      pid -> GenServer.call(pid, {:record_write, path})
    end
  end

  @doc """
  Повертає всі зміни агента до стану на початку сесії.

  Повертає {:ok, %{restored: [...], removed: [...]}} або {:error, reason}.
  """
  @spec rewind() :: {:ok, map()} | {:error, term()}
  def rewind do
    case GenServer.whereis(@name) do
      nil -> {:error, :no_snapshot_session}
      pid -> GenServer.call(pid, :rewind)
    end
  end

  @doc """
  Скільки файлів змінено в цій сесії.
  """
  def stats do
    case GenServer.whereis(@name) do
      nil -> %{changed: 0, created: 0}
      pid -> GenServer.call(pid, :stats)
    end
  end

  # --- Server ---
  @impl true
  def init(_opts) do
    # Стан ведеться окремо для кожного кореня проєкту: процес один,
    # але корінь — це Sandbox.root(), який у тестах міняється.
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:record_write, path}, _from, state) do
    case Sandbox.resolve(path) do
      {:ok, absolute} ->
        root = Sandbox.root()
        {session, state} = session_for(state, root)
        relative = relative_to(root, absolute)
        do_record(session, absolute, relative, state, root)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:rewind, _from, state) do
    root = Sandbox.root()

    case Map.fetch(state.sessions, root) do
      {:ok, session} ->
        removed =
          session.created
          |> Enum.to_list()
          |> Enum.flat_map(&delete_file(root, &1))

        restored =
          session.backups
          |> Enum.map(fn {relative, backup_absolute} ->
            if restore_file(root, relative, backup_absolute), do: relative
          end)
          |> Enum.filter(& &1)
          |> Enum.sort()

        {:reply, {:ok, %{restored: restored, removed: removed}},
         %{state | sessions: Map.delete(state.sessions, root)}}

      :error ->
        # Ідемпотентно: повторний /rewind — це «нічего не робити»,
        # а не помилка.
        {:reply, {:ok, %{restored: [], removed: []}}, state}
    end
  end

  def handle_call(:stats, _from, state) do
    case Map.fetch(state.sessions, Sandbox.root()) do
      {:ok, session} ->
        {:reply, %{changed: map_size(session.backups), created: MapSet.size(session.created)},
         state}

      :error ->
        {:reply, %{changed: 0, created: 0}, state}
    end
  end

  # Повертає {session, state}: стан уже містить створену сесію, тож
  # наступний запис побачить її без повторного створення.
  defp session_for(state, root) do
    case Map.fetch(state.sessions, root) do
      {:ok, session} ->
        {session, state}

      :error ->
        session = %{
          backups: %{},
          created: MapSet.new(),
          backups_dir: backups_dir(root, generate_session_id())
        }

        {session, %{state | sessions: Map.put(state.sessions, root, session)}}
    end
  end

  defp store_session(state, root, session) do
    %{state | sessions: Map.put(state.sessions, root, session)}
  end

  defp do_record(session, absolute, relative, state, root) do
    cond do
      Map.has_key?(session.backups, relative) ->
        # Файл уже збережено — друга зміна його не змінює.
        {:reply, {:ok, :backed_up}, state}

      MapSet.member?(session.created, relative) ->
        # Агент уже створив цей файл у цій сесії.
        {:reply, {:ok, :created}, state}

      File.exists?(absolute) ->
        case backup(session, absolute, relative) do
          {:ok, backup_absolute} ->
            session = %{
              session
              | backups: Map.put(session.backups, relative, backup_absolute)
            }

            {:reply, {:ok, :backed_up}, store_session(state, root, session)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      true ->
        session = %{session | created: MapSet.put(session.created, relative)}
        {:reply, {:ok, :created}, store_session(state, root, session)}
    end
  end

  defp backup(session, absolute, relative) do
    backup_absolute = Path.join(session.backups_dir, backup_name(relative))

    with :ok <- File.mkdir_p(Path.dirname(backup_absolute)),
         {:ok, content} <- File.read(absolute),
         :ok <- File.write(backup_absolute, content) do
      {:ok, backup_absolute}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :could_not_backup}
    end
  end

  defp restore_file(root, relative, backup_absolute) do
    absolute = Path.join(root, relative)

    with {:ok, content} <- File.read(backup_absolute),
         :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, content) do
      true
    else
      _ -> false
    end
  end

  defp delete_file(root, relative) do
    absolute = Path.join(root, relative)

    if File.exists?(absolute) do
      case File.rm(absolute) do
        :ok -> [relative]
        {:error, _} -> []
      end
    else
      []
    end
  end

  # Імена файлів можуть містити слеші, тому копіюємо за хешем шляху.
  defp backup_name(relative) do
    hash =
      :sha256
      |> :crypto.hash(relative)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    hash <> ".bak"
  end

  defp backups_dir(root, session), do: Path.join([root, ".ella", "snapshots", session])

  defp relative_to(_root, absolute) do
    case Sandbox.relativize(absolute) do
      {:ok, "."} -> "."
      {:ok, relative} -> relative
      {:error, _} -> absolute
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
