(** Dashboard_harness_health — operator harness-health
    read model over recent eval-calibration verdicts.

    External surface:
    - {b records} ({!harness_verdict_item}) reached as a type
      or via record-pattern access by callers.
    - {b verdict readers} ({!read_recent_verdicts},
      {!read_recent_verdicts_for_agents}) consumed by the
      keeper monitoring HTTP route.
    - {b dashboard JSON entry} ({!json}) consumed by
      [server_routes_http_routes_dashboard].

    Internal helpers stay private at this boundary
    ([rail_status] type, [date_bounds] /
    [start_date] / [end_date], [max_recent_verdicts],
    [read_store_records], [verdict_item_of_json],
    every other private accumulator). *)

(** {1 Verdict record} *)

(** One row of the recent harness verdicts ledger.
    Reached as a type by [dashboard_http_keeper] and as
    record-pattern access by the eval-calibration HTTP
    surface. *)
type harness_verdict_item =
  { timestamp : float
  ; task_id : string
  ; task_title : string
  ; agent_name : string
  ; gate : string
  ; verdict : string
  ; evaluator_runtime : string
  ; fallback_reason : string option
  ; notes_hash : string
    (** The calibration correlation key: a human label recorded against this
        hash joins this verdict in {!Eval_calibration.find_divergences}. *)
  }

(** {1 Verdict readers} *)

(** Returns the most recent calibration verdicts.
    [?since] / [?until] are ISO-date strings; [?limit]
    defaults to the internal [max_recent_verdicts] cap. *)
val read_recent_verdicts
  :  ?since:string
  -> ?until:string
  -> ?limit:int
  -> base_path:string
  -> unit
  -> harness_verdict_item list

(** Filtered variant of {!read_recent_verdicts} — keeps
    only verdicts whose [agent_name] matches a (trimmed,
    non-empty) entry of [agent_names].  Returns [\[\]]
    when the filter list is empty after trimming. *)
val read_recent_verdicts_for_agents
  :  ?since:string
  -> ?until:string
  -> ?limit:int
  -> base_path:string
  -> agent_names:string list
  -> unit
  -> harness_verdict_item list

(** {1 Dashboard JSON entry} *)

(** Renders the harness-health dashboard envelope:
    eval-calibration stats and recent verdicts, clipped
    to the [?since] / [?until] window when provided. *)
val json : ?since:string -> ?until:string -> base_path:string -> unit -> Yojson.Safe.t

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
