(** #9774: shared formatters for governance / operator judge diagnostics. *)

val truncate_with_marker : ?max_bytes:int -> string -> string
(** Trim [s] to [max_bytes] bytes (default 500), appending an ellipsis
    marker recording how many bytes were dropped. *)

val format_lenient_fallback : judge_label:string -> string -> string
(** Format the unparseable-response error string for a judge that hit
    the [Lenient_json.parse] [\`Assoc [("raw", _)]] fallback. The
    output is consumed both as the warn log payload and as the [Error]
    returned upstream. *)
