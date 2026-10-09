defmodule Ella.ToolTest do
  use ExUnit.Case, async: true

  alias Ella.Tool

  describe "parse_args/1" do
    test "повертає розібрану мапу для валідного JSON-об'єкта" do
      assert {:ok, %{"path" => "lib/ella.ex"}} = Tool.parse_args(~s({"path":"lib/ella.ex"}))
    end

    test "повертає помилку замість винятку на невалідному JSON" do
      assert {:error, reason} = Tool.parse_args("{not json")
      assert reason =~ "Invalid JSON"
    end

    test "відхиляє валідний, але не-об'єктний JSON" do
      assert {:error, reason} = Tool.parse_args("[1, 2, 3]")
      assert reason =~ "must be a JSON object"
    end

    test "відхиляє не-рядкові аргументи" do
      assert {:error, reason} = Tool.parse_args(%{"already" => "decoded"})
      assert reason =~ "must be a JSON string"
    end

    test "порожній об'єкт є валідним набором аргументів" do
      assert {:ok, %{}} = Tool.parse_args("{}")
    end
  end

  describe "to_schema/1" do
    test "будує OpenAI-сумісну схему інструмента" do
      schema = Tool.to_schema(Ella.Tools.ReadFile)

      assert schema["type"] == "function"
      assert schema["function"]["name"] == "read_file"
      assert schema["function"]["parameters"]["required"] == ["path"]
    end
  end

  describe "max_iterations/0" do
    test "є додатним цілим числом" do
      assert is_integer(Tool.max_iterations())
      assert Tool.max_iterations() > 0
    end
  end
end
