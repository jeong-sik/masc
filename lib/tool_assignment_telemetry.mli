(** Tool_assignment_telemetry — Unified tool assignment lifecycle events

    Tracks the full causal chain from tool provision through execution:
    - [Assigned]: which tools were provided to which agent, when, under what policy
    - [Called]: when a provisioned tool was actually invoked
    - [Completed]: the outcome (success/failure, duration, error classification)

    Causal linkage via [assignment_id] allows answering:
    "Agent X was given tools [A,B,C] at T0; tool B was called at T1 and
    failed at T2 with error E."

    Storage: [Dated_jsonl] at [data/tool-events/YYYY-MM/DD.jsonl].
    In-memory index: agent_id → latest assignment_id (survives lookups
    but not server restarts; rebuild via [warm_up]). *)

type assignment_id = string

type tool_event =
  | Assigned of
      { assignment_id : assignment_id
      ; agent_id : string
      ; profile : string
      ; preset : string option
      ; tool_list : string list
      ; allow_set : string list
      ; deny_set : string list
      ; config_hash : string
      ; reason : string
      ; timestamp : float
      }
  | Called of
      { assignment_id : assignment_id
      ; tool_name : string
      ; arguments_hash : string
      ; source : string
      ; timestamp : float
      }
  | Completed of
      { assignment_id : assignment_id
      ; tool_name : string
      ; success : bool
      ; duration_ms : float
      ; error_kind : string option
      ; timestamp : float
      }

val event_to_json : tool_event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (tool_event, string) result

(** Emit an [Assigned] event, update the in-memory agent→assignment index,
    and return the generated [assignment_id].

    [config_hash] defaults to a SHA256 of profile|tool_list|allow_set|deny_set.
    Callers that have a canonical config snapshot should pass it explicitly. *)
val emit_assigned
  :  agent_id:string
  -> profile:string
  -> ?preset:string
  -> tool_list:string list
  -> ?allow_set:string list
  -> ?deny_set:string list
  -> ?config_hash:string
  -> ?reason:string
  -> unit
  -> assignment_id

(** Emit a [Called] event linked to the agent's latest assignment.
    Returns [None] when no assignment exists for the agent. *)
val emit_called
  :  agent_id:string
  -> tool_name:string
  -> ?arguments_hash:string
  -> source:string
  -> unit
  -> assignment_id option

(** Emit a [Completed] event. The caller must supply the [assignment_id]
    (from [emit_called] or direct context). *)
val emit_completed
  :  assignment_id:assignment_id
  -> tool_name:string
  -> success:bool
  -> duration_ms:float
  -> ?error_kind:string
  -> unit
  -> unit

(** Look up the most recent [assignment_id] for an agent. *)
val find_latest_assignment_id : agent_id:string -> assignment_id option

(** Read up to [n] recent events from disk (newest first). *)
val read_recent : n:int -> (tool_event list, string) result

(** Rebuild the in-memory agent→assignment index from existing disk records.
    Called once at server startup. *)
val warm_up : unit -> unit

(** Clear in-memory state (for testing). Does not touch disk. *)
val reset_for_testing : unit -> unit
