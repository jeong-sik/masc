package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestAnalyzeSimple(t *testing.T) {
	fact := analyze("echo hello")
	if fact.ParseStatus != "ok" {
		t.Fatalf("status = %q", fact.ParseStatus)
	}
	if len(fact.Commands) != 1 {
		t.Fatalf("commands = %d", len(fact.Commands))
	}
	if fact.Commands[0].Name != "echo" {
		t.Fatalf("name = %q", fact.Commands[0].Name)
	}
	if got := fact.Commands[0].Argv; len(got) != 2 || got[0] != "echo" || got[1] != "hello" {
		t.Fatalf("argv = %#v", got)
	}
	if fact.Features.Redirect || fact.Features.Pipeline {
		t.Fatalf("unexpected features: %#v", fact.Features)
	}
}

func TestAnalyzeFeatures(t *testing.T) {
	fact := analyze("FOO=bar echo $FOO > out.txt | wc -l")
	if fact.ParseStatus != "ok" {
		t.Fatalf("status = %q error=%v", fact.ParseStatus, fact.Error)
	}
	if !fact.Features.Pipeline {
		t.Fatal("pipeline feature not detected")
	}
	if !fact.Features.Redirect {
		t.Fatal("redirect feature not detected")
	}
	if !fact.Features.Variable {
		t.Fatal("variable feature not detected")
	}
	if !fact.Features.EnvAssignment {
		t.Fatal("env assignment feature not detected")
	}
}

func TestAnalyzeHeredocAndSubstitution(t *testing.T) {
	fact := analyze("cat <<EOF\n$(date)\nEOF")
	if fact.ParseStatus != "ok" {
		t.Fatalf("status = %q error=%v", fact.ParseStatus, fact.Error)
	}
	if !fact.Features.Heredoc {
		t.Fatal("heredoc feature not detected")
	}
	if !fact.Features.CommandSubstitution {
		t.Fatal("command substitution feature not detected")
	}
}

func TestAnalyzeParseErrorEmitsJSONFact(t *testing.T) {
	fact := analyze("echo \"unterminated")
	if fact.ParseStatus != "parse_error" {
		t.Fatalf("status = %q", fact.ParseStatus)
	}
	if fact.Error == nil || *fact.Error == "" {
		t.Fatal("missing parse error")
	}
	if len(fact.Commands) != 0 {
		t.Fatalf("commands = %#v", fact.Commands)
	}
	if fact.Commands == nil {
		t.Fatal("commands must encode as [] instead of null")
	}
	if _, err := json.Marshal(fact); err != nil {
		t.Fatalf("marshal: %v", err)
	}
}

func TestWriteFactDoesNotHTMLEscapeShellOperators(t *testing.T) {
	fact := analyze("echo hello > out.txt")
	var buf bytes.Buffer
	if err := writeFact(&buf, fact, true); err != nil {
		t.Fatalf("write fact: %v", err)
	}
	if strings.Contains(buf.String(), `\u003e`) {
		t.Fatalf("escaped shell operator in JSON: %s", buf.String())
	}
	if !strings.Contains(buf.String(), "echo hello > out.txt") {
		t.Fatalf("missing readable command: %s", buf.String())
	}
}
