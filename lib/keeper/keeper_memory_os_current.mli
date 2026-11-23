(** Read-only view and boot quarantine of a Keeper's ordinary current Memory OS
    snapshot ([<keeper>.memory-current.json]).

    All mutations flow through the single-writer Memory store
    ({!Librarian_store} / {!Librarian_writer}), which appends to
    [<keeper>.memory-log.jsonl] and rewrites this snapshot atomically.
    Source-bound explicit claims live in {!Keeper_memory_source_current}. A
    missing file means fresh empty state. *)

type source_kind = Keeper_memory_os_current_types.source_kind =
  | Librarian
  | Explicit_write
  | Explicit_retract

type source = Keeper_memory_os_current_types.source =
  { kind : source_kind
  ; trace_id : string
  }

(** A derived fact that did not survive truth maintenance because no complete
    proof path remained current. [missing_premise_ids] is the union of premises
    absent from the maintained fixed point across its derivations. *)
type support_invalidation = Keeper_memory_os_current_types.support_invalidation =
  { fact : Keeper_memory_os_types.fact
  ; missing_premise_ids : string list
  }

type change = Keeper_memory_os_current_types.change =
  { added : Keeper_memory_os_types.fact list
  ; removed : Keeper_memory_os_types.fact list
  ; retained : int
  ; invalidated : support_invalidation list
  }

type t = Keeper_memory_os_current_types.t =
  { revision : int
  ; updated_at : float
  ; source : source
  ; facts : Keeper_memory_os_types.fact list
  ; change : change
  }

val suffix : string

val path_for_keepers_dir : keepers_dir:string -> keeper_id:string -> string

val source_kind_to_string : source_kind -> string

val to_json : t -> Yojson.Safe.t

val snapshot_sha256 : t -> string
(** SHA-256 of the exact canonical bytes the writer stores for [t]. *)

(** Classified outcome of one snapshot read so callers can tell a decode
    rejection apart from a filesystem failure without matching on message
    text. *)
type read_classified =
  | No_snapshot
  | Readable of t
  | Undecodable of { rejection : string }
  | Io_unreadable of { detail : string }

val read_classified : keepers_dir:string -> keeper_id:string -> read_classified
(** Non-mutating classified read. *)

val read_for_keepers_dir :
  keepers_dir:string -> keeper_id:string -> (t option, string) result

val read_with_snapshot_sha256 :
  keepers_dir:string -> keeper_id:string -> ((t * string) option, string) result
(** Read one atomically replaced snapshot and return the lowercase SHA-256 of
    its exact stored bytes alongside the decoded value. *)

val keeper_id_of_filename : string -> string option
(** Parse this store's filename suffix without filesystem access. *)

val list_keeper_ids_for_keepers_dir : keepers_dir:string -> string list

val list_keeper_ids_with_suffix :
  keepers_dir:string -> suffix:string -> (string list, string) result
(** The owners of [<id><suffix>] files in [keepers_dir]. An inaccessible
    inventory is an error, not an empty store. *)

(** {1 Boot-time reconcile} *)

type boot_observation =
  | Boot_absent
  | Boot_readable
  | Boot_undecodable of
      { rejection : string
      ; snapshot_sha256 : string
      }
  | Boot_unreadable of { detail : string }

val inspect_for_boot : keepers_dir:string -> keeper_id:string -> boot_observation
(** Read-only boot and preflight check. Only a decoder rejection of the
    observed regular snapshot produces [Boot_undecodable]; unavailable paths
    and other I/O errors are [Boot_unreadable]. *)

val move_aside_for_keepers_dir
  :  ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> keepers_dir:string
  -> keeper_id:string
  -> now:float
  -> rejection:string
  -> expected_snapshot_sha256:string
  -> unit
  -> (string, string) result
(** Move one keeper's undecodable current snapshot to a fresh [.rejected-<now>]
    path after the operator accepted boot quarantine. Under the snapshot lock,
    re-reads the file and requires the exact [expected_snapshot_sha256] and the
    same decoder [rejection] before moving. *)

val rejected_base : string -> string option
(** The name a quarantined [<name>.rejected-<epoch>] or
    [<name>.rejected-<epoch>-<n>] was moved from. *)

(** How the basis of a claim seen again combines with the stored one: an
    observation outranks a derivation, a Board reference outranks the
    transcript, and two Board references keep the first. *)
val merge_basis
  :  Keeper_memory_os_types.basis
  -> Keeper_memory_os_types.basis
  -> Keeper_memory_os_types.basis

module For_testing : sig
  val decode_snapshot : string -> (t, string) result
  (** Decode captured snapshot bytes only. *)
end
