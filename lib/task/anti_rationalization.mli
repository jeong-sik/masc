(** Anti-rationalization gate for task completion.

    Verifies that completion notes actually address the task rather than
    containing avoidance patterns ("out of scope", "will do later", etc.).

    Inspired by Trail of Bits' Stop hook anti-rationalization pattern:
    a separate model reviews the primary agent's work before accepting it.

    When the LLM reviewer is unavailable, the configured fail-open/fail-closed
    policy decides whether liveness or safety takes priority. Empty or malformed
    evaluator output is treated as an invalid verdict and rejected.

    Cross-model evaluation (#3067): use [~evaluator_runtime] to force
    a different model family than the generator, providing genuine
    adversarial tension rather than same-model self-evaluation.

    @since v2.145.0 *)

(** Review request: task context + agent's completion claim. *)
type review_request = {
  task_title : string;
  task_description : string;
  completion_notes : string;
  agent_name : string;
  task_id : string;
  evidence_refs : string list;
}

(** Gate verdict. *)
type verdict =
  | Approve
  | Reject of string

type verdict_parse_error =
  | Empty_review_output
  | Unrecognized_review_format of string

val verdict_parse_error_to_string : verdict_parse_error -> string

type excuse_pattern_decision =
  | Terminal_reject
  | Advisory_to_llm
  | Advisory_safety_net_reject
  | Advisory_safety_net_reject_runtime_dead

val excuse_pattern_decision_to_string : excuse_pattern_decision -> string

val verdict_constructor_name : verdict -> string
(** Issue #8436: canonical UPPERCASE name (without payload) for a
    [verdict] — used as the witness function for schema enum SSOT. *)

val valid_verdict_strings : string list
(** Issue #8436: complete list of canonical [verdict] strings the
    schema enum advertises. Adding a 3rd constructor will fail
    compilation in [verdict_constructor_name]. *)

(** Which gate produced the verdict. Variant type prevents typos that
    would silently compile with a stringly-typed field. *)
type gate =
  | Evidence
  | Length
  | Excuse
  | Contract
  | Structured_tool
  | Llm_text_fallback
  | Format_reject
  | Evaluator_empty
      (** Evaluator responded with an empty completion — an evaluator-side
          failure, distinct from [Format_reject] (a parseable-but-wrong
          response). Deterministic Reject either way; empty output never
          approves (#22573 ratchet). Typed apart so evaluator health is
          observable and the keeper is not told to revise its notes. *)
  | Fallback

val gate_to_string : gate -> string

(** Structured review result with audit metadata for cross-model tracking. *)
type review_result = {
  verdict : verdict;
  evaluator_runtime : string;
  generator_runtime : string option;
  gate : gate;
  fallback_reason : string option;  (** Error message when gate=Fallback *)
}

(** Review a task completion claim with optional cross-model separation.

    @param evaluator_runtime Override runtime for LLM verification.
      Default: the profile selected by [routes.cross_verifier]. Use a
      different runtime name to force a specific evaluator profile.
    @param generator_runtime Optional name of the generator's runtime.
      Logged for auditing; not used in verification logic.
    @param required_evidence Contract [required_evidence] artifacts. Surfaced
      to the LLM prompt as a per-item checklist (task-1664).
    @param verify_gate_evidence Contract [verify_gate_evidence] artifacts,
      surfaced alongside [required_evidence] in the same checklist. *)
val review :
  ?evaluator_runtime:string ->
  ?generator_runtime:string ->
  ?completion_contract:string list ->
  ?required_evidence:string list ->
  ?verify_gate_evidence:string list ->
  ?on_verdict:(review_result -> unit) ->
  ?few_shot_block:string ->
  ?operator_override:bool ->
  ?sw:Eio.Switch.t option ->
  review_request -> review_result

(** Check completion notes against a contract. Returns unmet items.
    Used internally by Gate 2.5; exposed for testing. *)
val check_contract : notes:string -> contract:string list -> string list

(** Load excuse patterns dynamically from config/excuse_patterns.json.
    Returns the default hardcoded list if the file is missing or invalid.
    Exposed for dashboard administration. *)
val load_excuse_patterns : unit -> (string * string) list

(** Parse and validate a JSON value into excuse patterns.
    Rejects malformed entries with [Error msg] instead of silently dropping them. *)
val parse_excuse_patterns_json : Yojson.Safe.t -> ((string * string) list, string) result

(** Save excuse patterns to config/excuse_patterns.json.
    Uses atomic write (temp + rename). Invalidates cache on success.
    Returns [Ok ()] on success or [Error msg] on failure.
    Exposed for dashboard administration. *)
val save_excuse_patterns : (string * string) list -> (unit, string) result

(** Drop the in-memory pattern cache so the next [load_excuse_patterns]
    re-reads the on-disk file.  Exposed for tests that swap
    [MASC_CONFIG_DIR] between cases — the cache is otherwise process-
    lifetime and would mask later loads. *)
val reset_cache_for_tests : unit -> unit

(** Check notes for known excuse patterns (local, no LLM).
    Returns [Some (pattern, reason)] if a match is found.
    Exposed for testing. *)
val find_excuse_pattern : string -> (string * string) option

(** Build the LLM evaluator prompt for a review request.
    [excuse_advisory], when supplied, injects a
    [<gate2_advisory>] section that surfaces a substring-detected
    avoidance phrase to the LLM as a heuristic signal rather than
    a verdict — see #10113. [completion_contract], when supplied,
    injects a [<verification_contract>] section that the LLM must
    judge against completion notes. [required_evidence] /
    [verify_gate_evidence], when supplied, inject a [<required_evidence>]
    section listing the contract-required artifacts the notes must supply,
    with a per-item judgement instruction (task-1664). Exposed so tests can
    pin the prompt contract without standing up an OAS runtime. *)
val build_prompt :
  ?few_shot_block:string ->
  ?excuse_advisory:string * string ->
  ?completion_contract:string list ->
  ?required_evidence:string list ->
  ?verify_gate_evidence:string list ->
  review_request -> string

(** Parse LLM text output into a verdict (lenient fallback path).
    "APPROVE" -> [Ok Approve], "REJECT: reason" -> [Ok (Reject reason)].
    Unrecognized format returns [Error] instead of silently approving (ADR D3).
    Exposed for testing.
    @since 2.223.0 changed return type from [verdict] to [(verdict, string) result] *)
val parse_verdict : string -> (verdict, string) result

(** Typed variant of {!parse_verdict}. Production routing uses this form so
    empty output and malformed output cannot be distinguished by fragile string
    matching. *)
val parse_verdict_typed : string -> (verdict, verdict_parse_error) result

(** Parse verdict from structured tool call JSON arguments (primary path).
    Deterministic extraction from report_review_verdict tool output.
    @since 2.223.0 *)
val parse_review_verdict_from_json : Yojson.Safe.t -> (verdict, string) result

val excuse_pattern_observer_fn :
  (pattern:string -> outcome:excuse_pattern_decision -> unit) Atomic.t
val fallback_observer_fn : (mode:string -> runtime:string -> unit) Atomic.t
val run_llm_reviewer_fn :
  (?sw:Eio.Switch.t ->
   evaluator_runtime:string ->
   prompt:string ->
   report_tool_schema:Types_core.tool_schema ->
   unit -> ((verdict option * string), Agent_sdk.Error.sdk_error) result)
  Atomic.t
val is_runtime_permanently_dead_fn :
  (Agent_sdk.Error.sdk_error -> bool) Atomic.t
