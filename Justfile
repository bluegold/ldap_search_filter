set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default: test

test: test-ruby test-typescript test-csharp test-tools

test-ruby:
	cd ruby && bundle exec ruby -Itest test/test_ldap_filter.rb

test-typescript:
	cd typescript && npm test

test-csharp:
	cd csharp && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet run --project tests/LdapFilter.Tests.csproj -c Release

test-tools:
	ruby tools/test/bench_test.rb
