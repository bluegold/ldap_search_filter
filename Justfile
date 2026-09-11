set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default: test

test: test-ruby test-typescript test-typescript-effect test-python test-php test-cpp test-csharp test-csharp-aot test-zig test-rust test-go test-go-switch test-sbcl test-ghc test-tools

test-ruby:
	cd ruby && bundle exec ruby -Itest test/test_ldap_filter.rb

test-typescript:
	cd typescript && npm test

test-typescript-effect:
	cd typescript-effect && npm test

test-python:
	cd python && python3 -m unittest discover -s test -p 'test_*.py'

test-php:
	cd php && php test/test_ldap_filter.php

test-cpp:
	cd cpp && g++ -std=c++20 -O3 -pipe -o ldap_filter main.cpp && g++ -std=c++20 -O2 -pipe -o /tmp/ldf-cpp-test tests/test_ldap_filter.cpp && /tmp/ldf-cpp-test

test-csharp:
	cd csharp && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet run --project tests/LdapFilter.Tests.csproj -c Release

test-csharp-aot:
	cd csharp-aot && env DOTNET_CLI_HOME=/tmp/ldf-dotnet DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_NOLOGO=1 dotnet publish LdapFilter.Aot.csproj -c Release -r linux-x64 -p:PublishAot=true -p:SelfContained=true
	cd csharp-aot && bash ./test-smoke.sh

test-zig:
	cd zig && env ZIG_GLOBAL_CACHE_DIR=/tmp/ldf-zig-cache ZIG_LOCAL_CACHE_DIR=/tmp/ldf-zig-cache-local zig build test

test-rust:
	cd rust && cargo test

test-go:
	cd go && env GOCACHE=/tmp/ldf-gocache go test ./...

test-go-switch:
	cd go-switch && env GOCACHE=/tmp/ldf-gocache go test ./...

test-sbcl:
	cd sbcl && sbcl --noinform --non-interactive --load ldap_filter.lisp --load test/test_ldap_filter.lisp 2>/dev/null

test-ghc:
	cd ghc && bash test-unit.sh

test-tools:
	ruby tools/test/bench_test.rb
