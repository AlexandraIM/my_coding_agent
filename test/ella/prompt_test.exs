defmodule Ella.PromptTest do
  use ExUnit.Case, async: true

  alias Ella.Prompt

  describe "build/3 — структура" do
    test "обидва режими містять усі секції промпту" do
      for mode <- [:plan, :build] do
        prompt = Prompt.build(mode, "", "")

        assert prompt =~ "## Tools"
        assert prompt =~ "## Working process"
        assert prompt =~ "## Output format"
      end
    end

    test "правила проєкту додаються в кінець" do
      prompt = Prompt.build(:build, "\nPROJECT RULES HERE\n", "\nSKILLS HERE\n")

      assert prompt =~ "STRICT RULES"
      assert prompt =~ "PROJECT RULES HERE"
      assert prompt =~ "SKILLS HERE"
    end

    test "start_cli мову відповіді зазначає явно" do
      assert Prompt.build(:plan, "", "") =~ "language they used"
    end
  end

  describe "build/3 — режими відрізняються інструментами" do
    test "plan не пропонує інструментів зміни стану" do
      prompt = Prompt.build(:plan, "", "")

      refute prompt =~ "write_file"
      refute prompt =~ "apply_patch"
    end

    test "build описує apply_patch і системну підказку" do
      prompt = Prompt.build(:build, "", "")

      assert prompt =~ "apply_patch"
      assert prompt =~ "write_file"
      assert prompt =~ "/rewind"
    end
  end
end
