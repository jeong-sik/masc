(** Exact original Task inspection from a creation or answered Ask. Origin facts
    stay separate from Task/history/submission observations and authorize no replay. *)
type receipt =
  | Unobserved of int
  | Recorded of { task_id : string; backlog_version : int }
  | Ambiguous of { task_ids : string list; backlog_version : int }
type error =
  | Workspace_unconfirmed of string
  | Read_failed of string
  | Invalid_reply of string
  | Interrupted

type t
type request = string Masc_tui_fetched.request
type ask_origin = private {
  ao_keeper : string; ao_ask_id : string; ao_task_id : string;
  ao_answered_at : float; ao_stimulus_id : string;
  ao_workspace : Masc.Tui_decode.server_identity;
}
type origin = Task_creation of Masc_tui_task_dispatch.intent | Answered_ask of ask_origin
val create : Masc_tui_task_dispatch.intent -> t
(** Allocate an unread source; prepare its document on explicit transport
    capture/start, without formatting every creation that is never inspected. *)
val create_ask : keeper:string -> ask_id:string -> workspace:Masc.Tui_decode.server_identity ->
  identity:Masc.Tui_decode_asks.ask_followup_identity -> task:Masc.Tui_decode_asks.ask_linked_task ->
  (t,error) result
(** Capture only the canonical answer's recorded Task link. Missing/unavailable
    Task observations still carry a link; unlinked does not. Never manufacture
    a creation receipt or borrow current Keeper/global Task rows. *)
val origin : t -> origin
val workspace : t -> Masc.Tui_decode.server_identity option
val arguments : t -> ((string * Yojson.Safe.t) list, error) result
val decode : t -> Masc_tui_mcp.outcome -> (receipt, error) result
(** Validate the original opaque request, both workspace paths, positive backlog
    revision and exact receipt shape/cardinality. Unobserved is not no-effect;
    recorded is creation evidence, not current existence/status/completion. *)
val start : t -> t * request option
val is_current : t -> request -> bool
val complete : t -> request -> (receipt, error) result -> t
val suspend : reason:error -> t -> t
val observation : t -> (receipt, error) Masc_tui_fetched.observation option
(** None for an Ask origin: no creation source exists for that anchor. *)
val pending : t -> bool
val recorded_task : t -> string option
(** Exact original Task from its anchor: ready single creation fact or captured
    canonical Ask link. This does not prove present Task existence/status. *)
val capture_transport : Masc_tui_task_dispatch.progress -> t -> t
val document : t -> Masc_tui_detail_reading.t
val move : count:int -> height:int -> Masc_tui_detail_reading.movement -> t -> t
val search_key : width:int -> height:int -> key:string -> t -> t option
(** Search the displayed original document before dispatching source controls.
    [None] leaves the key to those controls. Query editing consumes printable
    keys and Esc without changing the origin, read tickets or draft. *)
val search_insert : width:int -> height:int -> text:string -> t -> t
(** Paste into an editing query only; otherwise leave the source unchanged. *)

type task_request
type task_snapshot
val prepare_task : task_id:string -> Masc.Tui_decode_task_inspection.observation ->
  (task_snapshot, error) result
(** Pure full Task formatting; run with response decoding on the CPU worker. *)
val start_task : t -> t * task_request option
val task_request_id : task_request -> int64
val task_request_key : task_request -> string
val task_is_current : t -> task_request -> bool
val task_observation : t ->
  (Masc.Tui_decode_task_inspection.observation, error) Masc_tui_fetched.observation
val task_pending : t -> bool
val complete_task : t -> task_request ->
  (task_snapshot, error) result -> t
val back_to_origin : t -> t
(** A Task read remains attached to its original creation ticket or Ask anchor.
    Closing/suspending/history selection retires it independently of transport. *)

type source = Origin | Task | History | Evidence
val displayed_source : t -> source
type history_request
type history_snapshot
val start_history : earlier:bool -> limit:int -> t -> t * history_request option
val history_page_request : history_request -> Masc.Tui_decode_task_inspection.history_request
val history_request_id : history_request -> int64
val history_is_current : t -> history_request -> bool
val prepare_history : Masc.Tui_decode_task_inspection.history -> history_snapshot
val complete_history : t -> history_request -> (history_snapshot,error) result -> t
val history_observation : t -> (Masc.Tui_decode_task_inspection.history,error) Masc_tui_fetched.observation

type evidence_source = From_task | From_history
type selection_observation =
  | Selection_observed
  | Selection_refreshing
  | Selection_retained of error
  | Selection_retrying of error
type evidence_basis = private {
  eb_source : evidence_source;
  eb_observation : selection_observation;
}
val evidence_basis : t -> evidence_basis option
(** Immutable source/observation state when the exact submission was selected.
    A retained or pending source can name a previously observed submission for
    read-only inspection, not authorize effects or assert current Task status.
    Refreshing Evidence keeps this original basis even if source state changes.
    [None] means no selection bound to this original Task, not no stored proof. *)
type evidence_request
type evidence_snapshot
val start_evidence : next:bool -> t -> t * evidence_request option
(** Explicit next/first observed submission. Ready and retained same-original
    Task/history values supply ids; absent/loading/failed-without-value sources
    do not. Capture their selection-time basis, preserving source order and
    exact-id deduplication. Refresh in Evidence keeps its exact original
    submission and basis; no current/freshness/execution authority is inferred. *)
val evidence_task_id : evidence_request -> string
val evidence_verification_id : evidence_request -> string
val evidence_request_id : evidence_request -> int64
val evidence_is_current : t -> evidence_request -> bool
val prepare_evidence : task_id:string -> verification_id:string ->
  Masc.Tui_decode.verification_evidence -> (evidence_snapshot,error) result
val complete_evidence : t -> evidence_request -> (evidence_snapshot,error) result -> t
val evidence_observation : t -> (Masc.Tui_decode.verification_evidence,error) Masc_tui_fetched.observation
