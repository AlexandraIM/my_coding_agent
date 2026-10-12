defmodule Ella.ConfigTest do
  use ExUnit.Case, async: false

  alias Ella.Config

  setup do
    root = Path.join(System.tmp_dir!(), "ella_config_#{System.unique_integer([:positive])}")
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

  defp write_config(root, map) do
    File.write!(Path.join([root, ".ella", "config.json"]), Jason.encode!(map))
  end

  describe "load/0 — відсутність конфігу" do
    test "повертає дефолти без помилки" do
      config = Config.load()

      assert Config.protected_paths(config) == []
      assert Config.require_approval?(config)
    end
  end

  describe "load/0 — читання" do
    test "читає protected_paths", %{root: root} do
      write_config(root, %{"protected_paths" => ["mix.exs", ".github/"]})

      assert Config.protected_paths() == ["mix.exs", ".github/"]
    end

    test "читає require_approval: false", %{root: root} do
      write_config(root, %{"protected_paths" => ["mix.exs"], "require_approval" => false})

      refute Config.require_approval?()
    end

    test "не ламається на битому JSON" do
      File.write!(Path.join(Ella.Sandbox.root(), ".ella/config.json"), "{not json")

      assert Config.protected_paths() == []
    end

    test "ігнорує невідомі поля" do
      File.write!(
        Path.join(Ella.Sandbox.root(), ".ella/config.json"),
        ~s({"protected_paths": [], "something_else": 42})
      )

      assert Config.protected_paths() == []
    end

    test "nil у полі protected_paths не затирає дефолт", %{root: root} do
      write_config(root, %{"protected_paths" => nil})

      assert Config.protected_paths() == []
    end
  end

  describe "налаштування надійності" do
    test "дефолти застосовуються, коли ключів немає" do
      assert Config.max_attempts() == 4
      assert Config.request_timeout_ms() == 120_000
      assert Config.context_budget() == 120_000
      assert Config.max_iterations() == Ella.Tool.max_iterations()
    end

    test "читаються з конфігу проєкту", %{root: root} do
      write_config(root, %{
        "max_attempts" => 7,
        "request_timeout_ms" => 30_000,
        "context_budget" => 8_000,
        "max_iterations" => 3
      })

      assert Config.max_attempts() == 7
      assert Config.request_timeout_ms() == 30_000
      assert Config.context_budget() == 8_000
      assert Config.max_iterations() == 3
    end

    test "некоректні значення не ламають сесію", %{root: root} do
      write_config(root, %{
        "max_attempts" => "багато",
        "request_timeout_ms" => -1,
        "context_budget" => nil
      })

      assert Config.max_attempts() == 4
      assert Config.request_timeout_ms() == 120_000
      assert Config.context_budget() == 120_000
    end
  end

  describe "protected?/2 — матчинг" do
    defp config(paths), do: %{"protected_paths" => paths}

    test "точний збіг файлу" do
      assert Config.protected?("mix.exs", config(["mix.exs"]))
      refute Config.protected?("lib/ella.ex", config(["mix.exs"]))
    end

    test "правило з '/' захищає все всередині" do
      assert Config.protected?(".github/workflows/ci.yml", config([".github/"]))
      assert Config.protected?(".github/workflows/ci.yml", config([".github"]))
    end

    test "директорія захищає власний вміст, але не сусідів" do
      assert Config.protected?("config/dev.exs", config(["config"]))
      refute Config.protected?("config_backup/dev.exs", config(["config"]))
    end

    test "./ префікс не впливає" do
      assert Config.protected?("./mix.exs", config(["mix.exs"]))
    end

    test "не захищає файл, схожий на правило" do
      refute Config.protected?("mix.exs.bak", config(["mix.exs"]))
    end

    test "порожній список нічого не захищає" do
      refute Config.protected?("mix.exs", config([]))
    end
  end
end
