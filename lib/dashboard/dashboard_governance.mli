(** Dashboard_governance — Live governance judge status surface.

    Case tracking has been retired; this module now returns judge
    runtime telemetry, approval queue counts, and empty case lists
    for backward-compat consumers. *)

(** {1 JSON surfaces} *)

(** Full dashboard payload with [summary], [judge], [judgments],
    [approval_queue], and empty [items] / [activity] / [cases] /
    [pending_actions] slots. *)
val dashboard_json :
  base_path:string ->
  limit:int ->
  offset:int ->
  status_filter:'a ->
  Yojson.Safe.t
