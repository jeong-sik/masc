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
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
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

(** [owed_events ~checkpoint_owner events] keeps the events this turn owes.
    [Checkpoint_saved] is owed only when [checkpoint_owner] is
    [Some Masc_agent_core]: an official client keeps its own session and MASC
    never saves an AGENT_CORE checkpoint for it. [None] (owner unknown) keeps
    it owed. Every other event is owed by every turn. The lane verdict and the
    lane gaps both read policies through this one function. *)
val owed_events :
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
  Keeper_runtime_manifest.event_kind list ->
  Keeper_runtime_manifest.event_kind list

(** [finished_turns_checkpoint_owner ~checkpoint_owner_of_runtime_id scan]
    names who held the resumable state of the turns [scan] saw finish. It
    reads the runtime id on each turn_finished row and asks
    [checkpoint_owner_of_runtime_id] for that runtime's owner. [None] when the
    scan has no turn_finished row, a row has no runtime id, the lookup does
    not know an id, or the finished turns have different owners: the scan's
    event counts add up all of its turns, so no single turn's owner may
    excuse an event for the others. *)
val finished_turns_checkpoint_owner :
  checkpoint_owner_of_runtime_id:
    (string -> Runtime_execution.checkpoint_owner option) ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  Runtime_execution.checkpoint_owner option

(** [runtime_lens_swimlane_completeness ~checkpoint_owner scan lane] reads
    the lane policy for [lane], keeps the events this turn owes
    ({!owed_events}), and returns one of five strings.

    - ["not_applicable"] — the policy names events, and this turn owes none
      of them. Nothing was proven and nothing is missing.
    - ["complete"] — every owed mandatory event has at least one row in
      [scan], and, when an owed terminal event exists, at least one of those
      also has a row.
    - ["finished"] — an owed terminal event has a row but an owed mandatory
      event does not.
    - ["mandatory_present"] — every owed mandatory event has a row but no owed
      terminal event does.
    - ["incomplete"] — neither holds.

    A lane with no policy has nothing to check and reads ["complete"]. A lane
    that owes no terminal event is never asked for one, so it reads
    ["complete"] as soon as its owed mandatory events are present.

    This reads the raw policy verdict. The swimlane JSON reports the rendered
    verdict instead, which returns ["not_observed"] for a tool_runtime lane
    the response carries no events for. *)
val runtime_lens_swimlane_completeness :
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  string ->
  string
(** The AGENT_CORE lane includes history projection observations without
    treating them as context injection or checkpoint completion. *)
val runtime_lens_agent_core_swimlane_json :
  Server_dashboard_http_keeper_runtime_manifest_scan.runtime_manifest_scan ->
  runtime_lens_gap list ->
  checkpoint_owner:Runtime_execution.checkpoint_owner option ->
  Yojson.Safe.t
