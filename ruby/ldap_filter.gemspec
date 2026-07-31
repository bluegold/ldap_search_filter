# frozen_string_literal: true

require_relative "lib/ldap_filter/version"

Gem::Specification.new do |spec|
  spec.name = "ldap_filter"
  spec.version = LdapFilter::VERSION
  spec.summary = "Parse and evaluate LDAP Search Filters"
  spec.description = "Parse RFC 4515 LDAP Search Filters and evaluate them against attribute maps."
  spec.authors = ["LDF contributors"]
  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "bin/*", "README.md", "LICENSE*"].select { |path| File.file?(path) }
  end
  spec.bindir = "bin"
  spec.executables = ["ldap_filter"]
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency "csv"
  spec.add_runtime_dependency "did_you_mean"

end
