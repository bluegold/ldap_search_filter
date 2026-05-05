package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestParseAndMatch(t *testing.T) {
	attrs := newOrderedAttrs()
	host := "www.kentei.ne.jp"
	status := "200"
	attrs.add("host", &host)
	attrs.add("status", &status)

	expr, err := parseFilter("(&(host=www.*)(status=200))")
	if err != nil {
		t.Fatalf("parseFilter: %v", err)
	}
	if !expr.match(attrs) {
		t.Fatalf("expected expression to match")
	}
}

func TestInspectAttrs(t *testing.T) {
	attrs := newOrderedAttrs()
	timeValue := "2022-04-10T00:00:05+09:00"
	remote := "49.98.3.247"
	http2 := "h2"
	attrs.add("time", &timeValue)
	attrs.add("remote_addr", &remote)
	attrs.add("http/2", &http2)

	got := inspectAttrs(attrs)
	want := `{time: "2022-04-10T00:00:05+09:00", remote_addr: "49.98.3.247", "http/2" => "h2"}`
	if got != want {
		t.Fatalf("inspectAttrs mismatch\nwant: %s\ngot:  %s", want, got)
	}
}

func TestCLI(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sample.ltsv")
	if err := os.WriteFile(path, []byte("host:example.com\tpass:true\nhost:other\tpass:false\n"), 0o644); err != nil {
		t.Fatalf("write input: %v", err)
	}

	var stdout, stderr bytes.Buffer
	if err := run([]string{"--format", "ltsv", "(host=example.com)", path}, &stdout, &stderr); err != nil {
		t.Fatalf("run: %v", err)
	}

	if got := stdout.String(); got != "{host: \"example.com\", pass: \"true\"}\n" {
		t.Fatalf("stdout mismatch: %q", got)
	}
	if !bytes.Contains(stderr.Bytes(), []byte("phase=boot")) ||
		!bytes.Contains(stderr.Bytes(), []byte("phase=ready")) ||
		!bytes.Contains(stderr.Bytes(), []byte("phase=done")) {
		t.Fatalf("missing phase logs: %q", stderr.String())
	}
}
