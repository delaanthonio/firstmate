require "yaml"

config = YAML.safe_load_file(ARGV.fetch(0), aliases: true)
abort "Polytoken config must be a mapping" unless config.is_a?(Hash)
config.delete("mcp_servers")
File.open(ARGV.fetch(1), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |output|
  output.write(YAML.dump(config))
end
