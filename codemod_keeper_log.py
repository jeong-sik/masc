#!/usr/bin/env python3
"""Codemod: migrate Log.Keeper.* "keeper:%s ..." to ~keeper_name parameter.

Uses perl-style multiline regex over file contents.
Handles:
  1. Same-line:   Log.Keeper.warn "keeper:%s msg" var rest
  2. Split format: Log.Keeper.warn\n  "keeper:%s msg"\n  var rest
"""

import re
import sys
from pathlib import Path

# Pattern: Log.Keeper.LEVEL (optional whitespace/newline) "keeper:%s REST" (optional whitespace) FIRST_ARG REST
# Captures: prefix, level, between, rest_of_format, after_fmt_close, first_arg, remaining_args
# We handle two cases separately for clarity.

def transform(content: str) -> tuple[str, int]:
    changes = 0

    # Case 1: Same-line
    #   Log.Keeper.warn "keeper:%s some message" keeper_var other; stuff
    # → Log.Keeper.warn ~keeper_name:keeper_var "some message" other; stuff
    def same_line(m):
        nonlocal changes
        indent = m.group('indent')
        level = m.group('level')
        rest_fmt = m.group('rest')
        after = m.group('after')
        # Parse first arg from 'after' (starts with whitespace, then the arg)
        arg_m = re.match(r'\s+(\S+)(.*)', after)
        if not arg_m:
            return m.group(0)  # can't parse, skip
        first_arg = arg_m.group(1)
        remaining = arg_m.group(2)
        changes += 1
        return f'{indent}Log.Keeper.{level} ~keeper_name:{first_arg} "{rest_fmt}"{remaining}'

    content = re.sub(
        r'(?P<indent>^\s*)Log\.Keeper\.(?P<level>info|warn|error|debug)\s+"keeper:%s (?P<rest>[^"]*)"(?P<after>.*)$',
        same_line,
        content,
        flags=re.MULTILINE,
    )

    # Case 2: Multi-line (format on next line)
    #   Log.Keeper.warn
    #     "keeper:%s some message" keeper_var other
    # → Log.Keeper.warn ~keeper_name:keeper_var
    #     "some message" other
    def multi_line_fmt(m):
        nonlocal changes
        indent = m.group('indent')
        level = m.group('level')
        fmt_indent = m.group('fmt_indent')
        rest_fmt = m.group('rest')
        after = m.group('after')
        arg_m = re.match(r'\s+(\S+)(.*)', after)
        if not arg_m:
            return m.group(0)
        first_arg = arg_m.group(1)
        remaining = arg_m.group(2)
        changes += 1
        return f'{indent}Log.Keeper.{level} ~keeper_name:{first_arg}\n{fmt_indent}"{rest_fmt}"{remaining}'

    content = re.sub(
        r'(?P<indent>^\s*)Log\.Keeper\.(?P<level>info|warn|error|debug)\s*\n\s*(?P<fmt_indent>\s+)"keeper:%s (?P<rest>[^"]*)"(?P<after>.*)$',
        multi_line_fmt,
        content,
        flags=re.MULTILINE,
    )

    # Case 3: Multi-line with args on separate line from format
    #   Log.Keeper.warn
    #     "keeper:%s some message"
    #       keeper_var other
    # → Log.Keeper.warn ~keeper_name:keeper_var
    #     "some message"
    #       other
    def multi_line_args(m):
        nonlocal changes
        indent = m.group('indent')
        level = m.group('level')
        fmt_indent = m.group('fmt_indent')
        rest_fmt = m.group('rest')
        arg_indent = m.group('arg_indent')
        first_arg = m.group('first_arg')
        remaining = m.group('remaining')
        changes += 1
        remaining_stripped = remaining.lstrip()
        if remaining_stripped:
            return (
                f'{indent}Log.Keeper.{level} ~keeper_name:{first_arg}\n'
                f'{fmt_indent}"{rest_fmt}"\n'
                f'{arg_indent}{remaining_stripped}'
            )
        else:
            return (
                f'{indent}Log.Keeper.{level} ~keeper_name:{first_arg}\n'
                f'{fmt_indent}"{rest_fmt}"'
            )

    content = re.sub(
        r'(?P<indent>^\s*)Log\.Keeper\.(?P<level>info|warn|error|debug)\s*\n(?P<fmt_indent>\s+)"keeper:%s (?P<rest>[^"]*)"\s*\n(?P<arg_indent>\s+)(?P<first_arg>\S+)(?P<remaining>.*)$',
        multi_line_args,
        content,
        flags=re.MULTILINE,
    )

    return content, changes


def main():
    lib_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('lib/keeper')
    total = 0
    files_changed = 0

    for fpath in sorted(lib_dir.rglob('*.ml')):
        old = fpath.read_text()
        new, changes = transform(old)
        if changes > 0:
            fpath.write_text(new)
            print(f'  {fpath.relative_to(lib_dir.parent.parent)}: {changes} sites')
            total += changes
            files_changed += 1

    print(f'\nTotal: {total} sites in {files_changed} files')


if __name__ == '__main__':
    main()
