set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default: test

test: test-ruby test-typescript test-csharp test-zig test-rust test-go test-go-switch test-tools

test-ruby:
	cd ruby && bundle exec ruby -Itest test/test_ldap_filter.rb

test-typescript:
	cd typescript && npm test

test-csharp:
	cd csharp && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet run --project tests/LdapFilter.Tests.csproj -c Release

test-zig:
	cd zig && env ZIG_GLOBAL_CACHE_DIR=/tmp/ldf-zig-cache ZIG_LOCAL_CACHE_DIR=/tmp/ldf-zig-cache-local zig build test

test-rust:
	cd rust && cargo test

test-go:
	cd go && env GOCACHE=/tmp/ldf-gocache go test ./...

test-go-switch:
	cd go-switch && env GOCACHE=/tmp/ldf-gocache go test ./...

test-tools:
	ruby tools/test/bench_test.rb
