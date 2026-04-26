(** Post-execution semantic classification of a completed shell command.

    This layer is {b orthogonal} to [Verdict]:
    - [Verdict] answers {i "may this command run?"} (pre-exec gate,
      produces [Trusted_argv.t] or denies).
    - [Exec_semantic] answers {i "how should the caller interpret the
      exit status of a command that already ran?"} (post-exec hint).

    Inspired by claude-code's [interpretCommandResult] in
    [src/utils/Shell.ts]. The OpenAI Codex harness blog posts
    ("harness-engineering", "unlocking-the-codex-harness") frame this
    as turning raw OS return codes into typed markers the agent loop
    can reason over without string scraping.

    Rollout: additive JSON field. Gated by [MASC_BASH_SEMANTIC_EXIT]
    env flag during the bake-in window (see
    [planning/claude-plans/20m-me-workspace-yousleepwhen-masc-mcp-graceful-panda.md]
    Phase 1). *)

(** Polymorphic variant so downstream modules can narrow the set in
    their own match arms without introducing a module dependency. *)
type t =
  [ `Ok
  | `Fail of int
  | `Timeout of float
  | `Signaled of int
  | `Git_not_a_repo
  | `Oom_killed
  | `Policy_denied of string
  | `Tool_missing of string
  | `Permission_denied of string
  ]

(** Map a finished [Unix.process_status] plus captured output into a
    semantic classification.

    Callers that only have a merged [output] string (e.g.
    [Exec_core.outcome]) should use [interpret_cmd] instead. *)
val interpret
  :  argv:string list
  -> status:Unix.process_status
  -> stdout:string
  -> stderr:string
  -> t

(** Best-effort [interpret] for call sites that carry a single
    [cmd:string] instead of an [argv] list and a merged
    [output:string] (stdout ++ stderr) instead of split streams.
    The first whitespace-separated token is treated as the argv head
    for tool-name heuristics; OOM detection scans the merged output.

    Heuristics (ported from claude-code [interpretCommandResult]):
    - exit 128 on [git …]  -> [`Git_not_a_repo]
    - exit 127             -> [`Tool_missing]
    - exit 126             -> [`Permission_denied]
    - SIGKILL w/ OOM token -> [`Oom_killed]
    - SIGTERM              -> [`Signaled]
    - otherwise exit 0     -> [`Ok]
    - otherwise exit n     -> [`Fail n]

    [interpret] is total and never raises. *)
val interpret_cmd : cmd:string -> status:Unix.process_status -> output:string -> t

(* interpret_cmd doc intentionally above; keeps interpret doc local. *)

(** Human-readable operator hint for LLM consumption. None for [`Ok]. *)
val to_hint : t -> string option

(** Self-correction alternatives for each semantic exit kind.
    Each string is a complete, actionable suggestion that an LLM agent
    can execute directly. Empty list means no auto-correction is
    possible (operator intervention required). *)
val to_alternatives : t -> string list

(** Minimal sum to describe variant payloads without forcing a
    [Yojson] dependency on [masc_exec]. The JSON envelope itself is
    rendered by the caller (e.g. [Exec_core] uses [Yojson.Safe]). *)
type payload_value =
  [ `String of string
  | `Int of int
  | `Float of float
  ]

(** Stable string tag for the semantic variant — e.g. ["ok"], ["fail"],
    ["git_not_a_repo"]. Additive-only: new variants extend the set but
    never rename or remove an existing tag. *)
val to_kind : t -> string

(** Variant-specific key/value pairs (e.g. [("exit_code", `Int 2)]).
    Empty for nullary variants. *)
val to_payload : t -> (string * payload_value) list

(** Runtime feature flag reader. Reads [MASC_BASH_SEMANTIC_EXIT].

    Default (post-#8721): [true] — the semantic field is emitted
    unless an operator explicitly opts out with
    [MASC_BASH_SEMANTIC_EXIT=0] (or ["false" / "FALSE" / "no" / "off"]).

    The flag survives one more minor bump to let downstream
    consumers confirm compatibility before it is removed.  The
    [interpret] / [to_json] functions are always safe to call; the
    flag only gates whether producers include the result in the
    user-visible response. *)
val enabled : unit -> bool
