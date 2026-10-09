defmodule Ella.Tools.FileToolsTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.{ApplyPatch, ReadFile, WriteFile}

  setup do
    root = Path.join(System.tmp_dir!(), "ella_files_#{System.unique_integer([:positive])}")
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

    :ok
  end

  defp read_back(relative), do: File.read!(Path.join(Ella.Sandbox.root(), relative))

  describe "ReadFile" do
    test "читає файл" do
      WriteFile.execute(%{"path" => "note.txt", "content" => "hello"})
      assert {:ok, "hello"} = ReadFile.execute(%{"path" => "note.txt"})
    end

    test "не читає поза проєктом" do
      assert {:error, reason} = ReadFile.execute(%{"path" => "/etc/passwd"})
      assert reason =~ "Absolute paths"
    end

    test "не читає через .." do
      assert {:error, reason} = ReadFile.execute(%{"path" => "../../../etc/hosts"})
      assert reason =~ "traversal"
    end
  end

  describe "WriteFile" do
    test "записує файл" do
      assert {:ok, _} = WriteFile.execute(%{"path" => "a.txt", "content" => "data"})
      assert read_back("a.txt") == "data"
    end

    test "створює вкладені директорії" do
      assert {:ok, _} = WriteFile.execute(%{"path" => "x/y/z.txt", "content" => "nested"})
      assert read_back("x/y/z.txt") == "nested"
    end

    test "не записує поза проєктом" do
      assert {:error, _} =
               WriteFile.execute(%{"path" => "/tmp/ella_should_not_exist", "content" => "x"})

      refute File.exists?("/tmp/ella_should_not_exist")
    end

    test "нормалізує non-breaking spaces" do
      WriteFile.execute(%{"path" => "nbsp.txt", "content" => "a\u00A0b"})
      assert read_back("nbsp.txt") == "a b"
    end
  end

  describe "ApplyPatch" do
    setup do
      WriteFile.execute(%{"path" => "code.ex", "content" => "one\ntwo\nthree\n"})
      :ok
    end

    test "замінює унікальний фрагмент" do
      assert {:ok, _} =
               ApplyPatch.execute(%{"path" => "code.ex", "search" => "two", "replace" => "TWO"})

      assert read_back("code.ex") == "one\nTWO\nthree\n"
    end

    test "повертає помилку, якщо фрагмент не знайдено" do
      assert {:error, reason} =
               ApplyPatch.execute(%{"path" => "code.ex", "search" => "missing", "replace" => "x"})

      assert reason =~ "Could not find"
      assert read_back("code.ex") == "one\ntwo\nthree\n"
    end

    test "відмовляється від неоднозначного патчу" do
      WriteFile.execute(%{"path" => "dup.ex", "content" => "x\nx\n"})

      assert {:error, reason} =
               ApplyPatch.execute(%{"path" => "dup.ex", "search" => "x", "replace" => "y"})

      assert reason =~ "Ambiguous patch"
      assert reason =~ "2 times"
      # Файл не змінено
      assert read_back("dup.ex") == "x\nx\n"
    end

    test "нормалізує non-breaking spaces у файлі та в аргументах" do
      WriteFile.execute(%{"path" => "nbsp.ex", "content" => "def foo do\n  :bar\u00A0end\nend\n"})

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "nbsp.ex",
                 "search" => ":bar end",
                 "replace" => ":baz end"
               })

      assert read_back("nbsp.ex") == "def foo do\n  :baz end\nend\n"
    end

    test "знаходить фрагмент, якщо у файлі nbsp, а в search — звичайний пробіл" do
      File.write!(Path.join(Ella.Sandbox.root(), "raw.ex"), "alpha\nbeta\u00A0gamma\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "raw.ex",
                 "search" => "beta gamma",
                 "replace" => "BETA"
               })

      assert read_back("raw.ex") == "alpha\nBETA\n"
    end

    test "не патчить поза проєктом" do
      assert {:error, _} =
               ApplyPatch.execute(%{
                 "path" => "/etc/hosts",
                 "search" => "localhost",
                 "replace" => "x"
               })
    end
  end
end
