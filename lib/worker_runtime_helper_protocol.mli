(** Worker_runtime_helper_protocol — wire protocol for worker
    helper subprocess.

    Defines the JSON envelope that [bin/masc_worker_run.ml]
    (the worker helper subprocess) emits on stdout and the
    parent process consumes.  Two shapes:

    - Success: [`Assoc [("ok", <run_result>)]]
    - Error:   [`Assoc [("error", `Assoc [message; kind])]]

    The wire-string [kind] enum is the operator-visible failure
    classification — runbooks key off these literals. *)

(** {1 Error taxonomy} *)

type error_kind =
  | Spec_parse  (** Subprocess failed to parse its input spec. *)
  | Runtime     (** OAS runtime / cascade execution failure. *)
  | Timeout     (** Subprocess hit its execution time budget. *)
  | Internal    (** Catch-all for unexpected failures. *)

type error_payload = {
  message : string;
  kind : error_kind;
}
(** Concrete record because [bin/masc_worker_run.ml] constructs
    it field-by-field on every error path.  The [message] is
    operator-visible (rendered into the JSON-RPC error envelope
    by the parent). *)

val error_kind_to_string : error_kind -> string
(** [error_kind_to_string k] returns the snake_case wire string:
    [spec_parse] / [runtime] / [timeout] / [internal].  Pinned
    at the contract seam — operator alerts grep on these
    literals. *)

val error_kind_of_string : string -> error_kind option
(** [error_kind_of_string s] parses the wire string back to the
    variant.  Case-insensitive, trim-tolerant.  Returns [None]
    for unrecognised values; the parent process logs unknowns
    via {!Log.Misc.warn} and falls back to {!Internal} (issue
    #8705 — subprocess version skew visibility). *)

(** {1 JSON envelope builders} *)

val success_json :
  Worker_container_types.run_result -> Yojson.Safe.t
(** [success_json run_result] wraps [run_result] in an
    [`Assoc [("ok", <run_result>)]] envelope.  Used by
    [bin/masc_worker_run.ml] for the success path. *)

val error_json : error_payload -> Yojson.Safe.t
(** [error_json payload] wraps [payload] in an
    [`Assoc [("error", `Assoc [message; kind])]] envelope.
    Used by [bin/masc_worker_run.ml] for every error path. *)

(** {1 Parent-side parser} *)

val parse_stdout :
  string ->
  ((Worker_container_types.run_result, error_payload) result, string)
  result
(** [parse_stdout stdout] parses the worker helper's stdout
    output.

    {2 Outer result}

    [Ok inner] when the JSON parsed and contains either an [ok]
    or [error] field.  [Error msg] for parse failures or
    malformed envelopes (operator-visible message describing
    the parse problem).

    {2 Inner result}

    [Ok run_result] when the envelope was the success shape;
    [Error error_payload] when it was the error shape.

    {2 Unknown error_kind handling}

    When the [error.kind] wire string is not recognised by
    {!error_kind_of_string}, the parser logs at
    {!Log.Misc.warn}:
    [["worker_runtime_helper: unknown error_kind \"X\" → Internal fallback (#8705)"]]
    and falls back to {!Internal}.  Missing [kind] key silently
    defaults to {!Internal} — that case is the documented
    contract, no warning emitted. *)

(** {1 Re-exported run_result codecs}

    Exposed for callers that need to encode / decode
    {!Worker_container_types.run_result} JSON without going
    through the [ok]/[error] envelope (e.g. tests that inject
    synthetic results into the parser). *)

val run_result_to_yojson :
  Worker_container_types.run_result -> Yojson.Safe.t

val run_result_of_yojson :
  Yojson.Safe.t ->
  (Worker_container_types.run_result, string) result
