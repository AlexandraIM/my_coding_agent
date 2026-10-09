defmodule Ella.SandboxTest do
  use ExUnit.Case, async: false

  alias Ella.Sandbox

  setup do
    root = Path.join(System.tmp_dir!(), "ella_sandbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:ella, :sandbox_root)
    Application.put_env(:ella, :sandbox_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(previous) do
        Application.delete_env(:ella, :sandbox_root)
      else
        Application.put_env(:ella, :sandbox_root, previous)
      end
    end)

    {:ok, root: root}
  end

  describe "resolve/1 — дозволені шляхи" do
    test "приймає відносний шлях усередині root" do
      assert {:ok, resolved} = Sandbox.resolve("lib/ella.ex")
      assert resolved == Path.join(Sandbox.root(), "lib/ella.ex")
    end

    test "приймає '.' як поточний каталог" do
      assert {:ok, resolved} = Sandbox.resolve(".")
      assert resolved == Sandbox.root()
    end

    test "приймає шлях до неіснуючого файлу (потрібен для запису)" do
      assert {:ok, _} = Sandbox.resolve("new_dir/new_file.txt")
    end
  end

  describe "resolve/1 — відхилені шляхи" do
    test "відхиляє абсолютний шлях до файлу поза проєктом" do
      assert {:error, reason} = Sandbox.resolve("/etc/passwd")
      assert reason =~ "Absolute paths are not allowed"
    end

    test "відхиляє абсолютний шлях навіть усередині root" do
      absolute = Path.join(Sandbox.root(), "lib/ella.ex")

      assert {:error, reason} = Sandbox.resolve(absolute)
      assert reason =~ "Absolute paths are not allowed"
    end

    test "відхиляє вихід через .." do
      assert {:error, reason} = Sandbox.resolve("../outside.txt")
      assert reason =~ "traversal"
    end

    test "відхиляє глибокий вихід через .." do
      assert {:error, reason} = Sandbox.resolve("lib/../../../../etc/passwd")
      assert reason =~ "traversal"
    end

    test "відхиляє path traversal, замаскований під валідний шлях" do
      assert {:error, _} = Sandbox.resolve("lib/../../secrets.txt")
    end

    test "відхиляє шлях із null-байтом" do
      assert {:error, reason} = Sandbox.resolve("lib/ella.ex\0.png")
      assert reason =~ "null byte"
    end

    test "відхиляє порожній шлях" do
      assert {:error, reason} = Sandbox.resolve("")
      assert reason =~ "empty"
    end

    test "відхиляє пробільний шлях" do
      assert {:error, _} = Sandbox.resolve("   ")
    end

    test "відхиляє не-рядкове значення" do
      assert {:error, reason} = Sandbox.resolve(123)
      assert reason =~ "must be a string"
    end
  end

  describe "symlink-проникнення" do
    test "відхиляє лінк, що веде за межі root", %{root: root} do
      secret = Path.join(System.tmp_dir!(), "ella_secret_#{System.unique_integer([:positive])}")
      File.write!(secret, "top secret")
      File.ln_s!(secret, Path.join(root, "sneaky.txt"))

      on_exit(fn -> File.rm(secret) end)

      assert {:error, reason} = Sandbox.resolve("sneaky.txt")
      assert reason =~ "symlink"
    end

    test "дозволяє лінк, що залишається усередині root", %{root: root} do
      target = Path.join(root, "real.txt")
      File.write!(target, "ok")
      File.ln_s!(target, Path.join(root, "alias.txt"))

      assert {:ok, _} = Sandbox.resolve("alias.txt")
    end
  end

  describe "read/1" do
    test "читає файл всередині root" do
      File.write!(Path.join(Sandbox.root(), "a.txt"), "hello")

      assert {:ok, "hello"} = Sandbox.read("a.txt")
    end

    test "не читає файл поза root" do
      assert {:error, reason} = Sandbox.read("/etc/passwd")
      assert reason =~ "Absolute paths"
    end

    test "повертає помилку для неіснуючого файлу" do
      assert {:error, reason} = Sandbox.read("missing.txt")
      assert reason =~ "Failed to read"
    end
  end

  describe "write/1" do
    test "записує файл і створює проміжні директорії" do
      assert :ok = Sandbox.write("deep/nested/file.txt", "content")
      assert File.read!(Path.join(Sandbox.root(), "deep/nested/file.txt")) == "content"
    end

    test "не записує поза root" do
      assert {:error, reason} = Sandbox.write("/tmp/ella_escape.txt", "bad")
      assert reason =~ "Absolute paths"
    end

    test "не записує через .." do
      assert {:error, _} = Sandbox.write("../ella_escape2.txt", "bad")
    end
  end

  describe "within_root?/1" do
    test "root є межею для себе" do
      assert Sandbox.within_root?(Sandbox.root())
    end

    test "файл усередині root" do
      assert Sandbox.within_root?(Path.join(Sandbox.root(), "lib/x.ex"))
    end

    test "сусідній каталог із спільним префіксом не проходить" do
      refute Sandbox.within_root?(Sandbox.root() <> "_sibling/file.txt")
    end
  end

  describe "resolve!/1" do
    test "кидає виняток на недопустимий шлях" do
      assert_raise ArgumentError, fn -> Sandbox.resolve!("/etc/passwd") end
    end
  end
end
