import Config

if Mix.env() == :test do
  config :ash, default_string_length_count: :codepoints
  config :ash, disable_async?: true
  config :logger, level: :warning
end
