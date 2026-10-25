defmodule Ella.BuildSteps.RegisterErtsResolver do
  @moduledoc """
  Крок збірки Burrito: реєструє `Ella.ErtsResolver`.

  Його не можна реєструвати в тілі `Ella.Application` — той код
  виконується лише під час компіляції модуля, а `Application.put_env`
  в процесі компілятора зникне разом із ним. Перша збірка після зміни
  файла працювала випадково; наступні, де перекомпілювати було нічого,
  тихо поверталися до стандартного резолвера і падали на 404.

  Крок виконується перед фазою `fetch`, тобто точно перед тим, як
  Burrito шукатиме ERTS.
  """

  @behaviour Burrito.Builder.Step

  @impl true
  def execute(%Burrito.Builder.Context{} = context) do
    Burrito.register_erts_resolver(Ella.ErtsResolver)
    context
  end
end
