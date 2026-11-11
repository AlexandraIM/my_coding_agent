defmodule Ella.OutputTest do
  use ExUnit.Case, async: false

  alias Ella.Output

  setup do
    Output.reset_sink()
    on_exit(fn -> Output.reset_sink() end)
    :ok
  end

  describe "sink/0" do
    test "defaults to :stdio" do
      assert Output.sink() == :stdio
    end

    test "set_sink/1 and reset_sink/0" do
      Output.set_sink({:tui, self()})
      assert Output.sink() == {:tui, self()}
      Output.reset_sink()
      assert Output.sink() == :stdio
    end
  end

  describe "puts/1 in tui mode" do
    test "sends {:output, text} to the sink pid" do
      Output.set_sink({:tui, self()})
      Output.puts("hello world")
      assert_receive {:output, "hello world"}, 500
    end

    test "converts tagged values to plain text" do
      Output.set_sink({:tui, self()})
      Output.puts(Output.tag("colored", :red))
      # In tui mode tag returns plain text
      assert_receive {:output, "colored"}, 500
    end

    test "handles list messages" do
      Output.set_sink({:tui, self()})
      Output.puts(["a", "b"])
      assert_receive {:output, "ab"}, 500
    end
  end

  describe "blank/0" do
    test "sends empty string" do
      Output.set_sink({:tui, self()})
      Output.blank()
      assert_receive {:output, ""}, 500
    end
  end

  describe "tag/2" do
    test "returns Owl.Tag in stdio mode" do
      assert %Owl.Tag{} = Output.tag("x", :red)
    end

    test "returns plain binary in tui mode" do
      Output.set_sink({:tui, self()})
      assert Output.tag("x", :red) == "x"
    end
  end

  describe "to_text/1" do
    test "binary" do
      assert Output.to_text("abc") == "abc"
    end

    test "Owl.Tag" do
      assert Output.to_text(Owl.Data.tag("hi", :green)) == "hi"
    end

    test "list" do
      assert Output.to_text(["a", "b"]) == "ab"
    end
  end
end
