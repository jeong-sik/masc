(** Dashboard_harness_health — operator harness-health
    read model over recent eval-calibration verdicts.

    External surface:
    - {b dashboard JSON entry} ({!json}) consumed by
      [server_routes_http_routes_dashboard].

    Stored rows are decoded by {!Eval_calibration.read_window} only. *)

(** {1 Dashboard JSON entry} *)

(** Renders the harness-health dashboard envelope:
    eval-calibration stats and recent verdicts, clipped
    to the [?since] / [?until] window when provided.
    [recent_verdicts_unreadable_count] is the number of rows in the window
    [recent_verdicts] is taken from that the store decoder refused. *)
val json : ?since:string -> ?until:string -> base_path:string -> unit -> Yojson.Safe.t

val cache_key_prefix : string
(** Every dashboard cache key the harness health read is kept under starts
    with this, whatever its workspace and query window. *)


(** {1 Operator labels} *)

type label_request =
  { label_notes_hash : string
  ; label_verdict : Eval_calibration.label_verdict
  ; label_reason : string
  }

val parse_label_body : string -> (label_request, string) result
(** Parse the harness-label POST body:
    [{"notes_hash": <64 hex>, "verdict": "approve" | "reject",
      "reason": <string>}].
    The verdict is the one the human holds, not agreement with the machine:
    divergence mining compares it against the evaluator's verdict under the
    same notes hash. *)

val record_operator_label : base_path:string -> labeler:string -> label_request -> unit
(** Append the label to the calibration ledger, joined to its verdict by
    [label_notes_hash]. *)
