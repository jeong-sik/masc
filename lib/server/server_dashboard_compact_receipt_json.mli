(** Compact-receipt JSON builders for the dashboard composite endpoint. *)

(** Truncate to [max_chars] (after [String.trim]) with a trailing
    ["..."] when truncated.  Returns [(text, truncated_flag)]. *)
val compact_preview : max_chars:int -> string -> string * bool

val compact_receipt_error_json : Yojson.Safe.t -> Yojson.Safe.t
val compact_receipt_cascade_json : Yojson.Safe.t -> Yojson.Safe.t
val compact_receipt_tool_surface_json : Yojson.Safe.t -> Yojson.Safe.t
