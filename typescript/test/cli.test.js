const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { main } = require("../dist/cli.js");

async function captureOutput(run) {
  const stdoutChunks = [];
  const stderrChunks = [];
  const originalStdoutWrite = process.stdout.write.bind(process.stdout);
  const originalStderrWrite = process.stderr.write.bind(process.stderr);

  process.stdout.write = (chunk, encoding, callback) => {
    stdoutChunks.push(String(chunk));
    if (typeof callback === "function") {
      callback();
    }
    return true;
  };
  process.stderr.write = (chunk, encoding, callback) => {
    stderrChunks.push(String(chunk));
    if (typeof callback === "function") {
      callback();
    }
    return true;
  };

  try {
    const code = await run();
    return { code, stdout: stdoutChunks.join(""), stderr: stderrChunks.join("") };
  } finally {
    process.stdout.write = originalStdoutWrite;
    process.stderr.write = originalStderrWrite;
  }
}

test("main emits phases and matches ltsv rows", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ldf-ts-"));
  const filePath = path.join(tmpDir, "sample.ltsv");
  fs.writeFileSync(
    filePath,
    [
      "host:example.com\tstatus:200",
      "host:example.org\tstatus:404"
    ].join("\n") + "\n",
    "utf8"
  );

  const output = await captureOutput(() => main(["--format", "ltsv", "(host=example.com)", filePath]));

  assert.equal(output.code, 0);
  assert.match(output.stderr, /phase=boot/);
  assert.match(output.stderr, /phase=ready/);
  assert.match(output.stderr, /phase=done/);
  assert.match(output.stdout, /example\.com/);
  assert.doesNotMatch(output.stdout, /example\.org/);
});

test("main emits phases and matches csv rows", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ldf-ts-"));
  const filePath = path.join(tmpDir, "sample.csv");
  fs.writeFileSync(
    filePath,
    [
      "host,status",
      "example.com,200",
      "example.org,404"
    ].join("\n") + "\n",
    "utf8"
  );

  const output = await captureOutput(() => main(["--format", "csv", "(host=example.com)", filePath]));

  assert.equal(output.code, 0);
  assert.match(output.stderr, /phase=boot/);
  assert.match(output.stderr, /phase=ready/);
  assert.match(output.stderr, /phase=done/);
  assert.match(output.stdout, /example\.com/);
  assert.doesNotMatch(output.stdout, /example\.org/);
});
