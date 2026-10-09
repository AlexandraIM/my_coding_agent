defmodule Ella do
  def start_cli do
    Owl.IO.puts(Owl.Data.tag("=== Привіт це Ella, твій кодінг партнер! ===", :magenta))

    Owl.IO.puts(
      "Commands: /plan (Switch to Plan Mode), /build (Switch to Build Mode), /mcp <npx/uvx/exec> <args> exit"
    )

    {:ok, pid} = Ella.Agent.start_link(mode: :plan)
    loop(pid)
  end

  defp loop(pid) do
    input = Owl.IO.input(label: "You") |> String.trim()

    cond do
      input == "/exit" ->
        Owl.IO.puts("Бувай, повертайся!")

      input == "/plan" ->
        Ella.Agent.set_mode(pid, :plan)
        loop(pid)

      input == "/build" || input == "/execute" ->
        Ella.Agent.set_mode(pid, :build)
        loop(pid)

      String.starts_with?(input, "/mcp ") ->
        cmd_str = String.replace_prefix(input, "/mcp ", "")

        case String.split(cmd_str, " ", trim: true) do
          [exec | args] ->
            Ella.Agent.register_mcp(pid, exec, args)

          _ ->
            Owl.IO.puts("Usage: /mcp <executable> [args...]")
        end

        loop(pid)

      input == "" ->
        loop(pid)

      true ->
        Ella.Agent.ask(pid, input)
        loop(pid)
    end
  end
end
