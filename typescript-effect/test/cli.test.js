const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Effect, Layer } = require("effect");
const { CliConsole, program } = require("../dist/cli.js");

test("program processes LTSV inside an Effect", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ldf-effect-"));
  const input = path.join(dir, "sample.ltsv");
  fs.writeFileSync(input, "host:example.com\tstatus:200\nhost:example.org\tstatus:404\n");
  const stdout = [];
  const originalWrite = process.stdout.write;
  process.stdout.write = (chunk) => { stdout.push(String(chunk)); return true; };
  try {
    const testConsole = {
      stdout: (text) => Effect.sync(() => stdout.push(String(text))),
      stderr: () => Effect.void
    };
    const code = await Effect.runPromise(Effect.provide(program(["--format", "ltsv", "(host=example.com)", input]), Layer.succeed(CliConsole, testConsole)));
    assert.equal(code, 0);
  } finally {
    process.stdout.write = originalWrite;
  }
  assert.match(stdout.join(""), /example\.com/);
  assert.doesNotMatch(stdout.join(""), /example\.org/);
});

test("program processes CSV quoted newlines as one record", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ldf-effect-"));
  const input = path.join(dir, "sample.csv");
  fs.writeFileSync(input, "host,message\nexample.com,\"hello\nworld\"\nexample.org,other\n");
  const stdout = [];
  const testConsole = {
    stdout: (text) => Effect.sync(() => stdout.push(String(text))),
    stderr: () => Effect.void
  };
  const code = await Effect.runPromise(Effect.provide(program(["--format", "csv", "(host=example.com)", input]), Layer.succeed(CliConsole, testConsole)));
  assert.equal(code, 0);
  assert.match(stdout.join(""), /hello.*world/s);
  assert.doesNotMatch(stdout.join(""), /example\.org/);
});
