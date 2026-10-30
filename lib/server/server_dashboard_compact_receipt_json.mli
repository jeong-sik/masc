(** Compact-receipt JSON builders for the dashboard composite endpoint. *)

val compact_receipt_error_json : Yojson.Safe.t -> Yojson.Safe.t
(** Preserve both attempt scopes: [attempt_count] belongs to the selected
    runtime, [lane_attempt_count] counts dispatched runtime candidates. Missing
    observations remain null; fallback is copied from the producer receipt. *)
val compact_receipt_runtime_json : Yojson.Safe.t -> Yojson.Safe.t
