(** Runtime-lens gap rendering and swimlane helpers. *)

type runtime_lens_gap =
  { code : string
  ; severity : string
  ; lane : string
  ; detail : string option
  }

val runtime_lens_gap_json : runtime_lens_gap -> Yojson.Safe.t

val runtime_lens_event_count :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Keeper_runtime_manifest.event_kind ->
  int

val runtime_lens_swimlane_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  runtime_lens_gap list ->
  lane:string ->
  label:string ->
  events:Keeper_runtime_manifest.event_kind list ->
  terminal_status:string ->
  synthetic_events:(string * int) list ->
  Yojson.Safe.t

val runtime_lens_keeper_terminal_status :
  terminal_event_present:bool ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  string

val runtime_lens_memory_terminal_status :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan -> string

type lane_policy =
  { lane : string
  ; mandatory_events : Keeper_runtime_manifest.event_kind list
  ; terminal_events : Keeper_runtime_manifest.event_kind list
  }

val lane_policies : lane_policy list
val event_lane : Keeper_runtime_manifest.event_kind -> string

(** [runtime_lens_swimlane_completeness scan lane] reads the lane policy for
    [lane] and returns one of four strings.

    - ["complete"] — every event in [mandatory_events] has at least one row in
      [scan], and, when [terminal_events] is non-empty, at least one of those
      also has a row.
    - ["finished"] — a terminal event has a row but a mandatory event does not.
    - ["mandatory_present"] — every mandatory event has a row but no terminal
      event does.
    - ["incomplete"] — neither holds.

    A lane with no policy has nothing to check and reads ["complete"]. A lane
    whose [terminal_events] is empty is never asked for one, so it reads
    ["complete"] as soon as its mandatory events are present.

    This reads the raw policy verdict. The swimlane JSON reports the rendered
    verdict instead, which returns ["not_observed"] for a lane the response
    carries no events for. *)
val runtime_lens_swimlane_completeness :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  string ->
  string