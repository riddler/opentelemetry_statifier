defmodule OpentelemetryStatifier.Config do
  @moduledoc """
  The validated result of `OpentelemetryStatifier.setup/1`'s options,
  carried through `:telemetry.attach/4` as the handler `Config` argument
  (the family's unanimous pattern for setup-time options - see the plan's
  Key Discoveries).

  Two keys are recognised:

    * `:record_datamodel_values` - defaults to `false`. Parsed and carried
      here; not yet read anywhere (`ots-j82` reads it once the datamodel
      effect events are mapped).
    * `:table` - the ETS table name the handler reads and writes against.
      Defaults to `OpentelemetryStatifier.SpanTable`, the module name
      standing in for the table name until Phase 2 gives that name a real
      table.

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
