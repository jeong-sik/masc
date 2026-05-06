(** #9774: shared formatters for governance / operator judge diagnostics. *)

val truncate_with_marker : ?max_bytes:int -> string -> string
(** Trim [s] to [max_bytes] bytes (default 500), appending an ellipsis
    marker recording how many bytes were dropped. *)

val format_lenient_fallback : judge_label:string -> string -> string
(** Format the unparseable-response error string for a judge that hit
    the [Lenient_json.parse] [\`Assoc [("raw", _)]] fallback. The
    output is consumed both as the warn log payload and as the [Error]
    returned upstream. *)

val format_unparseable_response :
  judge_label:string -> reason:string -> string -> string
(** Format a structurally-invalid judge response diagnostic. This path is
    for JSON that parsed but violated the judge output contract. *)

val record_lenient_fallback : judge_label:string -> string -> string
(** Increment the judge fallback metrics and return
    {!format_lenient_fallback}. *)

val record_unparseable_response :
  judge_label:string -> reason:string -> string -> string
(** Increment the judge unparseable metric and return
    {!format_unparseable_response}. *)

val lenient_fallback_metrics_json : judge_label:string -> Yojson.Safe.t
(** Current Prometheus counter values for a judge label, formatted for
    dashboard/runtime JSON surfaces. *)
