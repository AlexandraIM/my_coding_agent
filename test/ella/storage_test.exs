defmodule Ella.StorageTest do
  use ExUnit.Case, async: false

  alias Ella.Storage

  setup do
    root =
      Path.join(System.tmp_dir!(), "ella_storage_#{System.unique_integer([:positive])}")

    previous = Application.get_env(:ella, :storage_dir)
    Application.put_env(:ella, :storage_dir, root)

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(previous) do
        Application.delete_env(:ella, :storage_dir)
      else
        Application.put_env(:ella, :storage_dir, previous)
      end
    end)

    :ok
  end

  test "ensure_storage_created! creates sessions dir" do
    Storage.ensure_storage_created!()
    assert File.dir?(Storage.sessions_dir())
  end

  test "save and load session round-trip" do
    usage = %Ella.Llm.Usage{prompt_tokens: 10, completion_tokens: 5, model: "gpt-4o", cost: 0.001}

    data = %{
      mode: :build,
      messages: [%{"role" => "user", "content" => "hi"}],
      usage: usage
    }

    assert {:ok, path} = Storage.save_session("my session", data)
    assert File.exists?(path)

    assert {:ok, loaded} = Storage.load_session("my session")
    assert loaded.mode == :build
    assert loaded.messages == [%{"role" => "user", "content" => "hi"}]
    assert loaded.usage.prompt_tokens == 10
    assert loaded.usage.model == "gpt-4o"
  end

  test "load missing session returns not_found" do
    assert {:error, :not_found} = Storage.load_session("nope")
  end

  test "list_sessions returns saved names" do
    Storage.save_session("a", %{mode: :plan, messages: [], usage: nil})
    Storage.save_session("b", %{mode: :plan, messages: [], usage: nil})

    assert Enum.sort(Storage.list_sessions()) == ["a", "b"]
  end

  test "delete_session removes file" do
    Storage.save_session("tmp", %{mode: :plan, messages: [], usage: nil})
    assert :ok = Storage.delete_session("tmp")
    assert {:error, :not_found} = Storage.load_session("tmp")
  end
end
