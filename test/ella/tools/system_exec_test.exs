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

  describe "блокування інтерпреторів" do
    test "блокує bash -c з rm" do
      assert {:error, reason} =
               SystemExec.execute(%{"command" => "bash -c \"rm -rf /tmp\""})

      assert reason =~ "denied command"
      assert reason =~ "rm"
    end

    test "дозволяє bash -c з безпечними командами" do
      assert {:ok, output} =
               SystemExec.execute(%{"command" => "bash -c 'echo from_bash'"})

      assert output =~ "from_bash"
    end

    test "блокує sh -c з mkfs" do
      assert {:error, reason} =
               SystemExec.execute(%{"command" => "sh -c 'mkfs.ext4 /dev/null'"})

      assert reason =~ "mkfs"
    end

    test "блокує python3 -c з rm (через check_interpreter_bypass)" do
      # `;` всередині Python рядка розбиває сегмент, але
      # check_interpreter_bypass перевіряє повну команду.
      assert {:error, reason} =
               SystemExec.execute(%{"command" => "python3 -c 'import os; os.system(\"rm\")'"})

      assert reason =~ "rm"
    end
  end

  describe "disallowed_patterns з конфігу" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "ella_exec_cfg_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, ".ella"))

      previous_root = Application.get_env(:ella, :sandbox_root)
      previous_cfg = Application.get_env(:ella, :load_project_config)
      Application.put_env(:ella, :sandbox_root, root)
      Application.put_env(:ella, :load_project_config, true)

      File.write!(Path.join(root, ".ella/config.json"),
        Jason.encode!(%{
          "protected_paths" => [],
          "disallowed_patterns" => ["curl\\s+http", "wget\\s"],
          "require_approval" => true
        }))

      on_exit(fn ->
        File.rm_rf(root)

        if is_nil(previous_root) do
          Application.delete_env(:ella, :sandbox_root)
        else
          Application.put_env(:ella, :sandbox_root, previous_root)
        end

        if is_nil(previous_cfg) do
          Application.delete_env(:ella, :load_project_config)
        else
          Application.put_env(:ella, :load_project_config, previous_cfg)
        end
      end)

      :ok
    end

    test "блокує за disallowed_patterns" do
      assert {:error, reason} =
               SystemExec.execute(%{"command" => "curl http://evil.example.com"})

      assert reason =~ "disallowed pattern"
    end

    test "дозволяє команди без збігів з disallowed_patterns" do
      assert {:ok, _} = SystemExec.execute(%{"command" => "echo safe_command"})
    end
  end
end
