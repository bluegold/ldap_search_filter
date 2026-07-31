#!/usr/bin/env ruby

require "rbconfig"

def bootstrap_yjit!(argv)
  yjit = nil
  yjit_stats = false

  i = 0
  while i < argv.length
    case argv[i]
    when "--jit", "--yjit"
      raise ArgumentError, "conflicting JIT flags" if yjit == false

      yjit = true
      argv.delete_at(i)
    when "--no-jit", "--no-yjit"
      raise ArgumentError, "conflicting JIT flags" if yjit == true

      yjit = false
      argv.delete_at(i)
    when "--yjit-stats"
      yjit_stats = true
      argv.delete_at(i)
    else
      i += 1
    end
  end

  return if yjit.nil? && !yjit_stats

  if yjit_stats
    raise ArgumentError, "--yjit-stats requires --jit" if yjit == false
    yjit = true
  end

  ruby_args = [RbConfig.ruby]
  ruby_args << "--yjit" if yjit
  ruby_args << "--disable-yjit" if yjit == false
  ruby_args << "--yjit-stats" if yjit_stats
  ruby_args << $PROGRAM_NAME
  ruby_args.concat(argv)

  exec(*ruby_args)
end

bootstrap_yjit!(ARGV)

require_relative "lib/ldap_filter"
require_relative "lib/ldap_filter/cli"

LdapFilter::Cli.run(ARGV)
