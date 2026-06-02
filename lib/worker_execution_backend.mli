(** Worker_execution_backend — closed variant naming the
    container runtime a worker executes against, with
    JSON / string codecs.

    Used by [Worker_container_types.runtime_backend] (the field
    every worker spec carries) and dispatched on by
    [Worker_container_runners] to pick between in-process
    [Local_playground] execution and a real [Docker] container.

    The variant is intentionally closed: a future "k8s" or
    "podman" backend must extend the type, failing every
    pattern-match site at compile time rather than silently
    routing to one of the existing arms. *)

type t =
  | Local_playground
  | Docker

val to_string : t -> string
(** ["local_playground"] / ["docker"] — canonical lower-snake
    form used in JSONL persistence and operator output. *)

val of_string : string -> t option
(** Inverse of {!to_string}, accepting an extra ["local"] alias
    for [Local_playground] and trimming / lowercasing the input.
    Returns [None] for any unknown value (no silent fallback). *)

val to_yojson : t -> Yojson.Safe.t
(** Wraps {!to_string} as [`String _]. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict JSON decoder — only [`String s] is accepted, with
    [s] forwarded to {!of_string}. Returns [Error] for unknown
    string values and for non-string JSON, with the value
    surfaced in the error message for debuggability. *)
