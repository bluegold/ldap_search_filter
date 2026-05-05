const test = require("node:test");
const assert = require("node:assert/strict");

const { evaluateFilter, inspectAttrs, parseFilter } = require("../dist/filter.js");

test("parseFilter parses wildcard filters", () => {
  const node = parseFilter("(host=www.*)");

  assert.equal(node.kind, "item");
  assert.equal(node.attr, "host");
  assert.equal(node.op, "=");
  assert.equal(node.value, "www.*");
  assert.ok(node.regex instanceof RegExp);
});

test("parseFilter parses presence filters", () => {
  const node = parseFilter("(host=*)");

  assert.equal(node.kind, "item");
  assert.equal(node.value, "*");
  assert.equal(node.regex, undefined);
});

test("evaluateFilter handles logical expressions", () => {
  const node = parseFilter("(&(host=www.*)(status=200))");

  assert.equal(
    evaluateFilter(node, {
      host: "www.example.com",
      status: "200"
    }),
    true
  );
});

test("inspectAttrs formats ruby-like hashes", () => {
  assert.equal(
    inspectAttrs({
      time: "2022-04-10T00:00:05+09:00",
      remote_addr: "49.98.3.247",
      "http/2": "h2"
    }),
    '{time: "2022-04-10T00:00:05+09:00", remote_addr: "49.98.3.247", "http/2" => "h2"}'
  );
});
