(** Original Task creation inspection. Read-only evidence stays separate from
    the original creation transport outcome and never authorizes a replay. *)
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
val create : Masc_tui_task_dispatch.intent -> t
(** Allocate an unread source; prepare its document on explicit transport
    capture/start, without formatting every creation that is never inspected. *)
val origin : t -> Masc_tui_task_dispatch.intent
val arguments : t -> ((string * Yojson.Safe.t) list, error) result
val decode : t -> Masc_tui_mcp.outcome -> (receipt, error) result
(** Validate the original opaque request, both workspace paths, positive backlog
    revision and exact receipt shape/cardinality. Unobserved is not no-effect;
    recorded is creation evidence, not current existence/status/completion. *)
val start : t -> t * request option
val is_current : t -> request -> bool
val complete : t -> request -> (receipt, error) result -> t
val suspend : reason:error -> t -> t
val observation : t -> (receipt, error) Masc_tui_fetched.observation
val pending : t -> bool
val recorded_task : t -> string option
(** Only the current ready single creation fact; caller still owns workspace
    admission and an explicit new read of the Task's current state. *)
val capture_transport : Masc_tui_task_dispatch.progress -> t -> t
val document : t -> Masc_tui_detail_reading.t
val move : count:int -> height:int -> Masc_tui_detail_reading.movement -> t -> t

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
val task_on_screen : t -> bool
val back_to_creation : t -> t
(** A Task read remains attached to its original single ready creation ticket.
    Closing/suspending/history selection retires it independently of transport. *)
