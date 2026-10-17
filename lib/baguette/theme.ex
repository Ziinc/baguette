defmodule Baguette.Theme do
  @moduledoc """
  Theme tokens, named in classes as `bg-<token>`, `text-<token>` and
  `border-<token>`.

      defmodule MyApp.Theme do
        use Baguette.Theme

        token :primary, light: "#2563eb", dark: "#3b82f6"
        token :primary_foreground, "#ffffff"
      end

  Token names use underscores in Elixir and dashes in classes
  (`text-primary-foreground`).
  """

  defmacro __using__(_opts) do
    quote do
      import Baguette.Theme, only: [token: 2]
      Module.register_attribute(__MODULE__, :baguette_tokens, accumulate: true)
      @before_compile Baguette.Theme
    end
  end

  @doc "Defines a token: one colour, or one per appearance (`light:`, `dark:`)."
  defmacro token(name, value) do
    quote do
      @baguette_tokens {unquote(name), Baguette.Theme.__values__(unquote(value))}
    end
  end

  @doc false
  def __values__(value) when is_binary(value), do: %{light: value, dark: value}
  def __values__(values) when is_list(values), do: Map.new(values)

  defmacro __before_compile__(env) do
    tokens = Module.get_attribute(env.module, :baguette_tokens)

    quote do
      @doc "The tokens for `appearance`, keyed by class name."
      def tokens(appearance \\ :light) do
        for {name, values} <- unquote(Macro.escape(tokens)), into: %{} do
          {name |> Atom.to_string() |> String.replace("_", "-"), Map.fetch!(values, appearance)}
        end
      end
    end
  end
end
