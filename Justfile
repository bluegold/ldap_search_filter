set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default: test

test: test-ruby test-typescript test-tools

test-ruby:
	cd ruby && bundle exec ruby -Itest test/test_ldap_filter.rb

test-typescript:
	cd typescript && npm test

test-tools:
	ruby tools/test/bench_test.rb
