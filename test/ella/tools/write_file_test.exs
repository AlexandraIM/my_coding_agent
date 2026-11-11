defmodule Ella.Tools.WriteFileTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.WriteFile

  setup do
    root = Path.join(System.tmp_dir!(), "write_file_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = Application.get_env(:ella, :sandbox_root)
    Application.put_env(:ella, :sandbox_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous) do
        Application.delete_env(:ella, :sandbox_root)
      else
        Application.put_env(:ella, :sandbox_root, previous)
      end
    end)

    %{root: root}
  end

  defp read_back(root, relative), do: File.read!(Path.join(root, relative))

  test "writes a new file and returns success", %{root: root} do
    assert {:ok, msg} = WriteFile.execute(%{"path" => "note.txt", "content" => "hello"})
    assert msg =~ "Successfully wrote"
    assert read_back(root, "note.txt") == "hello"
  end

  test "overwrites an existing file", %{root: root} do
    WriteFile.execute(%{"path" => "a.txt", "content" => "old"})
    assert {:ok, _} = WriteFile.execute(%{"path" => "a.txt", "content" => "new"})
    assert read_back(root, "a.txt") == "new"
  end

  test "creates nested directories", %{root: root} do
    assert {:ok, _} = WriteFile.execute(%{"path" => "x/y/z.txt", "content" => "nested"})
    assert read_back(root, "x/y/z.txt") == "nested"
  end

  test "normalises non-breaking spaces before writing", %{root: root} do
    WriteFile.execute(%{"path" => "nbsp.txt", "content" => "a\u00A0b"})
    assert read_back(root, "nbsp.txt") == "a b"
  end

  test "rejects paths outside the sandbox" do
    assert {:error, _} =
             WriteFile.execute(%{"path" => "/tmp/ella_should_not_exist", "content" => "x"})

    refute File.exists?("/tmp/ella_should_not_exist")
  end

  test "rejects traversal paths" do
    assert {:error, _} = WriteFile.execute(%{"path" => "../../../etc/hosts", "content" => "x"})
  end

  test "returns invalid arguments for missing keys" do
    assert {:error, msg} = WriteFile.execute(%{"path" => "a.txt"})
    assert msg =~ "Invalid arguments"
  end

  test "returns invalid arguments for non-map input" do
    assert {:error, msg} = WriteFile.execute("bad")
    assert msg =~ "Invalid arguments"
  end
end
