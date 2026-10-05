# Why spans and links are shaped this way

A chart execution does not look like the work tracing was built for. A web
request starts, calls a few things and ends within a second; a library loan
starts when a copy of a book is checked out to a patron and ends when it is
returned or written off as lost, weeks later, with a renewal or two in
between. This page is about how the bridge fits an execution like that into
OpenTelemetry's model of spans, traces and links, and why it settled on the
shape it did rather than the more obvious ones.

## The unit is the macrostep

A chart moves only when something happens to it: the loan is checked out,
renewed, returned. The interpreter takes each such event to rest in one
macrostep, and the bridge makes each macrostep one span, named
`statifier.macrostep`. The loan in the README's
[Basic usage](../../README.md#basic-usage) exports four of them: the start,
the checkout, the renewal and the return.

Three other units were on the table, and each fails a loan in its own way.

A span per state reads naturally ("the copy was on loan from here to here"),
but a state is not where the work happens. The copy sits in `on_loan` for
three weeks doing nothing; the work is in the moments it changes state, and
a span for the quiet interval would be mostly empty time with the interesting
part squeezed into its edges.

A span for the whole execution has the opposite problem. It would open at
checkout and stay open until the return, and most tracing pipelines assume a
span ends within seconds or minutes: exporters buffer open spans in memory, a
backend may not show a trace until its root ends, and a sampler that dropped
that one root would drop the loan's entire history with it. The execution's
identity is still there on every span, as the `statifier.session_id`
attribute, so nothing is lost by not giving it a span of its own.

A span per microstep (each transition the interpreter fires inside a
macrostep) would be finer grained, but a microstep has no meaningful duration
of its own: it is a point in time, and the interval that matters is the
macrostep around it. So what happens inside a macrostep, a `<log>`, an
`<invoke>`, a datamodel write, and with tracing turned on each microstep's
detail, lands as span events on the macrostep's span. The timeline inside a
macrostep can be read off one span without a tree of children that each
lasted no time at all.

## One name, whatever the chart says

Every macrostep span has the same name. The event that triggered it
(`loan.renewed`), the trigger kind and the states the chart came to rest in
are attributes, not part of the name. Tracing backends group, index and price
by span name, and a chart's event and state names are its own vocabulary: a
bridge that put them in the name would hand every backend a new operation for
each event a chart could take, and the count would grow with every chart
anyone wrote. With one name, a backend sees one operation however large the
charts become, and the chart's vocabulary is still there to filter on.

The same caution shapes the attributes. A state id or an event name is
bounded by the chart, so it is safe to export. A datamodel value is not: the
patron's name, the copy's barcode, whatever the chart keeps, is bounded only
by the data. So a datamodel write lands as a span event that says which
location changed and where in the chart, and the values themselves stay out
unless the host asks for them when it attaches the bridge. The
[attribute mapping](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Attributes.html)
holds the full list.

## A trace per macrostep, held together by links

Each macrostep span is the root of its own trace, and it carries a link to
the same execution's previous macrostep span. The return links to the
renewal, the renewal to the checkout, the checkout to the start, and a
backend can walk the loan backwards from any point in it.

The alternative is to make each macrostep a child of the one before it, or
of one span for the execution, so the whole loan sits in one trace. That
reads well in a trace viewer, but a parent-child edge says something false
here: it says the child's time is contained in the parent's. The renewal does
not happen inside the checkout; the checkout was over weeks before. A link
says what is true, that one followed from the other, and it does not hold
anything open while the loan waits.

Sampling is the other reason. Because every macrostep is a root, a head
sampler keeps or drops whole macrosteps, never half of one, and a dropped
macrostep leaves its neighbours intact. A link that points at a macrostep the
sampler dropped is an ordinary dangling link, which backends are built to
show.

The same reasoning decides what happens when one chart invokes another. If
the loan chart invokes a check for holds on the copy before it goes out, the
invoked chart's first macrostep links to the loan's macrostep that started
it. Not a child: the invoked execution can outlive the macrostep that started
it, so the containment a parent edge promises would again be false.

## When a macrostep does have a parent

There is one case where nesting is the truth. A durable execution steps one
macrostep at a time inside a storage step that loads it, steps it and saves
it, and that step is a real interval that contains the macrostep. With the
persistence bridge attached, its `statifier_persistence.execution.step` span
is the macrostep span's parent, and a host running its own durable stepper
can declare its own step span as the parent through
[`OpentelemetryStatifier.Parent`](https://hexdocs.pm/opentelemetry_statifier/OpentelemetryStatifier.Parent.html).

What the bridge does not do is take whatever span happens to be current in
the process. That would have been the usual OpenTelemetry move, and the
simpler one, but a host with any unrelated span open at the moment a
macrostep starts, a request handler or a job, would capture every macrostep
into it, and "one trace per macrostep" would quietly stop being true for
everyone who had relied on it. So a parent is something this bridge opened
itself or something the host declared, never something it found, and the
bridge never changes the process's own context either.

## Time that passes between traces

A loan's due date is the clearest case of an execution reaching across time.
When the chart schedules a reminder for the due date and a job delivers it
three weeks later, the span for that delivery links back to the trace that
scheduled it, when the host stamped the scheduling trace into the event's
caller context. Again a link and not a parent: a parent would keep the
scheduling trace open for the whole three weeks. Without that stamp the
delivery span stands alone and is still joined to the loan by
`statifier.session_id`.

## The first span starts late

The first macrostep of an execution, the one that enters the initial state,
is the one place the shape shows a seam. The interpreter reports that
macrostep's start after some of its work is already done, so the span opens
late and its wall time reads shorter than the `statifier.duration` attribute
it carries. Every other macrostep's span brackets its work exactly.

The bridge could have back-dated every span from its end time and the
reported duration, which is how many OpenTelemetry bridges work. That would
fix the first span and make every other span an estimate, which is the wrong
trade for the one span that is off. So the skew is accepted, and
`statifier.duration` is the figure to trust for that span's cost.

## Where this leaves you

Reading a chart in a trace means reading a chain, not a tree: one trace per
macrostep, a short hop along a link to the one before, and
`statifier.session_id` to gather a whole execution when the links end.
[How to see a chart execution as a trace](../guides/how-to-see-a-chart-execution-as-a-trace.md)
follows one loan through that chain. The span design this package implements
is recorded in statifier-ex's
[OpenTelemetry design note](https://github.com/riddler/statifier-ex/blob/main/docs/opentelemetry.md),
and the choices made in this repository, the per-event handlers, the span
table and the nesting rules, are in
[the decision records](https://github.com/riddler/opentelemetry_statifier/tree/main/docs/adr).
