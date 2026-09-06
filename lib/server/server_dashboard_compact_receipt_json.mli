(** Compact-receipt JSON builders for the dashboard composite endpoint. *)

val compact_receipt_error_json : Yojson.Safe.t -> Yojson.Safe.t
val compact_receipt_runtime_json : Yojson.Safe.t -> Yojson.Safe.t
