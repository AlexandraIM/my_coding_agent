defmodule Ella.Tools.SearchToolsTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.{Glob, Grep, ListDir, ReadFile}

  setup do
    root = Path.join(System.tmp_dir!(), "ella_search_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib/ella/tools"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "deps/some_lib"))
    File.mkdir_p!(Path.join(root, "_build/dev"))
    File.mkdir_p!(Path.join(root, ".git"))

    File.write!(
      Path.join(root, "lib/ella/agent.ex"),
      "defmodule Ella.Agent do\n  def run do\n    :ok\n  end\nend\n"
    )

    File.write!(
      Path.join(root, "lib/ella/tools/grep.ex"),
      "defmodule Ella.Tools.Grep do\n  def search, do: :ok\nend\n"
    )

    File.write!(
      Path.join(root, "lib/ella/tools/read_file.ex"),
      "defmodule Ella.Tools.ReadFile do\nend\n"
    )

    File.write!(
      Path.join(root, "test/agent_test.exs"),
      "defmodule AgentTest do\n  test \"run works\" do\n    assert :ok\n  end\nend\n"
    )

    File.write!(Path.join(root, "README.md"), "# Project\n\nRun the agent.\n")
    File.write!(Path.join(root, "mix.exs"), "defmodule MyApp.MixProject do\nend\n")

    # Те, що не має потрапляти в результати пошуку.
    File.write!(Path.join(root, "deps/some_lib/creo.ex"), "def secret_dep_function do\nend\n")
    File.write!(Path.join(root, "_build/dev/generated.ex"), "def compiled_artifact do\nend\n")
    File.write!(Path.join(root, ".git/config"), "[core]\n")

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

    :ok
  end

  describe "ListDir" do
    test "показує структуру з розмірами файлів" do
      assert {:ok, output} = ListDir.execute(%{"path" => "lib", "depth" => 3})

      assert output =~ "ella/"
      assert output =~ "tools/"
      assert output =~ "agent.ex ("
    end

    test "за замовчуванням не показує приховані каталоги" do
      assert {:ok, output} = ListDir.execute(%{"path" => ".", "depth" => 2})

      assert output =~ "lib/"
      assert output =~ "README.md"
      refute output =~ "deps/"
      refute output =~ "_build/"
      refute output =~ ".git/"
    end

    test "повертає помилку для файлу, а не директорії" do
      assert {:error, reason} = ListDir.execute(%{"path" => "mix.exs"})
      assert reason =~ "not a directory"
    end

    test "повертає помилку для неіснуючого шляху" do
      assert {:error, reason} = ListDir.execute(%{"path" => "nope/"})
      assert reason =~ "does not exist"
    end

    test "не виходить за межі проєкту" do
      assert {:error, reason} = ListDir.execute(%{"path" => "/etc"})
      assert reason =~ "Absolute paths"
    end
  end

  describe "Glob" do
    test "знаходить файли за маскою" do
      assert {:ok, output} = Glob.execute(%{"pattern" => "lib/**/*.ex"})

      assert output =~ "lib/ella/agent.ex"
      assert output =~ "lib/ella/tools/grep.ex"
      refute output =~ "test/agent_test.exs"
    end

    test "пропускає ігноровані каталоги" do
      assert {:ok, output} = Glob.execute(%{"pattern" => "**/*.ex"})

      refute output =~ "deps/"
      refute output =~ "_build/"
    end

    test "знаходить файли за конкретним розширенням" do
      assert {:ok, output} = Glob.execute(%{"pattern" => "**/*.md"})
      assert output =~ "README.md"
    end

    test "підтримує маску на конкретний рівень" do
      assert {:ok, output} = Glob.execute(%{"pattern" => "lib/*"})
      assert output =~ "lib/ella/"
    end

    test "повертає 'No files matched' коли нічого не знайшлося" do
      assert {:ok, output} = Glob.execute(%{"pattern" => "**/*.zig"})
      assert output =~ "No files matched"
    end

    test "відхиляє порожній шаблон" do
      assert {:error, _} = Glob.execute(%{"pattern" => ""})
    end

    test "не шукає поза проєктом" do
      assert {:error, reason} = Glob.execute(%{"pattern" => "*.ex", "path" => "/etc"})
      assert reason =~ "Absolute paths"
    end

    test "відхиляє шлях-файл як базу пошуку" do
      assert {:error, reason} = Glob.execute(%{"pattern" => "*", "path" => "mix.exs"})
      assert reason =~ "not a directory"
    end
  end

  describe "Grep" do
    test "знаходить збіги з номерами рядків" do
      assert {:ok, output} = Grep.execute(%{"pattern" => "defmodule"})

      assert output =~ "lib/ella/agent.ex:1:"
      assert output =~ "match(es)"
    end

    test "фільтрує за glob" do
      assert {:ok, output} = Grep.execute(%{"pattern" => "defmodule", "glob" => "test/**/*.exs"})

      assert output =~ "test/agent_test.exs"
      refute output =~ "lib/ella/agent.ex"
    end

    test "не зачіпає ігноровані каталоги" do
      assert {:ok, output} = Grep.execute(%{"pattern" => "secret_dep_function"})
      assert output =~ "No matches"
    end

    test "повертає помилку для невалідного regex" do
      assert {:error, reason} = Grep.execute(%{"pattern" => "[unclosed"})
      assert reason =~ "Invalid regex"
    end

    test "поважає ignore_case" do
      assert {:ok, _} = Grep.execute(%{"pattern" => "defmodule", "ignore_case" => true})
      assert {:ok, output} = Grep.execute(%{"pattern" => "DEFMODULE"})
      assert output =~ "No matches"
      assert {:ok, output} = Grep.execute(%{"pattern" => "DEFMODULE", "ignore_case" => true})
      refute output =~ "No matches"
    end

    test "повертає помилку для неіснуючого шляху" do
      assert {:error, reason} = Grep.execute(%{"pattern" => "x", "path" => "nowhere"})
      assert reason =~ "does not exist"
    end

    test "не шукає поза проєктом" do
      assert {:error, reason} = Grep.execute(%{"pattern" => "x", "path" => "/etc"})
      assert reason =~ "Absolute paths"
    end

    test "поважає limit" do
      assert {:ok, output} = Grep.execute(%{"pattern" => "e", "limit" => 3})

      assert output =~ "Showing first 3 matches"
      assert output |> String.split("\n") |> length() <= 6
    end

    test "шукає у конкретному файлі" do
      assert {:ok, output} = Grep.execute(%{"pattern" => "defmodule", "path" => "mix.exs"})
      assert output =~ "mix.exs:1:"
    end
  end

  describe "ReadFile з offset/limit" do
    test "читає перші N рядків" do
      assert {:ok, output} = ReadFile.execute(%{"path" => "README.md", "limit" => 2})

      assert output =~ "Showing lines 1-2"
      assert output =~ "1\t# Project"
      assert output =~ "2\t"
    end

    test "продовжує з offset" do
      assert {:ok, output} =
               ReadFile.execute(%{"path" => "README.md", "offset" => 3, "limit" => 2})

      assert output =~ "Showing lines 3-4"
      assert output =~ "Run the agent."
    end

    test "повідомляє про загальну кількість рядків" do
      assert {:ok, output} = ReadFile.execute(%{"path" => "mix.exs"})
      assert output =~ "of 3 in mix.exs"
    end

    test "повідомляє, коли offset за межами файлу" do
      assert {:ok, output} = ReadFile.execute(%{"path" => "mix.exs", "offset" => 100})
      assert output =~ "past the end"
    end

    test "не дублює останній рядок при продовженні" do
      assert {:ok, _} = ReadFile.execute(%{"path" => "README.md", "limit" => 2})
      assert {:ok, output} = ReadFile.execute(%{"path" => "README.md", "offset" => 3})
      refute output =~ "# Project"
    end

    test "відхиляє від'ємний offset" do
      assert {:error, reason} = ReadFile.execute(%{"path" => "mix.exs", "offset" => 0})
      assert reason =~ "positive integer"
    end

    test "не читає поза проєктом" do
      assert {:error, _} = ReadFile.execute(%{"path" => "/etc/passwd"})
    end

    test "без offset/limit читає весь файл" do
      assert {:ok, output} = ReadFile.execute(%{"path" => "README.md"})
      assert output =~ "Run the agent."
    end
  end
end
