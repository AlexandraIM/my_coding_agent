defmodule Ella.SkillsTest do
  use ExUnit.Case, async: false

  alias Ella.Skills

  describe "parse/1 — валідні навички" do
    test "читає name, description і тіло" do
      content = """
      ---
      name: Testing
      description: How to write tests
      ---
      Use `mix test`.
      Always use describe blocks.
      """

      assert {:ok, skill} = Skills.parse(content)
      assert skill.name == "Testing"
      assert skill.description == "How to write tests"
      assert skill.instructions =~ "mix test"
      assert skill.instructions =~ "describe blocks"
      refute skill.instructions =~ "---"
    end

    test "name необов'язковий" do
      content = """
      ---
      description: No name here
      ---
      Body
      """

      assert {:ok, skill} = Skills.parse(content)
      assert skill.name == nil
      assert skill.description == "No name here"
    end

    test "обрізає пробіли в description" do
      content = """
      ---
      description:    spaced out
      ---
      Body
      """

      assert {:ok, %Skills{description: "spaced out"}} = Skills.parse(content)
    end

    test "знімає лапки" do
      content = """
      ---
      description: "Quoted: with colon"
      ---
      Body
      """

      assert {:ok, %Skills{description: "Quoted: with colon"}} = Skills.parse(content)
    end

    test "підтримує CRLF" do
      content = "---\r\ndescription: CRLF skill\r\n---\r\nBody here\r\n"

      assert {:ok, skill} = Skills.parse(content)
      assert skill.description == "CRLF skill"
      assert skill.instructions =~ "Body here"
    end

    test "ігнорує коментарі у frontmatter" do
      content = """
      ---
      # a comment
      description: With comments
      ---
      Body
      """

      assert {:ok, %Skills{description: "With comments"}} = Skills.parse(content)
    end
  end

  describe "parse/1 — інструменти" do
    test "читає tools як список у дужках" do
      content = """
      ---
      description: Restricted
      tools: [read_file, grep]
      ---
      Body
      """

      assert {:ok, skill} = Skills.parse(content)
      assert skill.allowed_tools == ["read_file", "grep"]
    end

    test "читає tools списком у рядках" do
      content = """
      ---
      description: Restricted
      tools:
        - read_file
        - grep
      ---
      Body
      """

      assert {:ok, skill} = Skills.parse(content)
      assert skill.allowed_tools == ["read_file", "grep"]
    end

    test "відсутність tools означає необмеженість" do
      content = """
      ---
      description: Free
      ---
      Body
      """

      assert {:ok, %Skills{allowed_tools: nil}} = Skills.parse(content)
    end
  end

  describe "parse/1 — помилки" do
    test "відхиляє файл без frontmatter" do
      assert {:error, reason} = Skills.parse("# Just markdown")
      assert reason =~ "frontmatter"
    end

    test "відхиляє навичку без description" do
      assert {:error, reason} = Skills.parse("---\nname: X\n---\nBody")
      assert reason =~ "description"
    end
  end

  describe "find/2 та exists?/2" do
    defp skill(name, tools \\ nil) do
      %Skills{name: name, description: "d", instructions: "i", allowed_tools: tools}
    end

    test "знаходить за точним ім'ям" do
      skills = [skill("Testing"), skill("Style")]

      assert {:ok, %Skills{name: "Testing"}} = Skills.find(skills, "Testing")
    end

    test "не чутливий до регістру та пробілів" do
      skills = [skill("Testing Conventions")]

      assert {:ok, _} = Skills.find(skills, "  testing conventions ")
      assert {:ok, _} = Skills.find(skills, "TESTING CONVENTIONS")
    end

    test "повертає помилку для невідомої навички" do
      assert {:error, reason} = Skills.find([skill("A")], "B")
      assert reason =~ "No skill named"
    end

    test "exists? перевіряє наявність" do
      skills = [skill("A")]
      assert Skills.exists?(skills, "a")
      refute Skills.exists?(skills, "b")
    end
  end

  describe "allows?/2" do
    test "nil-навичка дозволяє все" do
      assert Skills.allows?(nil, "write_file")
    end

    test "навичка без обмежень дозволяє все" do
      assert Skills.allows?(%Skills{allowed_tools: nil}, "write_file")
    end

    test "обмежена навичка дозволяє лише перелічені" do
      skill = %Skills{allowed_tools: ["read_file", "grep"]}

      assert Skills.allows?(skill, "read_file")
      assert Skills.allows?(skill, "grep")
      refute Skills.allows?(skill, "write_file")
    end
  end

  describe "catalog/1 та render/1" do
    test "каталог містить лише назву й опис, без інструкцій" do
      skills = [
        %Skills{name: "Testing", description: "How to test", instructions: "SECRET BODY"}
      ]

      catalog = Skills.catalog(skills)

      assert catalog =~ "Testing"
      assert catalog =~ "How to test"
      assert catalog =~ "load_skill"
      refute catalog =~ "SECRET BODY"
    end

    test "порожній каталог — порожній рядок" do
      assert Skills.catalog([]) == ""
    end

    test "render повертає повний текст" do
      skill = %Skills{name: "Testing", description: "d", instructions: "DO THIS"}

      rendered = Skills.render(skill)

      assert rendered =~ "Testing"
      assert rendered =~ "DO THIS"
    end

    test "render згадує обмеження інструментів" do
      skill = %Skills{
        name: "S",
        description: "d",
        instructions: "i",
        allowed_tools: ["read_file"]
      }

      rendered = Skills.render(skill)

      assert rendered =~ "ONLY use"
      assert rendered =~ "read_file"
    end
  end

  describe "load_all/0 — пріоритет джерел" do
    setup do
      root = Path.join(System.tmp_dir!(), "ella_skills_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, ".ella/skills"))
      File.mkdir_p!(Path.join(root, "global_skills"))

      previous_sandbox = Application.get_env(:ella, :sandbox_root)
      previous_global = Application.get_env(:ella, :global_skills_dir)
      previous_seed = Application.get_env(:ella, :seed_default_skills)
      Application.put_env(:ella, :sandbox_root, root)
      Application.put_env(:ella, :global_skills_dir, Path.join(root, "global_skills"))
      # Disable seeding to isolate tests from global skill seeding
      Application.put_env(:ella, :seed_default_skills, false)

      on_exit(fn ->
        File.rm_rf(root)

        if is_nil(previous_sandbox) do
          Application.delete_env(:ella, :sandbox_root)
        else
          Application.put_env(:ella, :sandbox_root, previous_sandbox)
        end

        if is_nil(previous_global) do
          Application.delete_env(:ella, :global_skills_dir)
        else
          Application.put_env(:ella, :global_skills_dir, previous_global)
        end

        if is_nil(previous_seed) do
          Application.delete_env(:ella, :seed_default_skills)
        else
          Application.put_env(:ella, :seed_default_skills, previous_seed)
        end
      end)

      {:ok, skills_dir: Path.join(root, ".ella/skills")}
    end

    test "читає навички з проєкту", %{skills_dir: dir} do
      File.write!(Path.join(dir, "testing.md"), """
      ---
      name: Testing
      description: Project testing rules
      ---
      Run mix test.
      """)

      skills = Skills.load_all()

      assert [%Skills{name: "Testing", scope: :project}] = skills
      assert hd(skills).instructions =~ "mix test"
    end

    test "пропускає биті файли, не ламаючи решту", %{skills_dir: dir} do
      File.write!(Path.join(dir, "good.md"), "---\ndescription: Fine\n---\nBody")
      File.write!(Path.join(dir, "broken.md"), "no frontmatter at all")

      skills = Skills.load_all()

      assert [%Skills{name: "good"} = skill] = skills
      assert skill.description == "Fine"
    end

    test "ігнорує файли не .md", %{skills_dir: dir} do
      File.write!(Path.join(dir, "note.txt"), "just text")
      File.write!(Path.join(dir, "skill.json"), ~s({"description": "nope"}))

      assert Skills.load_all() == []
    end

    test "ім'я за замовчуванням береться з імені файлу", %{skills_dir: dir} do
      File.write!(Path.join(dir, "code_style.md"), "---\ndescription: d\n---\nBody")

      assert [%Skills{name: "code style"}] = Skills.load_all()
    end

    test "порожня директорія дає порожній список", %{skills_dir: skills_dir} do
      # Ensure both project and global skills dirs are empty
      assert File.ls(skills_dir) == {:ok, []}
      global_dir = Application.get_env(:ella, :global_skills_dir)
      assert File.ls(global_dir) == {:ok, []}

      assert Skills.load_all() == []
    end
  end
end
