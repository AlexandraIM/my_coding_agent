defmodule Ella.SnapshotTest do
  use ExUnit.Case, async: false

  alias Ella.Snapshot
  alias Ella.Tools.{ApplyPatch, WriteFile}

  setup do
    root = Path.join(System.tmp_dir!(), "ella_snap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous_root = Application.get_env(:ella, :sandbox_root)
    Application.put_env(:ella, :sandbox_root, root)

    {:ok, _} = Snapshot.ensure_started()

    on_exit(fn ->
      # Снапшот — іменований процес: без зупинки наступний тест
      # отримає чужий стан і чужий root.
      if Snapshot.running?(), do: GenServer.stop(Ella.Snapshot)
      File.rm_rf(root)

      if is_nil(previous_root) do
        Application.delete_env(:ella, :sandbox_root)
      else
        Application.put_env(:ella, :sandbox_root, previous_root)
      end
    end)

    {:ok, root: root}
  end

  defp write(relative, content) do
    WriteFile.execute(%{"path" => relative, "content" => content})
  end

  defp read(root, relative), do: File.read!(Path.join(root, relative))

  describe "backup файлів" do
    test "зберігає оригінал перед першою зміною", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "original")

      {:ok, :backed_up} = Snapshot.record_write("a.txt")
      write("a.txt", "modified")

      assert read(root, "a.txt") == "modified"

      assert {:ok, %{restored: ["a.txt"], removed: []}} = Snapshot.rewind()
      assert read(root, "a.txt") == "original"
    end

    test "друга зміна того ж файлу не перезаписує бекап", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "original")

      Snapshot.record_write("a.txt")
      write("a.txt", "v1")
      assert {:ok, :backed_up} = Snapshot.record_write("a.txt")
      write("a.txt", "v2")

      Snapshot.rewind()
      assert read(root, "a.txt") == "original"
    end

    test "видаляє файл, створений агентом" do
      write("new.txt", "created by agent")

      assert {:ok, %{restored: [], removed: ["new.txt"]}} = Snapshot.rewind()
      refute File.exists?(Path.join(Ella.Sandbox.root(), "new.txt"))
    end

    test "відновлює вкладені файли разом із директоріями", %{root: root} do
      File.mkdir_p!(Path.join(root, "lib"))
      File.write!(Path.join(root, "lib/a.ex"), "original")

      Snapshot.record_write("lib/a.ex")
      write("lib/a.ex", "modified")
      File.rm_rf!(Path.join(root, "lib"))

      {:ok, %{restored: ["lib/a.ex"]}} = Snapshot.rewind()
      assert read(root, "lib/a.ex") == "original"
    end

    test "не чіпає роботу користувача поза файлами агента", %{root: root} do
      File.write!(Path.join(root, "agent.txt"), "before")
      File.write!(Path.join(root, "user.txt"), "user work")

      write("agent.txt", "after")

      {:ok, %{restored: ["agent.txt"], removed: []}} = Snapshot.rewind()

      assert read(root, "agent.txt") == "before"
      assert read(root, "user.txt") == "user work"
    end
  end

  describe "stats/0" do
    test "рахує змінені та створені файли", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "x")
      File.write!(Path.join(root, "b.txt"), "y")

      Snapshot.record_write("a.txt")
      Snapshot.record_write("new.txt")

      assert %{changed: 1, created: 1} = Snapshot.stats()
    end

    test "скидається після rewind", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "x")
      Snapshot.record_write("a.txt")

      Snapshot.rewind()
      assert %{changed: 0, created: 0} = Snapshot.stats()
    end
  end

  describe "інтеграція з інструментами" do
    test "write_file робить бекап", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "original")

      write("a.txt", "modified")

      {:ok, %{restored: ["a.txt"]}} = Snapshot.rewind()
      assert read(root, "a.txt") == "original"
    end

    test "apply_patch робить бекап", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "original content")

      ApplyPatch.execute(%{"path" => "a.txt", "search" => "original", "replace" => "patched"})
      assert read(root, "a.txt") == "patched content"

      {:ok, %{restored: ["a.txt"]}} = Snapshot.rewind()
      assert read(root, "a.txt") == "original content"
    end

    test "повторний rewind нічого не робить" do
      write("new.txt", "x")
      Snapshot.rewind()

      assert {:ok, %{restored: [], removed: []}} = Snapshot.rewind()
    end
  end

  describe "помилки" do
    test "відхиляє шлях поза проєктом" do
      assert {:error, reason} = Snapshot.record_write("/etc/passwd")
      assert reason =~ "Absolute paths"
    end

    test "без сесії повертає помилку, а не падає" do
      GenServer.stop(Ella.Snapshot)

      assert {:error, :no_snapshot_session} = Snapshot.record_write("a.txt")
      assert {:error, :no_snapshot_session} = Snapshot.rewind()
      refute Snapshot.running?()
    end
  end
end
