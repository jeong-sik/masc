(** The consumers that keep tool request originals under
    [tool-request-owners], told apart by the scope their records are stored
    under.

    The install preflight and the startup pass over the settled archive each
    decide per consumer, and both match this type without a wildcard. A scope
    the preflight accepts is therefore a scope the pass can classify. A
    consumer that is missing here is refused by the preflight once it has a
    live record, and one that is added here has to be answered in both before
    the tree compiles. *)

(** A consumer that keeps every original under one scope. *)
type one_scope =
  | Workspace_curator
  | Completion_review
  | Goal_proof_review
  | Candle_appraisal
[@@deriving enumerate]

type t =
  | Librarian of Keeper_librarian_store_preflight.purpose
      (** A Librarian scope is named by the producer that owns its kind. *)
  | One_scope of one_scope

val scope : one_scope -> string
(** The scope the consumer's own module retains its originals under. *)

val of_scope : string -> t option
(** The consumer whose originals are stored under the scope, or [None] when no
    consumer of this build keeps originals there. *)
