(** Read-only operator report for Memory OS fact-store GC dry-runs. *)

type keeper_result =
  | Keeper_ok of
      { keeper_id : string
      ; total_input : int
      ; ttl_expired : int
      ; dedup_removed : int
      ; written : int
      }
  | Keeper_error of
      { keeper_id : string
      ; message : string
      }

type t =
  { keepers_dir : string
  ; results : keeper_result list
  ; total_input : int
  ; ttl_expired : int
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
    existing non-shared [*.facts.jsonl] store in [keepers_dir] is scanned. If it
    is provided, missing stores are reported as per-keeper errors instead of
    silently returning an empty report. *)

val to_json : t -> Yojson.Safe.t
val render_text : t -> string
