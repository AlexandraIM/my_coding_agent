defmodule Ella.ErtsResolver do
  @moduledoc """
  Burrito-резолвер, що бере ERTS із встановленого Erlang.

  За замовчуванням Burrito завантажує готовий ERTS з beam-machine.
  Для конкретної версії OTP такої збірки може не існувати — і тоді
  збірка падає на 404, навіть якщо ERTS цієї версії стоїть у машині
  розробника.

  `:runtime` робить збірку самодостатньою: бінарник містить ту ERTS,
  з якою його збирали. Плата — він гарантовано працює лише на тих
  платформах, де його збирали. Для справжнього крос-збору приберіть
  `custom_erts` із цілей у `mix.exs`.
  """

  @behaviour Burrito.Util.ERTSResolver

  @impl true
  def do_resolve(%Burrito.Builder.Target{} = target) do
    # :runtime змушує Burrito взяти ERTS з тієї машини, де йде
    # збірка, замість завантаження готової.
    %Burrito.Builder.Target{target | erts_source: {:runtime, :current_erts}}
  end
end
