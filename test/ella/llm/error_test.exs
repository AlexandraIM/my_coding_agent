defmodule Ella.Llm.ErrorTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.Error

  test "transient помилка придатна до повтору" do
    error = Error.transient("rate limited")
    assert Error.retryable?(error)
    assert Error.message(error) == "rate limited"
  end

  test "permanent помилка не повторюється" do
    error = Error.permanent("bad key", status: 401)
    refute Error.retryable?(error)
    assert error.status == 401
  end

  test "retry_after_ms зберігається" do
    error = Error.transient("429", retry_after_ms: 2_000)
    assert error.retry_after_ms == 2_000
  end

  test "старі помилки-рядки розпізнаються за змістом" do
    assert Error.retryable?("API error Status 429: too many")
    assert Error.retryable?("Network error: %Req.TransportError{}")
    refute Error.retryable?("API error Status 401: unauthorized")
  end

  test "невідомий тип вважається неповторним" do
    refute Error.retryable?({:weird, :tuple})
  end

  test "message приймає будь-яке значення" do
    assert Error.message(Error.permanent("x")) == "x"
    assert Error.message("plain") == "plain"
    assert Error.message(:atom) == ":atom"
  end
end
