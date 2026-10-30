(** Typed [tool_error] surface for LLM-facing tool failures.
    See [docs/rfc/RFC-0148-typed-tool-error-variant.md] for design.

    Closed sum type — adding a variant forces all callers to handle it
    (compiler-enforced exhaustive match).  Replaces ~30 catch-all
    [Failure msg] sites at the tool execution boundary. *)

(** {1 Type} *)

type t =
  | Not_found of { what : string }
      (** Lookup failed: file / table / symbol not present.
          [what] is operator-facing (logged) and LLM-facing (in [to_json]). *)
  | Permission_denied of { path : string }
      (** Access denied — distinguish from [Not_found] so LLM can choose
          a different strategy (skip vs retry-with-different-path). *)
  | Invalid_input of { detail : string }
      (** Argument validation failed at the boundary.  Tool was called
          with malformed input. *)
  | Resource_exhausted of { resource : string; detail : string }
      (** A bounded resource is unavailable (fd, memory, quota, etc.).
          [resource] enumerates the resource family; [detail] explains. *)
  | Timeout of { stage : string; elapsed_sec : float }
      (** Operation exceeded its deadline.  [stage] names the timed-out
          phase (e.g. [slot_wait], [spawn], [command], [llm_response]). *)
  | Cancelled of { reason : string }
      (** Cooperative cancellation — distinct from timeout.  [reason]
          should be the trigger (parent fiber, user signal, etc.). *)
  | Internal_error of { detail : string; exn : exn option }
      (** Last-resort variant for unclassified failures.  [exn] preserves
          the original exception object for in-process debugging; it is
          {b not} serialised to JSON (see [to_json]).

          Adding new variants {b reduces} use of this constructor.  A
          backsliding lint should track direct callers of
          [Internal_error]. *)

(** {1 Construction helpers} *)

val of_exn : ?detail:string -> exn -> t
(** Map an arbitrary exception into the most specific variant.
    Recognised:
    - [Not_found] -> [Not_found { what = detail }]
    - [Failure msg] -> [Internal_error { detail = msg; exn = Some e }]
    - [Sys_error msg] -> [Internal_error { detail = msg; exn = Some e }]
    - [Unix.Unix_error (EACCES, _, path)] -> [Permission_denied { path }]
    - [Unix.Unix_error (ENOENT, _, path)] -> [Not_found { what = path }]
    - [Unix.Unix_error ((EMFILE | ENFILE), op, _)] ->
        [Resource_exhausted { resource = "fd"; detail = op }]
    - Anything else -> [Internal_error { detail; exn = Some e }]

    [detail] overrides the default detail string when supplied. *)

(** {1 Serialisation} *)

val kind : t -> string
(** Constructor tag in lower_snake_case, suitable for the [kind] field of
    [to_json] (e.g. [Not_found _ -> "not_found"]).  Stable; LLM prompts
    pattern-match this value. *)

val to_json : t -> Yojson.Safe.t
(** LLM-facing wire format.  Schema:
    {v
    { "kind": "<kind>", ...record fields exposed as JSON members... }
    v}

    The [Internal_error.exn] field is {b never} included in the JSON
    output — it stays in-process for debug logs only. *)

val to_string : t -> string
(** Human-readable single-line summary, suitable for logs.
    Includes the [kind] tag and the discriminating field(s). *)
