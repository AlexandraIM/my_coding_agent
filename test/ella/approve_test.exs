defmodule Ella.ApproveTest do
  use ExUnit.Case, async: false

  alias Ella.Approve

  setup do
    root = Path.join(System.tmp_dir!(), "approve_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous_root = Application.get_env(:ella, :sandbox_root)
    previous_interactive = Application.get_env(:ella, :interactive)
    previous_load_config = Application.get_env(:ella, :load_project_config)

    Application.put_env(:ella, :sandbox_root, root)
    Application.delete_env(:ella, :interactive)
    Application.put_env(:ella, :load_project_config, true)

    on_exit(fn ->
      File.rm_rf!(root)

      restore = fn key, val ->
        if is_nil(val) do
          Application.delete_env(:ella, key)
        else
          Application.put_env(:ella, key, val)
        end
      end

      restore.(:sandbox_root, previous_root)
      restore.(:interactive, previous_interactive)
      restore.(:load_project_config, previous_load_config)
      Ella.Output.reset_sink()
    end)

    %{root: root}
  end

  describe "interactive?/0" do
    test "returns false when app env is false" do
      Application.put_env(:ella, :interactive, false)
      refute Approve.interactive?()
    end

    test "returns true when app env is true" do
      Application.put_env(:ella, :interactive, true)
      assert Approve.interactive?()
    end

    test "returns false when CI env var is set and no app override" do
      Application.delete_env(:ella, :interactive)
      System.put_env("CI", "true")
      on_exit(fn -> System.delete_env("CI") end)
      refute Approve.interactive?()
    end
  end

  describe "ask/2" do
    test "returns :unavailable in non-interactive mode" do
      Application.put_env(:ella, :interactive, false)
      assert Approve.ask("write_file", "lib/foo.ex") == :unavailable
    end

    test "returns :yes and warns when require_approval is false", %{root: root} do
      Application.put_env(:ella, :interactive, true)

      File.mkdir_p!(Path.join(root, ".ella"))
      File.write!(Path.join(root, ".ella/config.json"), ~s({"require_approval": false}))

      Ella.Output.set_sink(self())

      assert Approve.ask("write_file", "lib/foo.ex") == :yes

      output =
        collect_output()

      assert output =~ "[protected]"
    end
  end

  describe "refusal/1 and unavailable/1" do
    test "refusal returns the expected message" do
      msg = Approve.refusal("lib/foo.ex")
      assert msg =~ "Refused by the user"
      assert msg =~ "lib/foo.ex"
      assert msg =~ "Do not retry"
    end

    test "unavailable returns the expected message" do
      msg = Approve.unavailable("lib/foo.ex")
      assert msg =~ "Blocked"
      assert msg =~ "non-interactive"
      assert msg =~ "lib/foo.ex"
    end
  end

  defp collect_output(acc \\ "") do
    receive do
      {:output, text} -> collect_output(acc <> to_string(text))
    after
      50 -> acc
    end
  end
end
