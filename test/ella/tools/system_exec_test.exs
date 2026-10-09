defmodule Ella.Tools.SystemExecTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.SystemExec

  describe "виконання через шелл" do
    test "виконує просту команду" do
      assert {:ok, output} = SystemExec.execute(%{"command" => "echo hello"})
      assert output =~ "hello"
      assert output =~ "Success"
    end

    test "підтримує конвеєри" do
      assert {:ok, output} =
               SystemExec.execute(%{"command" => "printf 'aaa\\nbbb\\nccc\\n' | head -2"})

      assert output =~ "aaa"
      assert output =~ "bbb"
      refute output =~ "ccc"
    end

    test "підтримує послідовність через &&" do
      assert {:ok, output} = SystemExec.execute(%{"command" => "true && echo chained"})
      assert output =~ "chained"
    end

    test "повертає помилку з кодом виходу" do
      assert {:error, output} = SystemExec.execute(%{"command" => "ls /nonexistent_path_xyz"})
      assert output =~ "Command failed"
    end

    test "працює з перенаправленням у файл" do
      path = Path.join(Ella.Sandbox.root(), "ella_exec_test_tmp.txt")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, _} =
               SystemExec.execute(%{"command" => "echo redirected > ella_exec_test_tmp.txt"})

      assert File.read!(path) =~ "redirected"
    end
  end

  describe "політика безпеки" do
    test "блокує rm" do
      assert {:error, reason} = SystemExec.execute(%{"command" => "rm -rf /tmp"})
      assert reason =~ "safety policy"
    end

    test "блокує rm у другому сегменті ланцюга" do
      assert {:error, reason} = SystemExec.execute(%{"command" => "echo hi && rm -rf /tmp/x"})
      assert reason =~ "safety policy"
    end

    test "блокує sudo" do
      assert {:error, _} = SystemExec.execute(%{"command" => "sudo ls"})
    end

    test "блокує shutdown" do
      assert {:error, _} = SystemExec.execute(%{"command" => "shutdown now"})
    end

    test "блокує git reset --hard" do
      assert {:error, reason} = SystemExec.execute(%{"command" => "git reset --hard HEAD~5"})
      assert reason =~ "Destructive git command"
    end

    test "блокує git push --force" do
      assert {:error, _} = SystemExec.execute(%{"command" => "git push --force origin main"})
    end

    test "дозволяє безпечні git команди" do
      assert {:ok, _} = SystemExec.execute(%{"command" => "git --version"})
    end

    test "дозволяє mix test" do
      assert {:ok, _} = SystemExec.execute(%{"command" => "mix --version"})
    end
  end

  describe "обрізання виводу" do
    test "обрізає надто великий stdout" do
      assert {:ok, output} = SystemExec.execute(%{"command" => "yes hello | head -100000"})

      assert output =~ "truncated"
      assert String.length(output) < 40_000
    end
  end

  describe "невалідні аргументи" do
    test "відхиляє без команди" do
      assert {:error, reason} = SystemExec.execute(%{"foo" => "bar"})
      assert reason =~ "Invalid arguments"
    end

    test "відхиляє порожній рядок команди" do
      assert {:ok, _} = SystemExec.execute(%{"command" => ""})
    end
  end
end
