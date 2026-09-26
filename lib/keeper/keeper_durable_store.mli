(** Every durable store this build decodes, in one list, with the boot policy
    each one gets.

    The deploy preflight ([deployment_preflight_helper validate-stores]) and
    boot ({!Keeper_store_boot_reconcile}) both read this list; neither keeps
    its own. When each kept one, the preflight knew 16 stores and boot three,
    so a build started outside the deploy script never read the other 14. On
    2026-09-26 a [masc start] booted a build whose official-client session
    schema had moved from v1 to v2 (#38986): the preflight knew that store,
    boot did not, and every official-client keeper failed each turn until
    the files were moved by hand.

    Which stores boot reads is carried on the type (RFC
    every-durable-store-has-one-boot-policy, RFC-0420, RFC-0444 §2.4):
    - [refuse_boot]: boot decodes every file before any keeper loop starts
      and refuses to start while one is undecodable, unless the operator
      passes [--accept-store-quarantine]. A store is here when a writer
      would overwrite what it could not read (keeper meta, memory current)
      or when its keeper cannot take a turn while the file is unreadable
      (official-client session).
    - [degrade_typed]: boot decodes it once and logs one INFO line when it is
      unavailable. Its readers report the failure and no writer overwrites
      the file, so keepers run without it (the goal store).
    - [preflight_only]: boot does not read it. Its readers meet an
      undecodable file at run time, and the deploy preflight is the one
      place that reads it before a start.

    The preflight decodes every store whatever its boot policy and refuses
    the deploy on any refusal. A new constructor of {!t} does not compile
    until it has a policy, an {!Id.t}, a name and a scan. *)

type refuse_boot = [ `Refuse_boot ]
type degrade_typed = [ `Degrade_typed ]
type preflight_only = [ `Preflight_only ]

type _ t =
  | Keeper_meta : refuse_boot t
  | Memory_current : refuse_boot t
  | Goal_store : degrade_typed t
  | Gate_pending : preflight_only t
  | Official_client_session : refuse_boot t
  | Librarian_range_receipts : preflight_only t
  | Memory_source_current : preflight_only t
  | Disposition_receipts : preflight_only t
  | Board_posts : preflight_only t
  | Provider_inputs : preflight_only t
  | Turn_records : preflight_only t
  | Turn_boundaries : preflight_only t
  | Librarian_progress : preflight_only t
  | Librarian_official_progress : preflight_only t
  | Turn_fragments : preflight_only t
  | Memory_absorbed : preflight_only t
  | Memory_os_events : preflight_only t

type _ boot_policy =
  | Refuse_boot : refuse_boot boot_policy
  | Degrade_typed : degrade_typed boot_policy
  | Preflight_only : preflight_only boot_policy

val policy : 'a t -> 'a boot_policy
(** Read off the type index. Moving a store to another policy changes its
    index, and every match on {!policy} that routes the store stops
    compiling until its examiner changes too. *)

(** The flat name of each store, so the list can be derived. *)
module Id : sig
  type t =
    | Keeper_meta
    | Memory_current
    | Goal_store
    | Gate_pending
    | Official_client_session
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

type any = Any : _ t -> any

val id : _ t -> Id.t
val of_id : Id.t -> any

val all : any list
(** {!of_id} over {!Id.all}. Nobody writes this list by hand, so a store
    cannot be in it for the preflight and missing for boot. *)

val name : _ t -> string
(** The name the preflight prints, e.g. ["board posts"]. *)

val on_refusal : _ t -> string
(** What the running server does with a file or row of this store it cannot
    decode, for the operator reading the preflight's refusal. *)

type report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

val scan : _ t -> base_path:string -> (report, string) result
(** Decode every file or row of the store under [base_path] with this
    build's reader. Reads only: nothing is created, moved or written. [Error]
    means the store could not be listed at all; a file or row that does not
    decode is counted in [refused]. *)
