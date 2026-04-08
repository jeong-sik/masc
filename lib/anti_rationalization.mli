(** Anti-rationalization gate for task completion.

    Verifies that completion notes actually address the task rather than
    containing avoidance patterns ("out of scope", "will do later", etc.).

    Inspired by Trail of Bits' Stop hook anti-rationalization pattern:
    a separate model reviews the primary agent's work before accepting it.

    When the LLM reviewer is unavailable, falls back to local pattern matching
    only. Liveness takes priority over correctness.

    Cross-model evaluation (#3067): use [~evaluator_cascade] to force
    a different model family than the generator, providing genuine
    adversarial tension rather than same-model self-evaluation.

    @since v2.145.0 *)

(** Review request: task context + agent's completion claim. *)
type review_request = {
  task_title : string;
  task_description : string;
  completion_notes : string;
  agent_name : string;
}

(** Gate verdict. *)
type verdict =
  | Approve
  | Reject of string

(** Which gate produced the verdict. Variant type prevents typos that
    would silently compile with a stringly-typed field. *)
type gate =
  | Length
  | Excuse
  | Contract
  | Structured_tool
  | Llm_text_fallback
  | Format_reject
  | Fallback

val gate_to_string : gate -> string
val gate_of_string : string -> (gate, string) result

(** Structured review result with audit metadata for cross-model tracking. *)
type review_result = {
  verdict : verdict;
  evaluator_cascade : string;
  generator_cascade : string option;
  gate : gate;
  fallback_reason : string option;  (** Error message when gate=Fallback *)
}

(** Review a task completion claim with optional cross-model separation.

    @param evaluator_cascade Override cascade for LLM verification.
      Default: ["cross_verifier"]. Use a different cascade name to ensure
      cross-model evaluation (e.g. ["cross_verifier"]).
    @param generator_cascade Optional name of the generator's cascade.
      Logged for auditing; not used in verification logic. *)
val review :
  ?evaluator_cascade:string ->
  ?generator_cascade:string ->
  ?completion_contract:string list ->
  ?on_verdict:(review_result -> unit) ->
  ?few_shot_block:string ->
  ?sw:Eio.Switch.t ->
  review_request -> review_result

(** Backward-compatible wrapper returning only the verdict. *)
val review_verdict :
  ?evaluator_cascade:string ->
  ?generator_cascade:string ->
  ?completion_contract:string list ->
  ?on_verdict:(review_result -> unit) ->
  ?few_shot_block:string ->
  ?sw:Eio.Switch.t ->
  review_request -> verdict

(** Check completion notes against a contract. Returns unmet items.
    Used internally by Gate 2.5; exposed for testing. *)
val check_contract : notes:string -> contract:string list -> string list

(** Serialize review result to JSON for logging/calibration. *)
val review_result_to_json : review_result -> Yojson.Safe.t

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

(** Check notes for known excuse patterns (local, no LLM).
    Returns [Some (pattern, reason)] if a match is found.
    Exposed for testing. *)
val find_excuse_pattern : string -> (string * string) option

(** Parse LLM text output into a verdict (lenient fallback path).
    "APPROVE" -> [Ok Approve], "REJECT: reason" -> [Ok (Reject reason)].
    Unrecognized format returns [Error] instead of silently approving (ADR D3).
    Exposed for testing.
    @since 2.223.0 changed return type from [verdict] to [(verdict, string) result] *)
val parse_verdict : string -> (verdict, string) result

(** Parse verdict from structured tool call JSON arguments (primary path).
    Deterministic extraction from report_review_verdict tool output.
    @since 2.223.0 *)
val parse_review_verdict_from_json : Yojson.Safe.t -> (verdict, string) result
