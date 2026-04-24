(** Non-interactive git environment — RFC-0007 rev.3 PR-1.

    Centralised constants that force git subprocesses (invoked inside
    the keeper docker sandbox or via [Unix.execve]) to fail fast rather
    than block on a credential prompt.

    Evidence (2026-04-24, commit 0e408ffc1d5b34badb0cc1b9f3704a9e725fb8c6):
    [rg -n 'GIT_ASKPASS|GIT_TERMINAL_PROMPT' lib/ test/ scripts/] returned
    zero hits. A keeper [git push] inside docker could, in principle,
    hang indefinitely if the RO-mounted [hosts.yml] auth path failed
    before git fell through to a prompt. This module is the centralised
    fix (RFC-0007 PR-1, one callsite today: [keeper_shell_docker.ml:234-245]).

    Consumers MUST prefer these constants over open-coding the pairs,
    so future callsites inherit the safety guarantee by construction. *)

val env : (string * string) list
(** The two canonical pairs:
    - [("GIT_ASKPASS", "")]       — empty helper, git raises instead of prompting
    - [("GIT_TERMINAL_PROMPT", "0")] — disables the git-core prompt fallback *)

val docker_env_args : string list
(** [env] flattened as docker [run -e KEY=VALUE] argv tokens.

    Each pair [(k, v)] produces two tokens [\["-e"; k ^ "=" ^ v\]], matching
    the existing inline style in [keeper_shell_docker.ml]. Callers append
    this to their existing [-e] list. *)
