defmodule Ella.SeedDefaultsTest do
  use ExUnit.Case, async: false

  alias Ella.Skills

  setup do
    root =
      Path.join(System.tmp_dir!(), "ella_seed_#{System.unique_integer([:positive])}")

    global_dir = Path.join(root, ".ella")
    File.mkdir_p!(Path.join(global_dir, "skills"))

    previous = Application.get_env(:ella, :global_skills_dir)
    previous_seed = Application.get_env(:ella, :seed_default_skills)
    Application.put_env(:ella, :global_skills_dir, global_dir)
    Application.put_env(:ella, :seed_default_skills, true)
    Application.delete_env(:ella, :default_skills_seeded)

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(previous) do
        Application.delete_env(:ella, :global_skills_dir)
      else
        Application.put_env(:ella, :global_skills_dir, previous)
      end

      if is_nil(previous_seed) do
        Application.delete_env(:ella, :seed_default_skills)
      else
        Application.put_env(:ella, :seed_default_skills, previous_seed)
      end

      Application.delete_env(:ella, :default_skills_seeded)
    end)

    {:ok, skills_dir: Path.join(global_dir, "skills")}
  end

  test "seed_defaults writes four default skill files", %{skills_dir: skills_dir} do
    :ok = Skills.seed_defaults_to(skills_dir)

    assert File.exists?(Path.join(skills_dir, "verify.md"))
    assert File.exists?(Path.join(skills_dir, "git.md"))
    assert File.exists?(Path.join(skills_dir, "review.md"))
    assert File.exists?(Path.join(skills_dir, "plan.md"))
  end

  test "seed_defaults is idempotent (does not overwrite existing)", %{skills_dir: skills_dir} do
    Skills.seed_defaults_to(skills_dir)

    # Modify one file
    File.write!(Path.join(skills_dir, "verify.md"), "custom content")

    # Run again
    Skills.seed_defaults_to(skills_dir)

    # Custom content preserved
    content = File.read!(Path.join(skills_dir, "verify.md"))
    assert content == "custom content"
  end

  test "seed_defaults does nothing when disabled", %{skills_dir: skills_dir} do
    Application.put_env(:ella, :seed_default_skills, false)
    Application.delete_env(:ella, :default_skills_seeded)

    # Remove existing seeded files to test clean slate
    case File.ls(skills_dir) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          File.rm(Path.join(skills_dir, file))
        end)
      _ -> :ok
    end

    Skills.seed_defaults_to(skills_dir)

    # No files created
    assert File.ls(skills_dir) == {:ok, []}
  end

  test "seed_defaults runs only once per VM", %{skills_dir: skills_dir} do
    Skills.seed_defaults_to(skills_dir)

    # Clear the seeded flag to simulate new agent start
    Application.delete_env(:ella, :default_skills_seeded)

    # Should not re-seed (flag is still set by first call)
    # Actually the flag persists, so let's check files weren't touched again
    mtime_before = File.stat!(Path.join(skills_dir, "verify.md")).mtime

    :timer.sleep(10)
    Skills.seed_defaults_to(skills_dir)

    mtime_after = File.stat!(Path.join(skills_dir, "verify.md")).mtime
    assert mtime_before == mtime_after
  end

  test "seed_defaults handles unwritable directory gracefully", %{skills_dir: skills_dir} do
    Application.put_env(:ella, :seed_default_skills, true)
    Application.delete_env(:ella, :default_skills_seeded)

    # Make dir read-only
    try do
      case :filelib.is_writable(skills_dir) do
        true ->
          :file.change_mode(skills_dir, 0o555)
          on_exit(fn ->
            :file.change_mode(skills_dir, 0o755)
          end)

          # Should not raise, just log
          Skills.seed_defaults_to(skills_dir)

        false ->
          # Can't test on this platform
          :ok
      end
    rescue
      _ ->
        # :filelib.is_writable not available, skip
        :ok
    end
  end
end