(** Event-sourced agent loop journal.

    Records every agent loop action as an immutable event.
    On crash recovery, replays the journal to reconstruct exact state
    without re-executing side-effectful activities.

    Provides fine-grained agent-loop-level event sourcing.

    Key properties:
    - Events are append-only (immutable journal)
    - Side-effectful activities use idempotency keys to skip on replay
    - Full journal is JSON-serializable for persistence

    @since 0.89.0

    @stability Evolving
    @since 0.93.1 *)

(** {1 Event types} *)

(** Canonical envelope type for adapters that project durable journal events
    across runtimes. Journal variants remain unchanged for compatibility.
    @since 0.170.5 *)
type envelope_v2 = Event_envelope.t

val mk_envelope_v2
  :  ?event_id:string
  -> ?correlation_id:string
  -> ?run_id:string
  -> ?event_time:float
  -> ?observed_at:float
  -> ?seq:int
  -> ?parent_event_id:string
  -> ?caused_by:string
  -> ?source_clock:Event_envelope.source_clock
  -> unit
  -> envelope_v2

(** An agent loop event. Each variant captures the data needed
    to replay the action without re-executing it. *)
type event =
  | Turn_started of
      { turn : int
      ; timestamp : float
      }
  | Llm_request of
      { turn : int
      ; model : string
      ; timestamp : float
      }
  | Llm_response of
      { turn : int
      ; input_tokens : int option
      ; output_tokens : int option
      ; stop_reason : string
      ; duration_ms : float
      ; timestamp : float
      }
  | Tool_called of
      { turn : int
      ; tool_name : string
      ; idempotency_key : string
      ; input_hash : string
      ; timestamp : float
      }
  | Tool_completed of
      { turn : int
      ; tool_name : string
      ; idempotency_key : string
      ; output_json : Yojson.Safe.t
      ; is_error : bool
      ; duration_ms : float
      ; timestamp : float
      }
  | State_transition of
      { from_state : string
      ; to_state : string
      ; reason : string
      ; timestamp : float
      }
  | Checkpoint_saved of
      { checkpoint_id : string
      ; timestamp : float
      }
  | Error_occurred of
      { turn : int
      ; error_domain : string
      ; detail : string
      ; timestamp : float
      }

(** {1 Journal} *)

type journal

(** Ordinary [on_append] observer failure captured after the event was added to
    the journal.  The original exception and raw backtrace are retained so a
    caller can surface or re-raise the failure without fabricating a new
    origin. *)
type append_error =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

(** Create an empty journal.
    When [~on_append] is provided, it is called after every
    {!append} with the event just recorded.  Intended for
    projecting journal events onto {!Event_bus} or other sinks.
    @since 0.133.0 *)
val create : ?on_append:(event -> unit) -> unit -> journal

(** Append an event to the journal, then notify [on_append].

    The append is committed before observer notification. An ordinary observer
    exception is returned explicitly as [Error] and never rolls back the event.
    [Out_of_memory], [Stack_overflow], [Sys.Break], and cancellation are
    re-raised with their original backtrace after the event is committed. *)
val append : journal -> event -> (unit, append_error) result

(** All events in chronological order. *)
val events : journal -> event list

(** Number of events in the journal. *)
val length : journal -> int

(** {1 Idempotency} *)

(** Generate an idempotency key from tool name + input hash.
    Deterministic: same inputs always produce the same key. *)
val make_idempotency_key : tool_name:string -> input:Yojson.Safe.t -> string

(** Check if an activity with this key has already completed.
    Returns [Some output_json] if found, [None] if not. *)
val find_completed_activity : journal -> string -> Yojson.Safe.t option

(** {1 Replay} *)

(** Replay summary: extracted from a journal for state reconstruction. *)
type replay_summary =
  { last_turn : int
  ; completed_tools : (string * Yojson.Safe.t) list (** idempotency_key -> output *)
  ; last_state : string
  ; total_input_tokens : int option
  ; total_output_tokens : int option
  ; error_count : int
  }

(** Extract a replay summary from a journal.
    Used to reconstruct agent state after crash recovery. *)
val replay_summary : journal -> replay_summary

(** {1 Serialization} *)

val event_to_json : event -> Yojson.Safe.t
val event_of_json : Yojson.Safe.t -> (event, string) result
val journal_to_json : journal -> Yojson.Safe.t
val journal_of_json : Yojson.Safe.t -> (journal, string) result

(** {1 Persistence}

    JSONL-based file persistence for crash recovery.  Each line is a
    single event's JSON representation, appended in chronological
    order.  Durable across restarts; atomic dump uses a temp file
    + rename.

    @since 0.133.0 *)

(** Dump the full journal to [path] as JSONL (one event per line,
    chronological order).  Writes to [path ^ ".tmp"] first then
    renames, so a partial write cannot corrupt an existing file.
    Returns [Error msg] on I/O failure. *)
val save_to_file : journal -> string -> (unit, string) result

(** Load a journal from a JSONL file produced by {!save_to_file}.
    Empty or missing file returns an empty journal (not an error).
    Malformed lines abort the load with [Error msg] identifying the
    first bad line.  The loaded journal has no [on_append] callback.

    When [~fs] is supplied the load uses Eio non-blocking I/O and is
    bounded by a 50 MB size limit; otherwise a synchronous fallback is
    used for non-Eio callers. *)
val load_from_file : ?fs:Eio.Fs.dir_ty Eio.Path.t -> string -> (journal, string) result

(** {1 Queries} *)

(** Events for a specific turn. *)
val events_for_turn : journal -> int -> event list

(** Last event timestamp, or [None] for empty journals. *)
val last_timestamp : journal -> float option

(** All tool completions (for replay). *)
val tool_completions : journal -> (string * Yojson.Safe.t * bool) list
