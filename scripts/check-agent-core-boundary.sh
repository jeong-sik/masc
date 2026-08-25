#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
core_root="${AGENT_CORE_ROOT:-${repo_root}/packages/agent_core}"

fail() {
  echo "agent-core boundary: $*" >&2
  exit 1
}

[[ ! -L "${core_root}" ]] || fail "package root must not be a symlink: ${core_root}"
[[ -d "${core_root}/lib" ]] || fail "missing required source tree: ${core_root}/lib"
[[ -f "${core_root}/lib/dune" ]] || fail "missing required root library stanza"
[[ -f "${core_root}/test/dune" ]] || fail "missing required behavior suite"
[[ -f "${core_root}/models.toml" ]] || fail "missing required model catalog"

# Agent Core is a source subtree in the MASC workspace, not an independently
# released package. Dune owns dependency resolution; this cheap guard owns only
# the filesystem/package shape that Dune's library graph does not describe.
if independent_surfaces="$(find "${core_root}" -mindepth 1 \
  \( -name dune-project -o -name 'dune-workspace*' -o -name '*.opam' \
     -o -name .github -o -name release-please-config.json \
     -o -name .release-please-manifest.json \) -print)"; then
  :
else
  fail "could not inspect package surfaces below ${core_root}"
fi
[[ -z "${independent_surfaces}" ]] || {
  printf '%s\n' "${independent_surfaces}" >&2
  fail "independent package surface is forbidden"
}

# A source symlink can make Dune compile a coordinator-owned file while the
# library itself still appears to live below packages/agent_core. Reject that
# direct filesystem escape; generated-source provenance is outside this guard.
if source_symlinks="$(find "${core_root}" -mindepth 1 -type l -print)"; then
  :
else
  fail "could not inspect source links below ${core_root}"
fi
[[ -z "${source_symlinks}" ]] || {
  printf '%s\n' "${source_symlinks}" >&2
  fail "source symlinks are forbidden"
}

emit_agent_core_module_alias_violations() {
  find "${core_root}/lib" -type f \( -name '*.ml' -o -name '*.mli' \) -print0 \
    | perl -0 -e '
      use strict;
      use warnings;

      sub is_coordinator_module {
        my ($name) = @_;
        return $name =~ /\A(?:Masc_[A-Za-z0-9_]*|Keeper_[A-Za-z0-9_]*|Board_[A-Za-z0-9_]*|Gate_[A-Za-z0-9_]*|Server_[A-Za-z0-9_]*|Operator_[A-Za-z0-9_]*|Runtime_agent|Runtime_toml|Workspace_[A-Za-z0-9_]*)\z/;
      }

      while (defined(my $path = <STDIN>)) {
        $path =~ s/\0\z//;
        next unless length $path;
        open my $fh, "<", $path or die "could not read $path: $!\n";
        local $/;
        my $raw = <$fh>;
        close $fh or die "could not close $path: $!\n";

        my @tokens;
        my $line = 1;
        for (my $idx = 0; $idx < length($raw); ) {
          my $ch = substr($raw, $idx, 1);
          if ($ch =~ /\s/) {
            $line++ if $ch eq "\n";
            $idx++;
          } elsif (substr($raw, $idx, 2) eq "(*") {
            my $depth = 1;
            $idx += 2;
            while ($idx < length($raw) && $depth > 0) {
              if (substr($raw, $idx, 2) eq "(*") {
                $depth++;
                $idx += 2;
              } elsif (substr($raw, $idx, 2) eq "*)") {
                $depth--;
                $idx += 2;
              } else {
                $line++ if substr($raw, $idx, 1) eq "\n";
                $idx++;
              }
            }
            die "unterminated OCaml comment in $path\n" if $depth;
          } elsif ($ch eq "\x27") {
            # A double quote inside a character literal must not open the
            # string branch below and hide subsequent module aliases. Only
            # consume a complete literal; type variables remain punctuation
            # plus identifiers.
            my $literal_cursor = $idx + 1;
            if ($literal_cursor < length($raw)
                && substr($raw, $literal_cursor, 1) eq "\\") {
              $literal_cursor++;
              if (substr($raw, $literal_cursor, 3) =~ /\A[0-9]{3}\z/) {
                $literal_cursor += 3;
              } elsif (substr($raw, $literal_cursor, 3)
                       =~ /\A[xX][0-9A-Fa-f]{2}\z/) {
                $literal_cursor += 3;
              } elsif (substr($raw, $literal_cursor, 4)
                       =~ /\Ao[0-7]{3}\z/) {
                $literal_cursor += 4;
              } else {
                $literal_cursor++;
              }
            } else {
              $literal_cursor++;
            }
            if ($literal_cursor < length($raw)
                && substr($raw, $literal_cursor, 1) eq "\x27") {
              $idx = $literal_cursor + 1;
            } else {
              $idx++;
            }
          } elsif ($ch eq "\"") {
            $idx++;
            my $closed = 0;
            while ($idx < length($raw)) {
              $ch = substr($raw, $idx, 1);
              if ($ch eq "\\") {
                die "unterminated OCaml escape in $path\n"
                  if $idx + 1 >= length($raw);
                $line++ if substr($raw, $idx + 1, 1) eq "\n";
                $idx += 2;
              } elsif ($ch eq "\"") {
                $closed = 1;
                $idx++;
                last;
              } else {
                $line++ if $ch eq "\n";
                $idx++;
              }
            }
            die "unterminated OCaml string in $path\n" unless $closed;
          } elsif ($ch eq "{" && substr($raw, $idx) =~ /\A\{([a-z_]*)\|/) {
            my $delimiter = $1;
            my $opening = length($delimiter) + 2;
            my $closing = "|" . $delimiter . "}";
            my $end = index($raw, $closing, $idx + $opening);
            die "unterminated OCaml quoted string in $path\n" if $end < 0;
            my $quoted = substr($raw, $idx, $end + length($closing) - $idx);
            $line += ($quoted =~ tr/\n//);
            $idx = $end + length($closing);
          } elsif ($ch =~ /[A-Za-z_]/) {
            my $token_line = $line;
            my $start = $idx++;
            $idx++ while $idx < length($raw)
              && substr($raw, $idx, 1) =~ /[A-Za-z0-9_\x27]/;
            push @tokens, [substr($raw, $start, $idx - $start), $token_line];
          } elsif ($ch =~ /[()\[\]{}=;]/) {
            push @tokens, [$ch, $line];
            $idx++;
          } else {
            $idx++;
          }
        }

        for (my $idx = 0; $idx < @tokens; $idx++) {
          next unless $tokens[$idx][0] eq "module"
            || $tokens[$idx][0] eq "and";
          my $cursor = $idx + 1;
          if ($tokens[$idx][0] eq "module") {
            $cursor++ if $cursor < @tokens && $tokens[$cursor][0] eq "rec";
            $cursor++ if $cursor < @tokens && $tokens[$cursor][0] eq "type";
          }
          next unless $cursor < @tokens
            && $tokens[$cursor][0] =~ /\A[A-Z][A-Za-z0-9_\x27]*\z/;
          my $binding_line = $tokens[$idx][1];
          $cursor++;

          my @stack;
          my $constraint_equality = 0;
          for (; $cursor < @tokens; $cursor++) {
            my $token = $tokens[$cursor][0];
            if ($token eq "(" || $token eq "[" || $token eq "{") {
              push @stack, $token eq "(" ? ")" : $token eq "[" ? "]" : "}";
            } elsif ($token eq "sig" || $token eq "struct"
                     || $token eq "object" || $token eq "begin") {
              push @stack, "end";
            } elsif (@stack && $token eq $stack[-1]) {
              pop @stack;
            } elsif (!@stack && $token eq "with") {
              $constraint_equality = 1;
            } elsif (!@stack && $token eq "and"
                     && $cursor + 1 < @tokens
                     && ($tokens[$cursor + 1][0] eq "type"
                         || $tokens[$cursor + 1][0] eq "module")) {
              $constraint_equality = 1;
            } elsif (!@stack && $token eq "=") {
              my $rhs = $cursor + 1;
              $rhs++ while $rhs < @tokens && $tokens[$rhs][0] eq "(";
              if ($rhs < @tokens && is_coordinator_module($tokens[$rhs][0])) {
                print "$path:$binding_line:$tokens[$rhs][0]\n";
                last;
              } elsif ($constraint_equality) {
                $constraint_equality = 0;
              } else {
                last;
              }
            } elsif (!@stack && !$constraint_equality
                     && $token eq "module"
                     && $cursor + 2 < @tokens
                     && $tokens[$cursor + 1][0] eq "type"
                     && $tokens[$cursor + 2][0] eq "of") {
              # Stay in the current binding while crossing a
              # [module type of ...] signature constraint.
              $cursor += 2;
            } elsif (!@stack && !$constraint_equality
                     && $token eq "module") {
              last;
            } elsif (!@stack && !$constraint_equality
                     && $token =~ /\A(?:type|let|class|exception|external|open|include|end)\z/) {
              last;
            }
          }
        }
      }
    '
}

# Dune's resolved graph is the authority for library dependencies. Keep the
# existing source-level coordinator-name guard as defense in depth until the
# parser-backed replacement tracked by #28258 lands; it is intentionally not
# presented as the dependency authority.
coordinator_module_pattern='(Masc_[A-Za-z0-9_]*|Keeper_[A-Za-z0-9_]*|Board_[A-Za-z0-9_]*|Gate_[A-Za-z0-9_]*|Server_[A-Za-z0-9_]*|Operator_[A-Za-z0-9_]*|Runtime_agent|Runtime_toml|Workspace_[A-Za-z0-9_]*)'
if module_violations="$(rg -n \
  -e "\\b${coordinator_module_pattern}\\." \
  -e "\\b(open!?|include)[[:space:]]+${coordinator_module_pattern}\\b" \
  -e "\\([[:space:]]*module[[:space:]]+${coordinator_module_pattern}\\b" \
  "${core_root}/lib" \
  --glob '*.ml' --glob '*.mli')"; then
  :
else
  status=$?
  if [[ "${status}" -eq 1 ]]; then
    module_violations=""
  else
    fail "could not scan agent core source imports"
  fi
fi
if alias_violations="$(emit_agent_core_module_alias_violations)"; then
  if [[ -n "${alias_violations}" ]]; then
    module_violations="${module_violations}${module_violations:+$'\n'}${alias_violations}"
  fi
else
  fail "could not parse agent core module aliases"
fi
[[ -z "${module_violations}" ]] || {
  printf '%s\n' "${module_violations}" >&2
  fail "agent core source imports a MASC coordinator module"
}

echo "agent-core package shape: ok"
