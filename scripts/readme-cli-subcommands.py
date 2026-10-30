#!/usr/bin/env python3
"""Read shell examples from stdin and report direct MASC subcommands, never execute them."""

import re
import shlex
import sys

ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")
SUBCOMMAND = re.compile(r"[a-z][a-z0-9_-]*\Z")


def command_words(line):
    # Split only unquoted shell separators. shlex then decodes each command's
    # words, including assignments such as DEMO="two; words". Splitting before
    # unquoting keeps a literal "&&" in echo arguments out of command position.
    start = 0
    quote = None
    escaped = False
    segments = []
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote is not None:
            if char == quote:
                quote = None
        elif char in {"'", '"'}:
            quote = char
        elif char == "#" and (index == start or line[index - 1].isspace()):
            line = line[:index]
            break
        elif char in ";&|":
            segments.append(line[start:index])
            start = index + 1
    segments.append(line[start:])
    for segment in segments:
        try:
            words = shlex.split(segment)
        except ValueError:
            # README code also contains non-shell examples and placeholders.
            continue
        if words:
            yield words


def subcommand(words):
    index = 0
    while index < len(words) and ASSIGNMENT.match(words[index]):
        index += 1
    if index < len(words) and words[index] == "env":
        index += 1
        while index < len(words):
            word = words[index]
            if ASSIGNMENT.match(word) or word in {"-i", "--ignore-environment"}:
                index += 1
            elif word in {"-u", "--unset"}:
                index += 2
            elif word.startswith("--unset="):
                index += 1
            elif word == "--":
                index += 1
                while index < len(words) and ASSIGNMENT.match(words[index]):
                    index += 1
                break
            else:
                break
    if index + 1 < len(words):
        executable = words[index].rsplit("/", 1)[-1]
        name = words[index + 1]
        if executable in {"masc", "main_eio.exe"} and SUBCOMMAND.fullmatch(name):
            return name
    return None


def main():
    # A shell continuation keeps subsequent binary paths in the same command's
    # argument list (not a new invocation on the following display line).
    examples = sys.stdin.read().replace("\\\n", "")
    for line in examples.splitlines():
        for words in command_words(line):
            name = subcommand(words)
            if name is not None:
                print(name)


if __name__ == "__main__":
    main()
