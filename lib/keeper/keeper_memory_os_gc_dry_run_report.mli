(** Read-only operator report for Memory OS fact-store GC dry-runs. *)

type keeper_error =
  | Missing_fact_store of { facts_path : string }
  | Corrupt_fact_store of { message : string }
  | Fact_store_access_error of { message : string }
  | Fact_store_locked of
      { caller : string
      ; lock_path : string
      ; attempts : int
      }

type keeper_result =
  | Keeper_ok of
      { keeper_id : string
      ; total_input : int
      ; ttl_expired : int
      ; ttl_expired_ephemeral : int
      ; ttl_expired_non_ephemeral : int
      ; ttl_expired_by_category : (string * int) list
      ; dedup_removed : int
      ; written : int
      }
  | Keeper_error of
      { keeper_id : string
      ; error : keeper_error
      }

type t =
  { keepers_dir : string
  ; keeper_ids_known : bool
  ; keeper_id_discovery_read_errors : string list
  ; results : keeper_result list
  ; total_input : int
  ; ttl_expired : int
  ; ttl_expired_ephemeral : int
  ; ttl_expired_non_ephemeral : int
  ; ttl_expired_by_category : (string * int) list
  ; dedup_removed : int
  ; written : int
  ; error_count : int
  }

val run_for_keepers_dir
  :  keepers_dir:string
  -> ?keeper_ids:string list
  -> now:float
  -> unit
  -> t
(** Scan keeper fact stores and run {!Keeper_memory_os_gc.run_gc_for_keepers_dir}
    with [dry_run:true]. Must be called inside an Eio context because the GC
    path takes the per-keeper facts lock. If [keeper_ids] is omitted, every
    existing non-shared [*.facts.jsonl] store in [keepers_dir] is scanned.
    Discovery failures are reported through [keeper_ids_known=false] and
    [keeper_id_discovery_read_errors], not as an empty fleet. If [keeper_ids] is
    provided, missing stores are reported as per-keeper errors instead of
    silently returning an empty report. *)

module For_testing : sig
  val run_for_keepers_dir
    :  keepers_dir:string
    -> run_gc_for_keepers_dir:
         (keepers_dir:string
          -> dry_run:bool
          -> keeper_id:string
          -> now:float
          -> unit
          -> Keeper_memory_os_gc.gc_report)
    -> ?keeper_ids:string list
    -> now:float
    -> unit
    -> t
end

val to_json : t -> Yojson.Safe.t
val render_text : t -> string
