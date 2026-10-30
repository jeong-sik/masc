(** Pure projection of dashboard schedule snapshots and exact wake history.
    The loader owns HTTP acquisition; these readers preserve store-read
    uncertainty, producer ordering and absent-versus-negative evidence. *)

val snapshot_of_json :
  Yojson.Safe.t -> (Masc_tui_types.schedule_snapshot, string) result

val wake_history_of_json :
  Yojson.Safe.t -> (Masc_tui_types.schedule_wake_history, string) result
