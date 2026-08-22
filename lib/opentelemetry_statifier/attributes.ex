defmodule OpentelemetryStatifier.Attributes do
  @moduledoc """
  The uniform measurement/metadata-to-attribute mapping the design note
  (statifier-ex `docs/opentelemetry.md`, "Attribute mapping") fixes, applied
  to span events rather than re-decided per event name.

  Every attribute lands under the `statifier.` namespace. Measurements are
  numbers by contract and pass through as numeric attributes of the same
  name. Metadata is mapped by shape:

    * `:effect` is never serialized - the raw struct is for in-VM
      consumers; a wire format is where "the struct rides verbatim" stops
      being cheap.
    * `:location` (a `%Statifier.Parser.Location{}`) flattens to
      `statifier.source.line`/`statifier.source.column` - the one place
      the bridge flattens a struct, because OTel attributes are scalar.
    * `:configuration` (already state-id strings by the ADR-0040 contract)
      becomes a sorted string-array attribute, bounded by the chart's
      state count.
    * `:new_value`, `:prior_value`, and `:datamodel` are the unbounded
      datamodel values: excluded unless the host opted in at setup with
      `record_datamodel_values: true`, and rendered with `inspect/1` when
      it did - they are arbitrary terms, and `inspect/1` is the only
      rendering that needs no per-type policy.
    * everything else is identity metadata: strings and integers pass
      through, atoms become strings, tuples (an `owner`, chart vocabulary
      of bounded shape) render with `inspect/1`, `nil` is omitted rather
      than encoded, and any other shape is dropped - a malformed value
      costs one attribute, never the event.
  """

  alias OpentelemetryStatifier.Config
  alias Statifier.Parser.Location

  @never_serialized [:effect, :span_ref]
  @datamodel_value_keys [:new_value, :prior_value, :datamodel]

  @doc """
  Maps one event's `measurements` and `metadata` into span-event
  attributes under the rules above, honoring `config`'s
  `record_datamodel_values` opt-in.
  """
  @spec span_event_attributes(map(), map(), Config.t()) :: map()
  def span_event_attributes(measurements, metadata, %Config{} = config)
      when is_map(measurements) and is_map(metadata) do
    Map.merge(from_measurements(measurements), from_metadata(metadata, config))
  end

  @spec from_measurements(map()) :: map()
  defp from_measurements(measurements) do
    for {key, value} <- measurements, is_atom(key) and is_number(value), into: %{} do
      {"statifier.#{key}", value}
    end
  end

  @spec from_metadata(map(), Config.t()) :: map()
  defp from_metadata(metadata, config) do
    Enum.reduce(metadata, %{}, fn
      {key, value}, acc when is_atom(key) -> put_metadata(acc, key, value, config)
      {_key, _value}, acc -> acc
    end)
  end

  @spec put_metadata(map(), atom(), term(), Config.t()) :: map()
  defp put_metadata(acc, key, _value, _config) when key in @never_serialized, do: acc

  # `nil` before every shape clause: an absent attribute is cleaner than a
  # "nil" string, matching the macrostep span's own `event_name` handling.
  defp put_metadata(acc, _key, nil, _config), do: acc

  defp put_metadata(acc, :location, %Location{start_line: line, start_column: column}, _config)
       when is_integer(line) and is_integer(column) do
    acc
    |> Map.put("statifier.source.line", line)
    |> Map.put("statifier.source.column", column)
  end

  defp put_metadata(acc, :configuration, %MapSet{} = configuration, _config) do
    Map.put(
      acc,
      "statifier.configuration",
      configuration |> MapSet.to_list() |> Enum.sort()
    )
  end

  defp put_metadata(acc, key, value, %Config{record_datamodel_values: record?})
       when key in @datamodel_value_keys do
    if record? do
      Map.put(acc, "statifier.#{key}", inspect(value))
    else
      acc
    end
  end

  defp put_metadata(acc, key, value, _config), do: put_scalar(acc, "statifier.#{key}", value)

  @spec put_scalar(map(), String.t(), term()) :: map()
  defp put_scalar(acc, key, value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
       do: Map.put(acc, key, value)

  defp put_scalar(acc, key, value) when is_atom(value),
    do: Map.put(acc, key, Atom.to_string(value))

  defp put_scalar(acc, key, value) when is_tuple(value), do: Map.put(acc, key, inspect(value))

  # A shape the rules above do not name (a struct, a map, a list of terms,
  # a pid) is dropped: one lost attribute, never a raised handler.
  defp put_scalar(acc, _key, _value), do: acc
end
