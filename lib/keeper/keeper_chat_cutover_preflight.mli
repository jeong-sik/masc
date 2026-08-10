(** One-shot safety boundary for the Keeper chat-operation hard cut.

    The new Owner inventory must not start while storage owned by the removed
    chat implementation is still present.  This module is deliberately
    read-only: it inventories the old files and reports the work that would be
    stranded.  Archival is an explicit deployment action. *)

type queue_counts =
  { total : int
  ; pending : int
  ; inflight : int
  ; recovery_required : int
  ; terminal : int
  }

type queue_database =
  { keeper_name : string
  ; path : string
  ; counts : queue_counts
  }

type artifact =
  { keeper_name : string
  ; path : string
  }

type report =
  { queue_databases : queue_database list
  ; queue_sidecars : artifact list
  ; direct_delivery_directories : artifact list
  ; direct_marker_count : int
  }

type error =
  | Filesystem_error of
      { path : string
      ; detail : string
      }
  | Unexpected_file_kind of
      { path : string
      ; expected : string
      ; actual : string
      }
  | Queue_database_error of
      { path : string
      ; detail : string
      }

val inspect : keepers_root:string -> (report, error) result
val is_clear : report -> bool
val artifact_count : report -> int
val active_queue_row_count : report -> int
val stranded_work_count : report -> int
val error_to_string : error -> string
val report_to_yojson : report -> Yojson.Safe.t
val report_to_string : report -> string
