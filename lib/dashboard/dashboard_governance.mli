(** Dashboard_governance — Live governance judge status surface.

    Case tracking has been retired; this module now returns judge
    runtime telemetry, approval queue counts, and empty case lists
    for backward-compat consumers. *)

type detail_status = [ `OK | `Not_found ]

(** {1 JSON surfaces} *)

(** [factual_snapshot_json ~base_path] returns a minimal snapshot
    used by the bootstrap loops. Items/activity lists are always
    empty. *)
val factual_snapshot_json : base_path:string -> Yojson.Safe.t

(** Full dashboard payload with [summary], [judge], [judgments],
    [approval_queue], and empty [items] / [activity] / [cases] /
    [pending_actions] slots. *)
val dashboard_json :
  base_path:string ->
  limit:int ->
  offset:int ->
  status_filter:'a ->
  Yojson.Safe.t

(** Legacy cases list (now always empty). *)
val cases_json :
  base_path:string ->
  limit:int ->
  offset:int ->
  status_filter:'a ->
  include_test:'b ->
  Yojson.Safe.t

(** Legacy case detail (now always [`Not_found]). *)
val case_detail_json :
  base_path:string ->
  case_id:string ->
  detail_status * Yojson.Safe.t
