defmodule Ella.Tools.ApplyPatchTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.ApplyPatch

  setup do
    root = Path.join(System.tmp_dir!(), "apply_patch_test_#{System.unique_integer([:positive])}")
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

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp read_back(root, rel), do: File.read!(Path.join(root, rel))

  describe "exact match" do
    test "happy path updates file once", %{root: root} do
      write(root, "code.ex", "one\ntwo\nthree\n")

      assert {:ok, msg} =
               ApplyPatch.execute(%{"path" => "code.ex", "search" => "two", "replace" => "TWO"})

      assert msg =~ "Successfully patched"
      assert read_back(root, "code.ex") == "one\nTWO\nthree\n"
    end

    test "ambiguous match (2+ occurrences) is rejected", %{root: root} do
      write(root, "dup.ex", "x\nx\n")

      assert {:error, msg} =
               ApplyPatch.execute(%{"path" => "dup.ex", "search" => "x", "replace" => "y"})

      assert msg =~ "Ambiguous patch"
      assert msg =~ "2 times"
      assert read_back(root, "dup.ex") == "x\nx\n"
    end

    test "not found falls through to fuzzy then errors", %{root: root} do
      write(root, "code.ex", "one\ntwo\nthree\n")

      assert {:error, msg} =
               ApplyPatch.execute(%{"path" => "code.ex", "search" => "missing", "replace" => "x"})

      assert msg =~ "Could not find"
      assert read_back(root, "code.ex") == "one\ntwo\nthree\n"
    end

    test "NBSP normalisation allows exact match", %{root: root} do
      write(root, "nbsp.ex", "def foo do\n  :bar\u00A0end\nend\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "nbsp.ex",
                 "search" => ":bar end",
                 "replace" => ":baz end"
               })

      assert read_back(root, "nbsp.ex") == "def foo do\n  :baz end\nend\n"
    end

    test "NBSP in search matches NBSP in file", %{root: root} do
      File.write!(Path.join(root, "raw.ex"), "alpha\nbeta\u00A0gamma\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "raw.ex",
                 "search" => "beta gamma",
                 "replace" => "BETA"
               })

      assert read_back(root, "raw.ex") == "alpha\nBETA\n"
    end
  end

  describe "whitespace normalisation strategy" do
    test "trailing spaces in file are ignored", %{root: root} do
      write(root, "trail.ex", "one   \ntwo\nthree\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{"path" => "trail.ex", "search" => "one", "replace" => "ONE"})

      assert read_back(root, "trail.ex") =~ "ONE"
    end

    test "collapses 3+ blank lines", %{root: root} do
      write(root, "blanks.ex", "a\n\n\n\nb\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "blanks.ex",
                 "search" => "a\n\nb",
                 "replace" => "A\n\nB"
               })

      assert read_back(root, "blanks.ex") =~ "A"
    end
  end

  describe "relative indent strategy" do
    test "inherits original indentation", %{root: root} do
      write(root, "indent.ex", "defmodule Foo do\n  def bar do\n    :baz\n  end\nend\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "indent.ex",
                 "search" => "def bar do\n  :baz\nend",
                 "replace" => "def bar do\n  :qux\nend"
               })

      assert read_back(root, "indent.ex") ==
               "defmodule Foo do\n  def bar do\n    :qux\n  end\nend\n"
    end

    test "multiple occurrences after stripping returns error", %{root: root} do
      write(root, "dup2.ex", "  x\n  x\n")

      assert {:error, _} =
               ApplyPatch.execute(%{"path" => "dup2.ex", "search" => "x", "replace" => "y"})
    end
  end

  describe "multi-block SEARCH/REPLACE format" do
    test "two blocks both applied in order", %{root: root} do
      write(root, "multi.ex", "a\nb\nc\nd\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "multi.ex",
                 "search" =>
                   "<<<<< SEARCH\na\n======\nAA\n>>>>>\n<<<<< SEARCH\nd\n======\nDD\n>>>>>\n",
                 "replace" => "ignored"
               })

      assert read_back(root, "multi.ex") == "AA\nb\nc\nDD\n"
    end

    test "single SEARCH/REPLACE block", %{root: root} do
      write(root, "block.ex", "defmodule Foo do\n  :bar\nend\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{
                 "path" => "block.ex",
                 "search" => "<<<<< SEARCH\n  :bar\n======\n  :baz\n>>>>>\n",
                 "replace" => "ignored"
               })

      assert read_back(root, "block.ex") == "defmodule Foo do\n  :baz\nend\n"
    end

    test "first block found, second not found returns error", %{root: root} do
      write(root, "partial.ex", "a\nb\nc\n")

      assert {:error, msg} =
               ApplyPatch.execute(%{
                 "path" => "partial.ex",
                 "search" =>
                   "<<<<< SEARCH\na\n======\nAA\n>>>>>\n<<<<< SEARCH\nzzz\n======\nZZ\n>>>>>\n",
                 "replace" => "ignored"
               })

      assert msg =~ "Could not find one of the search blocks"
    end

    test "malformed (markers but no blocks) returns error", %{root: root} do
      write(root, "malformed.ex", "a\nb\nc\n")

      assert {:error, msg} =
               ApplyPatch.execute(%{
                 "path" => "malformed.ex",
                 "search" => "<<<< SEARCH\nfoo",
                 "replace" => "ignored"
               })

      assert msg =~ "No SEARCH/REPLACE blocks found"
    end

    test "CRLF line endings still match", %{root: root} do
      File.write!(Path.join(root, "crlf.ex"), "a\r\nb\r\nc\r\n")

      assert {:ok, _} =
               ApplyPatch.execute(%{"path" => "crlf.ex", "search" => "b", "replace" => "B"})

      assert read_back(root, "crlf.ex") =~ "B"
    end
  end

  describe "sandbox / args" do
    test "rejects path outside sandbox", %{root: _root} do
      assert {:error, _} =
               ApplyPatch.execute(%{
                 "path" => "/etc/hosts",
                 "search" => "localhost",
                 "replace" => "x"
               })
    end

    test "missing keys returns invalid arguments" do
      assert {:error, msg} = ApplyPatch.execute(%{"path" => "a.ex"})
      assert msg =~ "Invalid arguments"
    end

    test "non-map input returns invalid arguments" do
      assert {:error, msg} = ApplyPatch.execute("bad")
      assert msg =~ "Invalid arguments"
    end
  end
end
