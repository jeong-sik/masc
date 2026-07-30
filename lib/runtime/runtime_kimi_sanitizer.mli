(** Runtime_kimi_sanitizer — Auto-healing sanitizer for broken Kimi provider wire chunks. *)

(** [sanitize_wire_chunk raw_json] repairs provider-specific wire corruptions,
    such as Kimi's missing byte delimiter ["finish_reasonhoices"] ->
    ["finish_reason": null}, "choices"]. *)
val sanitize_wire_chunk : string -> string
