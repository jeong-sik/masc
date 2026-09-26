(** How each durable store is read, one record per store.
    {!Keeper_durable_store.reader} routes each store to its record. The
    module is private to the library. *)

type report =
  { rows : int
  ; refused : int
  ; first_refusal : string option
  }

type store_scan =
  { store : string
  ; on_refusal : string
  ; scan : base_path:string -> (report, string) result
  }

val keeper_meta_store : store_scan
val memory_os_current_store : store_scan
val gate_pending_store : store_scan
val official_client_session_store : store_scan
val librarian_range_receipt_store : store_scan
val memory_source_current_store : store_scan
val disposition_receipt_store : store_scan
val board_posts_store : store_scan
val provider_input_store : store_scan
val turn_record_store : store_scan
val turn_boundary_store : store_scan
val librarian_progress_store : store_scan
val librarian_official_progress_store : store_scan
val turn_fragment_store : store_scan
val memory_absorbed_store : store_scan
val memory_os_events_store : store_scan
