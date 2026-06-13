package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

const (
	schemaVersion = 1
	parserName    = "mvdan.cc/sh/v3/syntax@v3.10.0"
)

type features struct {
	Pipeline            bool `json:"pipeline"`
	Redirect            bool `json:"redirect"`
	Heredoc             bool `json:"heredoc"`
	Subshell            bool `json:"subshell"`
	CommandSubstitution bool `json:"command_substitution"`
	Variable            bool `json:"variable"`
	Glob                bool `json:"glob"`
	EnvAssignment       bool `json:"env_assignment"`
	ProcessSubstitution bool `json:"process_substitution"`
}

type commandFact struct {
	Name string   `json:"name"`
	Argv []string `json:"argv"`
}

type oracleFact struct {
	SchemaVersion int           `json:"schema_version"`
	Parser        string        `json:"parser"`
	Command       string        `json:"command"`
	ParseStatus   string        `json:"parse_status"`
	Features      features      `json:"features"`
	Commands      []commandFact `json:"commands"`
	Error         *string       `json:"error"`
}

func main() {
	commandFlag := flag.String("command", "", "shell command to parse; stdin is used when omitted")
	pretty := flag.Bool("pretty", false, "indent JSON output")
	flag.Parse()

	command, err := readCommand(*commandFlag, flag.Args(), os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	fact := analyze(command)
	if err := writeFact(os.Stdout, fact, *pretty); err != nil {
		fmt.Fprintf(os.Stderr, "encode oracle fact: %v\n", err)
		os.Exit(1)
	}
}

func readCommand(flagValue string, args []string, stdin io.Reader) (string, error) {
	switch {
	case flagValue != "":
		return flagValue, nil
	case len(args) > 0:
		return strings.Join(args, " "), nil
	default:
		raw, err := io.ReadAll(stdin)
		if err != nil {
			return "", fmt.Errorf("read stdin: %w", err)
		}
		command := strings.TrimRight(string(raw), "\n")
		if command == "" {
			return "", errors.New("missing command: pass --command, argv, or stdin")
		}
		return command, nil
	}
}

func analyze(command string) oracleFact {
	fact := oracleFact{
		SchemaVersion: schemaVersion,
		Parser:        parserName,
		Command:       command,
		ParseStatus:   "ok",
		Features:      features{},
		Commands:      []commandFact{},
		Error:         nil,
	}

	parser := syntax.NewParser()
	file, err := parser.Parse(strings.NewReader(command), "")
	if err != nil {
		msg := err.Error()
		fact.ParseStatus = "parse_error"
		fact.Error = &msg
		return fact
	}

	fact.Features = collectFeatures(file)
	fact.Commands = collectCommands(file)
	return fact
}

func writeFact(w io.Writer, fact oracleFact, pretty bool) error {
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	if pretty {
		encoder.SetIndent("", "  ")
	}
	return encoder.Encode(fact)
}

func collectFeatures(file *syntax.File) features {
	var out features
	syntax.Walk(file, func(node syntax.Node) bool {
		switch n := node.(type) {
		case *syntax.BinaryCmd:
			if n.Op == syntax.Pipe || n.Op == syntax.PipeAll {
				out.Pipeline = true
			}
		case *syntax.Redirect:
			out.Redirect = true
			if n.Hdoc != nil {
				out.Heredoc = true
			}
		case *syntax.Subshell:
			out.Subshell = true
		case *syntax.CmdSubst:
			out.CommandSubstitution = true
		case *syntax.ParamExp:
			out.Variable = true
		case *syntax.Assign:
			out.EnvAssignment = true
		case *syntax.ProcSubst:
			out.ProcessSubstitution = true
		case *syntax.ExtGlob:
			out.Glob = true
		case *syntax.Lit:
			if strings.ContainsAny(n.Value, "*?[") {
				out.Glob = true
			}
		}
		return true
	})
	return out
}

func collectCommands(file *syntax.File) []commandFact {
	var commands []commandFact
	printer := syntax.NewPrinter()
	syntax.Walk(file, func(node syntax.Node) bool {
		call, ok := node.(*syntax.CallExpr)
		if !ok || len(call.Args) == 0 {
			return true
		}

		argv := make([]string, 0, len(call.Args))
		for _, word := range call.Args {
			argv = append(argv, wordString(printer, word))
		}
		commands = append(commands, commandFact{Name: argv[0], Argv: argv})
		return true
	})
	return commands
}

func wordString(printer *syntax.Printer, word *syntax.Word) string {
	var buf bytes.Buffer
	if err := printer.Print(&buf, word); err != nil {
		return ""
	}
	return buf.String()
}
