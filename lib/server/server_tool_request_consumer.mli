(** The consumers that keep tool request originals under
    [tool-request-owners], told apart by the scope their records are stored
    under.

    The install preflight and the startup pass over the settled archive each
    decide per consumer, and both match this type without a wildcard. A scope
    the preflight accepts is therefore a scope the pass can classify, and a
    consumer that is added here has to be answered in both before the tree
    compiles.

    [Lane_addon_tool_request_owner.retain] takes its scope as a string, so
    nothing ties a consumer to this type when it starts keeping originals.
    One that is missing here stops the pass at every boot from its first live
    record, and the next install preflight refuses that record. *)

(** Each consumer keeps every original under one scope. *)
type t =
  | Workspace_curator
  | Completion_review
  | Goal_proof_review
  | Candle_appraisal
  | Media_reading
[@@deriving enumerate]

val scope : t -> string
(** The scope the consumer's own module retains its originals under. *)

val of_scope : string -> t option
(** The consumer whose originals are stored under the scope, or [None] when no
    consumer of this build keeps originals there. *)
