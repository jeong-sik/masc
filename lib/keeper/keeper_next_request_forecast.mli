(** Keeper_next_request_forecast — what the next Agent Core request would
    carry, computed from the same values a turn uses, without a turn.

    RFC keeper-context-window-in-tokens §10.4, run forward: the carried
    range from the pair's front over the durable checkpoint with the
    autonomous wake line appended as the newest atom. Nothing here
    dispatches, advances a cursor, consumes a note, or moves the front.

    Live at the time of the call: the pair's ledger (process-local, absent
    after a restart until the first counted usage), the binding's marks, and
    the checkpoint. Without a ledger the front is the range the newest
    completed Agent Core turn record on the trace measured, whichever
    runtime ran it, exactly as the turn driver seeds it; without that the
    request is the whole
    history and the provider judges it. As last measured, from turn
    records: [R] (tool schemas + keeper instructions) from the newest
    composition of a completed turn on the same runtime, because the tool
    surface is the lane's and an errored turn's record names the requested
    runtime rather than the one whose composition it holds; the pinned
    blocks (memory recall, dynamic context, ...) from the newest composition
    on any lane that is a first round's, because those blocks are the
    keeper's and a first round is recorded mostly by single-request turns:
    official-client turns, and turns that errored on their first request. A
    record describes the turn's latest request; a post-tool round drops
    every block {!Prompt_block_id.injected_on_post_tool_round} refuses, so
    only a record carrying such a block says what the next first round
    pins. {!measured_parts} carries the turn, and for the pinned figure the
    lane, each came from. *)

type measured_parts =
  { reserved_turn : int  (** The completed turn [reserved_bytes] was read from. *)
  ; reserved_bytes : int  (** Tool schemas + keeper instructions. *)
  ; pinned_turn : int  (** The first-round turn [pinned_bytes] was read from. *)
  ; pinned_runtime_id : string  (** The lane that turn ran on, as its record names it. *)
  ; pinned_bytes : int  (** Every other prompt block, never cut. *)
  }

type parts_refusal =
  | No_composition_on_runtime of { records_read : int }
      (** No completed turn on this runtime carried an exact composition. *)
  | No_first_round_composition of { records_read : int; newest_turn : int }
      (** Compositions were read, none of them a first round's on any lane;
          [newest_turn] is the newest completed turn on this runtime. *)

val parts_refusal_to_string : parts_refusal -> string

type lane_refusal =
  | Not_materialized of { runtime_id : string }
  | Not_agent_core of { runtime_id : string }
      (** An official-client runtime: the spawned client owns its context
          and masc carries no range for it. *)

val lane_refusal_to_string : lane_refusal -> string

type carried =
  { first_atom : int  (** The oldest atom the request carries. *)
  ; kept_atoms : int
  ; transmitted_bytes : int
        (** Pinned messages, the carried atoms and the preamble, as the
            composition's encoder counts them; excludes [reserved_bytes] and
            [pinned_bytes] of the prompt. *)
  ; origin : Keeper_carried_front.origin
  ; counted_tokens : int option
        (** The ledger's measured total for its last request, when known;
            what the marks are read against. *)
  }

type candidate =
  { runtime_id : string
  ; lane : (unit, lane_refusal) result
  ; marks : Runtime_schema.context_marks option
        (** As the binding declares them; [None] leaves eviction to a
            refusal. *)
  ; parts : (measured_parts, parts_refusal) result
  ; history_atoms : int  (** Atoms in the checkpoint plus the wake line. *)
  ; carried : carried option  (** [None] when [lane] is refused. *)
  }

type t =
  { keeper : string
  ; trace_id : string
  ; checkpoint_messages : int
  ; wake_line_bytes : int
  ; candidates : candidate list
        (** The keeper's bound runtime. Failover candidates are not listed. *)
  }

val forecast : config:Workspace.config -> keeper_name:string -> (t, string) result
(** [Error] when the keeper is unknown or its checkpoint cannot be read. *)

val to_json : t -> Yojson.Safe.t

val carry
  :  measure:(Agent_core.Types.message -> int)
  -> front:Keeper_carried_front.seed option
  -> counted_tokens:int option
  -> Agent_core.Types.message list
  -> carried
(** The pure arithmetic, for tests: {!Runtime_model_input_tail_window.project_from_atom}
    from the seeded front, once {!Keeper_carried_front.for_history} admits it
    against this history; without one, the whole history. *)

val measure : Agent_core.Types.message -> int
(** Bytes of one message as the composition's encoder counts them. *)

type composition =
  { fixed_bytes : int  (** Tool schemas + keeper instructions. *)
  ; first_round_pinned_bytes : int option
        (** Every other prompt block, or [None] when the composition carries
            no block that only a first round injects: the post-tool shape. *)
  }

val read_composition : Turn_record.input_component list -> composition

type record_reading =
  { turn : int
  ; runtime_id : string  (** As the record names it. *)
  ; completed : bool  (** The record carries a stop reason. *)
  ; composition : composition
  }

val select_parts
  :  runtime_id:string
  -> records_read:int
  -> record_reading list
  -> (measured_parts, parts_refusal) result
(** Oldest first. [reserved] from the newest completed reading on
    [runtime_id]; [pinned] from the newest first-round reading on any lane,
    completed or not. *)
