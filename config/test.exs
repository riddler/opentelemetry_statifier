import Config

# The SDK is a test-only dependency; export nothing. Tests that assert on
# spans attach their own in-process exporter.
config :opentelemetry, traces_exporter: :none
