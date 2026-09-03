const test = require("node:test");
const assert = require("node:assert/strict");
const { Effect } = require("effect");
const { evaluateFilter, inspectAttrs, parseFilter } = require("../dist/filter.js");

test("Effect parser and evaluator return Effects", async () => {
  const ast = await Effect.runPromise(parseFilter("(&(host=www.*)(status=200))"));
  assert.equal(await Effect.runPromise(evaluateFilter(ast, { host: "www.example.com", status: "200" })), true);
  assert.equal(await Effect.runPromise(inspectAttrs({ host: "www.example.com" })), '{host: "www.example.com"}');
});

test("escaped asterisk is distinct from a presence filter", async () => {
  const literalStar = await Effect.runPromise(parseFilter("(cn=\\2a)"));
  const presence = await Effect.runPromise(parseFilter("(cn=*)"));

  assert.equal(
    await Effect.runPromise(evaluateFilter(literalStar, { cn: "*" })),
    true
  );
  assert.equal(
    await Effect.runPromise(evaluateFilter(literalStar, { cn: "anything" })),
    false
  );

  assert.equal(
    await Effect.runPromise(evaluateFilter(presence, { cn: "anything" })),
    true
  );
  assert.equal(
    await Effect.runPromise(evaluateFilter(presence, {})),
    false
  );

});

test("UTF-8 escapes are decoded correctly", async () => {
  const utf8 = await Effect.runPromise(parseFilter("(cn=\\c4\\8d)"));
  assert.equal(await Effect.runPromise(evaluateFilter(utf8, { cn: "č" })), true);
});

test("empty values and trailing input follow the filter grammar", async () => {
  const empty = await Effect.runPromise(parseFilter("(cn=)"));
  assert.equal(await Effect.runPromise(evaluateFilter(empty, { cn: "" })), true);
  await assert.rejects(Effect.runPromise(parseFilter("(cn=a)junk")));
  await assert.rejects(Effect.runPromise(parseFilter("(&(a=b)x(c=d))")));
});
