(** The durable stores the deploy preflight's [validate-stores] and boot
    reconcile read, in one list, with the boot policy each one gets.

    Both readers take their stores from {!Id.all}, which is derived, so a
    store cannot be in the list for one and missing for the other. The
    helper's other subcommands ([validate-current-meta], the event queue,
    schedule ledger and signals) still find their own files; RFC
    every-durable-store-has-one-boot-policy moves them here in later steps.

    {!reader} is the one table. It sends each store to one of three policies
    (RFC every-durable-store-has-one-boot-policy, RFC-0420, RFC-0444 §2.4):
    - [Refuse_boot]: boot decodes every file before any keeper loop starts
      and refuses to start while one is undecodable, unless the operator
      passes [--accept-store-quarantine]. Keeper meta and memory current are
      here: without them a keeper starts as another keeper or with empty
      memory, and overwrites what it lost. The deploy preflight reads them
      too.
    - [Degrade_typed]: boot decodes it once and logs one INFO line when it is
      unavailable. Keepers run without it and nothing overwrites it, so the
      deploy preflight does not read it (the goal store).
    - [Preflight_only]: boot does not read it. Its readers meet an
      undecodable file at run time, and the deploy preflight is the one
      place that reads it before a start.

    A store boot refuses on is named twice, as an {!Id.t} and as a
    {!Refusing.t}; boot's examiner, name and move-aside method match
    exhaustively on {!Refusing.t}, so sending a store to [Refuse_boot] does
    not compile until boot knows how to read and move it. *)

(** Every store. *)
module Id : sig
  type t =
    | Keeper_meta
    | Gate_pending
    | Official_client_session
    | Memory_current
    | Goal_store
    | Librarian_range_receipts
    | Memory_source_current
    | Disposition_receipts
    | Board_posts
    | Provider_inputs
    | Turn_records
    | Turn_boundaries
    | Librarian_progress
    | Librarian_official_progress
    | Turn_fragments
    | Memory_absorbed
    | Memory_os_events
  val all : t list
  (** Every constructor in declaration order, derived by
      [\[@@deriving enumerate\]]. *)
end

(** The stores boot refuses on. *)
module Refusing : sig
  type t =
    | Keeper_meta
    | Memory_current

  val all : t list
end

(** The stores boot reads once and reports. *)
module Reported : sig
  type t = Goal_store

  val all : t list
end

type report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

type scan

type reader =
  | Refuse_boot of Refusing.t * scan
  | Degrade_typed of Reported.t
  | Preflight_only of scan

val reader : Id.t -> reader

val name : Id.t -> string
(** The name the preflight prints, e.g. ["board posts"]. *)

val preflight_scan : Id.t -> scan option
(** What the deploy preflight reads: the scan of every [Refuse_boot] and
    [Preflight_only] store, and [None] for a [Degrade_typed] one. *)

val run : scan -> base_path:string -> (report, string) result
(** Decode every file or row of the store under [base_path] with this
    build's reader. Reads only: nothing is created, moved or written.
    [Error] means the store could not be listed at all; a file or row that
    does not decode is counted in [refused]. A [Degrade_typed] store has no
    {!scan}, so the preflight cannot read it. *)

val on_refusal : scan -> string
(** What the running server does with a file or row of this store it cannot
    decode, for the operator reading the preflight's refusal. *)
