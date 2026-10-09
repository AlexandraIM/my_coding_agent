defmodule Ella.GlobTest do
  use ExUnit.Case, async: true

  alias Ella.Glob

  describe "match?/2 — базові шаблони" do
    test "точний шлях" do
      assert Glob.match?("lib/ella.ex", "lib/ella.ex")
      refute Glob.match?("lib/ella.exs", "lib/ella.ex")
    end

    test "* не переходить через слеш" do
      assert Glob.match?("lib/ella.ex", "lib/*.ex")
      refute Glob.match?("lib/ella/tool.ex", "lib/*.ex")
    end

    test "? збігається з одним символом" do
      assert Glob.match?("a.ex", "?.ex")
      refute Glob.match?("ab.ex", "?.ex")
    end

    test "** збігається з нулем директорій" do
      assert Glob.match?("lib/ella.ex", "lib/**/*.ex")
    end

    test "** збігається з кількома директоріями" do
      assert Glob.match?("lib/a/b/c/ella.ex", "lib/**/*.ex")
    end

    test "** наприкінці збігається з усім" do
      assert Glob.match?("lib/a/b.ex", "lib/**")
      assert Glob.match?("lib/a.ex", "lib/**")
    end

    test "префікс без ** вимагає точного шляху" do
      assert Glob.match?("mix.exs", "*.exs")
      refute Glob.match?("lib/mix.exs", "*.exs")
    end
  end

  describe "match?/2 — фігурні дужки та класи" do
    test "{a,b} задає альтернативи" do
      assert Glob.match?("lib/ella.ex", "lib/{ella,glob}.ex")
      assert Glob.match?("lib/glob.ex", "lib/{ella,glob}.ex")
      refute Glob.match?("lib/other.ex", "lib/{ella,glob}.ex")
    end

    test "кілька альтернатив разом із **" do
      assert Glob.match?("test/ella/agent_test.exs", "**/{agent,glob}_test.exs")
      refute Glob.match?("test/ella/tool_test.exs", "**/{agent,glob}_test.exs")
    end

    test "вкладені дужки не ламають парсинг" do
      assert Glob.match?("x.ex", "{a,{b,x}}.ex")
    end

    test "[abc] — клас символів" do
      assert Glob.match?("a.ex", "[abc].ex")
      refute Glob.match?("d.ex", "[abc].ex")
    end

    test "[!abc] — заперечення в класі" do
      assert Glob.match?("d.ex", "[!abc].ex")
      refute Glob.match?("a.ex", "[!abc].ex")
    end
  end

  describe "to_regex/1" do
    test "повертає {:ok, regex} для валідного шаблону" do
      assert {:ok, regex} = Glob.to_regex("lib/**/*.ex")
      assert is_struct(regex, Regex)
    end

    test "екранує regex-спецсимволи у літеральних частинах" do
      # Точка має бути літеральною, а не " будь-який символ
      refute Glob.match?("libXella.ex", "lib.ella.ex")
      assert Glob.match?("lib.ella.ex", "lib.ella.ex")
    end
  end
end
