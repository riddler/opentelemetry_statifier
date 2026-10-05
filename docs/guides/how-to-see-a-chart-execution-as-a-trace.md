# How to see a chart execution as a trace

This guide shows you how to find one chart execution in your tracing backend
and follow it from its first macrostep to its last. You start from a host that
already runs the `opentelemetry` SDK with an exporter, has
`opentelemetry_statifier` in its dependencies, and executes the library loan
chart from the README's [Basic usage](../../README.md#basic-usage): a copy of a
book checked out to a patron, renewed once, and returned.

1. Attach the bridge in your application's `start/2`, after the SDK has
   started:

   ```elixir
   :ok = OpentelemetryStatifier.setup()
   ```

   `:telemetry.list_handlers([:statifier, :session, :macrostep])` now lists
   handlers whose ids begin with `OpentelemetryStatifier`.

2. Start each loan's session under an id you can search for:

   ```elixir
   {:ok, session} = Statifier.Session.start_link(machine, session_id: "loan_42")
   ```

   Every span the execution exports carries `statifier.session_id` set to
   `"loan_42"`.

3. Deliver the loan's events as your host already does, then search your
   backend for spans whose `statifier.session_id` is `loan_42`.

   You see four spans named `statifier.macrostep`, each the root of its own
   trace, numbered 1 to 4 by their `statifier.macrostep` attribute.

4. Open the span whose `statifier.outcome` is `done` and follow its link.

   The link leads to macrostep 3, whose `statifier.event_name` is
   `loan.renewed`; each span's link leads to the one before it, and
   macrostep 1, whose `statifier.trigger` is `initialize`, has no link.

5. Open the span events of macrostep 2, the one whose `statifier.event_name`
   is `loan.checked_out`.

   A `statifier.effect.log` event carries `statifier.source.line` 7, the line
   of the `<log>` element in the chart.

6. If another chart invoked this execution, open this execution's macrostep 1.

   It carries a link to the invoking chart's macrostep span, which you follow
   the same way.

For every attribute a span or span event can carry, see
[the attribute mapping](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Attributes.html).
