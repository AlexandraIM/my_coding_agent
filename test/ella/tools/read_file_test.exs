defmodule Ella.Tools.ReadFileTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.ReadFile

  setup do
    root = Path.join(System.tmp_dir!(), "read_file_test_#{System.unique_integer([:positive])}")
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

  test "reads a whole file with numbered lines", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "hello\nworld\n")
    assert {:ok, output} = ReadFile.execute(%{"path" => "note.txt"})
    assert output =~ "1\thello"
    assert output =~ "2\tworld"
    assert output =~ "Showing lines"
  end

  test "offset beyond end of file reports past the end", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "hello\nworld\n")
    assert {:ok, output} = ReadFile.execute(%{"path" => "note.txt", "offset" => 10})
    assert output =~ "Offset 10 is past the end"
  end

  test "limit is clipped at max limit", %{root: root} do
    lines = Enum.map(1..15_000, &"line #{&1}")
    File.write!(Path.join(root, "big.txt"), Enum.join(lines, "\n") <> "\n")

    assert {:ok, output} = ReadFile.execute(%{"path" => "big.txt", "limit" => 999_999})
    # only 10_000 lines should be shown
    assert output =~ "Showing lines 1-10000"
  end

  test "offset 0 returns an error", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "hello\n")
    assert {:error, msg} = ReadFile.execute(%{"path" => "note.txt", "offset" => 0})
    assert msg =~ "must be a positive integer"
  end

  test "negative offset returns an error", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "hello\n")
    assert {:error, msg} = ReadFile.execute(%{"path" => "note.txt", "offset" => -1})
    assert msg =~ "must be a positive integer"
  end

  test "non-integer limit returns an error", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "hello\n")
    assert {:error, msg} = ReadFile.execute(%{"path" => "note.txt", "limit" => "bad"})
    assert msg =~ "must be a positive integer"
  end

  test "missing file returns a read error", %{root: _root} do
    assert {:error, msg} = ReadFile.execute(%{"path" => "nope.txt"})
    assert msg =~ "Failed to read"
  end

  test "rejects paths outside the sandbox" do
    assert {:error, _} = ReadFile.execute(%{"path" => "/etc/passwd"})
  end

  test "rejects traversal paths" do
    assert {:error, _} = ReadFile.execute(%{"path" => "../../../etc/hosts"})
  end

  test "returns invalid arguments for non-map input" do
    assert {:error, msg} = ReadFile.execute("bad")
    assert msg =~ "Invalid arguments"
  end

  test "returns invalid arguments when path is missing" do
    assert {:error, msg} = ReadFile.execute(%{})
    assert msg =~ "Invalid arguments"
  end
end
