defmodule OpentelemetryStatifier.Config do
  @moduledoc """
  The validated result of the options `OpentelemetryStatifier.setup/1`,
  `OpentelemetryStatifier.Persistence.setup/1` and
  `OpentelemetryStatifier.Oban.setup/1` take, carried through
  `:telemetry.attach/4` as each handler's `Config` argument (the family's
  pattern for setup-time options).

  Two keys are recognised:

    * `:record_datamodel_values` - defaults to `false`. When `true`,
      `OpentelemetryStatifier.Attributes` records the datamodel values an
      event carries (`:new_value`, `:prior_value` and `:datamodel`) as
      span-event attributes rendered with `inspect/1`; when `false`, they
      are left out.
    * `:table` - the name of the ETS span table the handlers read and
      write. Defaults to `OpentelemetryStatifier.SpanTable`, the named
      table the `OpentelemetryStatifier.SpanTable` process creates when the
      application starts and sweeps on a timer. Any other name must name a
      table that already exists, created with
      `OpentelemetryStatifier.SpanTable.new_table/1`; the timed sweep runs
      over the default table only.

  An unknown key is rejected rather than ignored: a typo'd
  `record_datamodel_value` silently doing nothing is exactly the failure
  the project's cardinality policy cannot afford.
  """

  @keys [:record_datamodel_values, :table]

  defstruct record_datamodel_values: false,
            table: OpentelemetryStatifier.SpanTable

  @type t :: %__MODULE__{
          record_datamodel_values: boolean(),
          table: atom()
        }

  @doc """
  Validates a keyword list of setup options into a `t()`.

  Returns `{:error, {:invalid_options, :not_a_keyword_list}}` when `opts` is
  not even a keyword list, `{:error, {:unknown_options, keys}}` when it
  contains keys outside `:record_datamodel_values`/`:table`, and
  `{:error, {:invalid_option, key, value}}` when a recognised key holds a
  value of the wrong shape.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- validate_keyword_list(opts),
         :ok <- validate_known_keys(opts),
         :ok <- validate_values(opts) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end

  def new(_opts), do: {:error, {:invalid_options, :not_a_keyword_list}}

  defp validate_keyword_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      {:error, {:invalid_options, :not_a_keyword_list}}
    end
  end

  defp validate_known_keys(opts) do
    case Keyword.keys(opts) -- @keys do
      [] -> :ok
      unknown -> {:error, {:unknown_options, unknown}}
    end
  end

  defp validate_values(opts) do
    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      if valid_value?(key, value) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_option, key, value}}}
      end
    end)
  end

  defp valid_value?(:record_datamodel_values, value), do: is_boolean(value)
  defp valid_value?(:table, value), do: is_atom(value) and value != nil
end
