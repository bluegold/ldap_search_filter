const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const {
  detectFormat,
  parseCsvHeader,
  parseCsvLine,
  parseLtsvLine,
  rowToAttrs
} = require("../dist/io.js");

test("detectFormat uses file suffixes", () => {
  assert.equal(detectFormat("sample.csv"), "csv");
  assert.equal(detectFormat("sample.csv.xz"), "csv");
  assert.equal(detectFormat("sample.ltsv"), "ltsv");
  assert.equal(detectFormat("sample.log"), "ltsv");
});

test("parseCsvLine handles quoted fields", () => {
  assert.deepEqual(parseCsvLine('"a,b","c""d",e'), ["a,b", 'c"d', "e"]);
});

test("parseLtsvLine and rowToAttrs build attribute maps", () => {
  assert.deepEqual(
    parseLtsvLine('host:example.com\tstatus:200\tnote:line\\nnext'),
    {
      host: "example.com",
      status: "200",
      note: "line\nnext"
    }
  );

  const headers = parseCsvHeader("host,status");
  assert.deepEqual(rowToAttrs(headers, ["example.com", "200"]), {
    host: "example.com",
    status: "200"
  });
});

test("forEachInputLine reads plain text files", async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ldf-ts-"));
  const filePath = path.join(tmpDir, "sample.ltsv");
  fs.writeFileSync(filePath, "host:example.com\nhost:example.org\n", "utf8");

  const { forEachInputLine } = require("../dist/io.js");
  const lines = [];

  await forEachInputLine(filePath, (line) => {
    lines.push(line);
  });

  assert.deepEqual(lines, ["host:example.com", "host:example.org"]);
});
