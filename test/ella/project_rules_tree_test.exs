defmodule Ella.ProjectRulesTreeTest do
  use ExUnit.Case, async: false

  alias Ella.ProjectRules

  setup do
    root =
      Path.join(System.tmp_dir!(), "ella_tree_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(Path.join(root, "lib"), "web"))
    File.mkdir_p!(Path.join(root, "test"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.mkdir_p!(Path.join(root, "node_modules"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, ".ella"))

    File.write!(Path.join(root, "mix.exs"), "defmodule Mix.Project do end")
    File.write!(Path.join(root, "README.md"), "# Project")
    File.write!(Path.join(Path.join(root, "lib"), "app.ex"), "defmodule App do end")
    File.write!(Path.join(Path.join(Path.join(root, "lib"), "web"), "router.ex"), "defmodule Router do end")
    File.write!(Path.join(Path.join(root, "test"), "test_helper.exs"), "ExUnit.start()")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  test "project_tree returns top-level files and dirs", %{root: root} do
    tree = ProjectRules.project_tree(root, 2)

    assert tree =~ "PROJECT TREE"
    assert tree =~ "lib/"
    assert tree =~ "test/"
    assert tree =~ "mix.exs"
    assert tree =~ "README.md"
  end

  test "project_tree respects depth parameter", %{root: root} do
    tree = ProjectRules.project_tree(root, 1)

    assert tree =~ "lib/"
    refute tree =~ "  web/"  # depth 2 would show this
  end

  test "project_tree ignores ignored dirs", %{root: root} do
    tree = ProjectRules.project_tree(root, 3)

    refute tree =~ "_build/"
    refute tree =~ "deps/"
    refute tree =~ "node_modules/"
    refute tree =~ ".git/"
    refute tree =~ ".elixir_ls/"
  end

  test "project_tree does not ignore .ella", %{root: root} do
    tree = ProjectRules.project_tree(root, 3)

    assert tree =~ ".ella/"
  end

  test "project_tree returns empty for non-existent dir" do
    tree = ProjectRules.project_tree("/non/existent/path", 2)
    assert tree =~ "PROJECT TREE"
    assert tree =~ ""
  end
end