
(** Tool_call_replay_harness — JSONL snapshot loader + validation
    for tool-call replay scoring.

    Snapshot files capture a single tool-call interaction (goal,
    declared tools, OpenAI-format response, expected tool calls)
    so the harness can replay against alternative providers and
    assert tool-call equivalence offline.

    Two-stage API:
    1. {!load_snapshots_from_jsonl} parses a JSONL file into typed
       records.
    2. {!validate_snapshot} checks the response against the
       declared expectations and returns a list of human-readable
       error messages.

    Provider gate: only providers whose canonical name matches the
    OpenAI-compatible chat-completions envelope are supported
    today.  Unsupported providers must add an explicit extractor
    rather than silently reusing the OpenAI parser. *)

(** {1 Typed records} *)

type tool_call = {
  name : string;
  arguments : Yojson.Safe.t;
}
(** A single tool invocation.  Concrete record because tests
    construct it field-by-field for synthetic snapshots
    ({!Test_tool_call_replay_harness}). *)

type snapshot = {
  id : string;
  provider : string;
  model : string option;
  goal : string;
  tools : string list;
  response : Yojson.Safe.t;
  expected_tool_calls : tool_call list;
}
(** Parsed snapshot.  [tools] is the declared list of tool names
    available for the call; both expected and actual tool calls
    are validated against this set. *)

(** {1 Loader} *)

val load_snapshots_from_jsonl :
  string -> (snapshot list, string) Result.t
(** [load_snapshots_from_jsonl path] reads a JSONL file and parses
    each row into a {!snapshot}.

    {2 Error contract}

    Returns [Error msg] for any of:
    - File not found:
      [["snapshot file not found: <path>"]]
    - Malformed JSONL line:
      [["snapshot file contains <N> malformed JSONL line(s): <path>"]]
    - Per-row parse failure:
      [["snapshot[<idx>]: <reason>"]] where [<idx>] is the
      0-based row index and [<reason>] is the field-level error
      from {!snapshot_of_json}.

    The error wording is operator-visible (rendered into the test
    output and CI failure summary) — pinned so a future "let's
    rephrase the errors" PR must touch this contract. *)

(** {1 Validator} *)

val validate_snapshot : snapshot -> (unit, string list) Result.t
(** [validate_snapshot snapshot] checks the response against the
    declared expectations.

    Returns [Ok ()] when every declared expectation matches.
    Returns [Error msgs] with all violations collected (no early
    return).  Validation steps:

    1. Every [expected_tool_calls\[i\].name] must appear in
       [snapshot.tools] (otherwise:
       ["expected tool '<name>' is not declared in snapshot.tools"]).
    2. Provider must be supported by
       {!response_format_of_provider} (canonical names:
       [codex-api] / [glm-api] / [glm-coding-plan] / [kimi-api] /
       [openrouter] / [ollama] / [llama]; unsupported:
       ["snapshot provider '<p>' (canonical '<c>') is not supported by replay harness yet"]).
    3. Response must be the OpenAI Chat Completions shape with at
       least one [choices\[\]] entry containing
       [message.tool_calls\[\]] (errors trace the path:
       [response.choices[0].message.tool_calls]).
    4. Response tool calls must be declared in [snapshot.tools].
    5. Tool-call counts must match [List.length expected_tool_calls].
    6. Each pair (expected, actual) must agree on [name] AND on
       [arguments] via {!Yojson.Safe.equal}.

    The "collect all errors" stance is deliberate — the harness
    is a CI gate that should surface every failure in one pass so
    operators do not need to fix-and-retry incrementally.  All
    error wordings are pinned at the contract seam. *)
