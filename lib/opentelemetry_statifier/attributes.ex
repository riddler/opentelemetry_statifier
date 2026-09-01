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

  ## Namespaces

  The `statifier.` namespace above is the *default* mapping, not the only
  one. A sibling family's events map under the sibling package's own
  namespace - `statifier_persistence.`, `statifier_oban.` - with the
  correlation key aliased onto the shared `statifier.session_id`, so one
  attribute joins a step, a timer and a macrostep across all three
  families. `mapping/0` and `mapping/2` build those, and every rule above
  applies unchanged inside whichever namespace is in force
  (`docs/adr/0004-sibling-setup-calls-and-bridge-owned-nesting.md`).
  """

  alias OpentelemetryStatifier.Config
  alias Statifier.Parser.Location

  @never_serialized [:effect, :span_ref]
  @datamodel_value_keys [:new_value, :prior_value, :datamodel]

  @typedoc """
  How one event family's keys become attribute names: a namespace
  `prefix`, per-key `aliases` that win over it (a full attribute name,
  not a prefix), and `drop`ped keys that never become attributes at all.
  """
  @type mapping :: %{
          prefix: String.t(),
          aliases: %{atom() => String.t()},
          drop: [atom()]
        }

  @doc """
  The default `statifier.` mapping, used for the
  `[:statifier, :session, ...]` family.
  """
  @spec mapping() :: mapping()
  def mapping, do: mapping("statifier", %{})

  @doc """
  A mapping under `prefix` with `aliases`. `caller_context` is dropped in
  every mapping this builds: it is an opaque host term the bridge *uses*
  (to link) and never flattens into attributes, a rule both sibling
  contracts state as explicitly as the design note states it for the
  interpreter family.
  """
  @spec mapping(String.t(), %{atom() => String.t()}) :: mapping()
  def mapping(prefix, aliases) when is_binary(prefix) and is_map(aliases) do
    %{prefix: prefix, aliases: aliases, drop: @never_serialized ++ [:caller_context]}
  end

  @doc """
  Maps one event's `measurements` and `metadata` into span-event
  attributes under the rules above, honoring `config`'s
  `record_datamodel_values` opt-in.
  """
  @spec span_event_attributes(map(), map(), Config.t()) :: map()
  def span_event_attributes(measurements, metadata, %Config{} = config),
    do: span_event_attributes(measurements, metadata, config, mapping())

  @doc """
  `span_event_attributes/3` under an explicit `mapping/2`.
  """
  @spec span_event_attributes(map(), map(), Config.t(), mapping()) :: map()
  def span_event_attributes(measurements, metadata, %Config{} = config, mapping)
      when is_map(measurements) and is_map(metadata) do
    Map.merge(
      from_measurements(measurements, mapping),
      from_metadata(metadata, config, mapping)
    )
  end

  @spec name(mapping(), atom() | String.t()) :: String.t()
  defp name(%{prefix: prefix, aliases: aliases}, key) do
    case Map.fetch(aliases, key) do
      {:ok, alias_name} -> alias_name
      :error -> "#{prefix}.#{key}"
    end
  end

  @spec from_measurements(map(), mapping()) :: map()
  defp from_measurements(measurements, mapping) do
    for {key, value} <- measurements,
        is_atom(key) and is_number(value) and key not in mapping.drop,
        into: %{} do
      {name(mapping, key), value}
    end
  end

  @spec from_metadata(map(), Config.t(), mapping()) :: map()
  defp from_metadata(metadata, config, mapping) do
    Enum.reduce(metadata, %{}, fn
      {key, value}, acc when is_atom(key) -> put_metadata(acc, key, value, config, mapping)
      {_key, _value}, acc -> acc
    end)
  end

  # `nil` before every shape clause: an absent attribute is cleaner than a
  # "nil" string, matching the macrostep span's own `event_name` handling.
  @spec put_metadata(map(), atom(), term(), Config.t(), mapping()) :: map()
  defp put_metadata(acc, _key, nil, _config, _mapping), do: acc

  defp put_metadata(acc, key, value, config, mapping) do
    cond do
      key in mapping.drop -> acc
      key in @datamodel_value_keys -> put_datamodel_value(acc, key, value, config, mapping)
      true -> put_kept_metadata(acc, key, value, mapping)
    end
  end

  @spec put_datamodel_value(map(), atom(), term(), Config.t(), mapping()) :: map()
  defp put_datamodel_value(acc, key, value, %Config{record_datamodel_values: true}, mapping),
    do: Map.put(acc, name(mapping, key), inspect(value))

  defp put_datamodel_value(acc, _key, _value, %Config{}, _mapping), do: acc

  @spec put_kept_metadata(map(), atom(), term(), mapping()) :: map()
  defp put_kept_metadata(
         acc,
         :location,
         %Location{start_line: line, start_column: column},
         mapping
       )
       when is_integer(line) and is_integer(column) do
    acc
    |> Map.put(name(mapping, "source.line"), line)
    |> Map.put(name(mapping, "source.column"), column)
  end

  defp put_kept_metadata(acc, :configuration, %MapSet{} = configuration, mapping) do
    Map.put(
      acc,
      name(mapping, :configuration),
      configuration |> MapSet.to_list() |> Enum.sort()
    )
  end

  defp put_kept_metadata(acc, key, value, mapping),
    do: put_scalar(acc, name(mapping, key), value)

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
