defmodule Ella.WriteGuardTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.{ApplyPatch, WriteFile}
  alias Ella.WriteGuard

  setup do
    root = Path.join(System.tmp_dir!(), "ella_guard_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".ella"))

    previous_root = Application.get_env(:ella, :sandbox_root)
    Application.put_env(:ella, :sandbox_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(previous_root) do
        Application.delete_env(:ella, :sandbox_root)
      else
        Application.put_env(:ella, :sandbox_root, previous_root)
      end
    end)

    {:ok, root: root}
  end

  defp protect(paths) do
    File.write!(
      Path.join(Ella.Sandbox.root(), ".ella/config.json"),
      Jason.encode!(%{"protected_paths" => paths, "require_approval" => false})
    )
  end

  defp original_interactive do
    previous = Application.get_env(:ella, :interactive)
    Application.delete_env(:ella, :interactive)
    on_exit(fn -> Application.put_env(:ella, :interactive, previous) end)
  end

  describe "неінтерактивний сеанс" do
    setup do
      original_interactive()
      Application.put_env(:ella, :interactive, false)
      :ok
    end

    test "захищений файл не пишеться" do
      protect(["mix.exs"])

      assert {:error, reason} = WriteFile.execute(%{"path" => "mix.exs", "content" => "hacked"})
      assert reason =~ "non-interactive"
      refute File.exists?(Path.join(Ella.Sandbox.root(), "mix.exs"))
    end

    test "захищений файл не патчиться" do
      protect(["mix.exs"])

      # Створюємо напряму: через write_file це неможливо, він і є
      # предметом перевірки.
      File.write!(Path.join(Ella.Sandbox.root(), "mix.exs"), "original content")

      assert {:error, reason} =
               ApplyPatch.execute(%{
                 "path" => "mix.exs",
                 "search" => "original",
                 "replace" => "patched"
               })

      assert reason =~ "non-interactive"
      assert File.read!(Path.join(Ella.Sandbox.root(), "mix.exs")) == "original content"
    end

    test "незахищений файл пишеться як завжди" do
      protect(["mix.exs"])

      assert {:ok, _} = WriteFile.execute(%{"path" => "lib/a.ex", "content" => "ok"})
      assert File.read!(Path.join(Ella.Sandbox.root(), "lib/a.ex")) == "ok"
    end
  end

  describe "require_approval: false" do
    setup do
      original_interactive()
      Application.put_env(:ella, :interactive, true)
      :ok
    end

    test "захищений файл проходить без запиту" do
      protect(["mix.exs"])

      # Питання не ставиться: interactive? дорівняє true, але
      # require_approval? — false, тому відповідь :yes без діалогу.
      assert {:ok, _} = WriteFile.execute(%{"path" => "mix.exs", "content" => "changed"})
      assert File.read!(Path.join(Ella.Sandbox.root(), "mix.exs")) == "changed"
    end
  end

  describe "повідомлення для моделі" do
    test "відмова забороняє повтор" do
      reason = Ella.Approve.refusal("mix.exs")

      assert reason =~ "Refused"
      assert reason =~ "Do not retry"
    end

    test "неінтерактивність теж забороняє повтор" do
      reason = Ella.Approve.unavailable("mix.exs")

      assert reason =~ "non-interactive"
      assert reason =~ "Do not retry"
    end
  end

  describe "check/2 — незахищені шляхи" do
    test "пропускає без запиту навіть в інтерактивному сеансі" do
      original_interactive()
      Application.put_env(:ella, :interactive, true)

      assert :ok = WriteGuard.check("lib/ella/tool.ex", "write_file")
    end
  end
end
