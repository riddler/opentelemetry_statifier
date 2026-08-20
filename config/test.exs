import Config

# The SDK is a test-only dependency; export nothing by default. Tests that
# assert on spans attach their own in-process exporter
# (test/support/span_capture.ex) via `:otel_simple_processor.set_exporter/2`,
# which needs a processor configured to attach an exporter to in the first
# place - `:otel_simple_processor` exports synchronously, which is what lets
# a test `assert_receive` right after the code under test returns.
config :opentelemetry, traces_exporter: :none
config :opentelemetry, processors: [{:otel_simple_processor, %{}}]
