(** Keeper_next_request_forecast — what the next Agent Core request would
    carry, computed from the same values a turn uses, without a turn.

    RFC keeper-context-window-in-tokens §10.3, run forward: capacity
    [B = W × density], history room [A = B − R − pinned], and the cut is
    {!Runtime_model_input_tail_window.project_target} over the durable
    checkpoint with the autonomous wake line appended as the newest atom.
    Nothing here dispatches, advances a cursor, or consumes a note.

    Live at the time of the call: the declared window, the runtime's density
    (process-local, absent after a restart until the first response), the
    request-body cap, and the checkpoint. As last measured, from turn
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
  ; instructions_bytes : int  (** The system prompt's share of [reserved_bytes]. *)
  ; schemas_bytes : int  (** The tool array's share of [reserved_bytes]. *)
  ; pinned_turn : int  (** The first-round turn [pinned_bytes] was read from. *)
  ; pinned_runtime_id : string  (** The lane that turn ran on, as its record names it. *)
  ; pinned_bytes : int  (** Every other prompt block, never cut. *)
  ; pinned_blocks : (Prompt_block_id.t * int) list
        (** The blocks behind [pinned_bytes], in the order the assembly
            concatenates them ({!Prompt_block_id.cache_rank}). *)
  }

type parts_refusal =
  | No_composition_on_runtime of { records_read : int }
      (** No completed turn on this runtime carried an exact composition. *)
  | No_first_round_composition of { records_read : int; newest_turn : int }
      (** Compositions were read, none of them a first round's on any lane;
          [newest_turn] is the newest completed turn on this runtime. *)

val parts_refusal_to_string : parts_refusal -> string

type window_refusal =
  | Contradiction of string
      (** The same contradiction the turn driver refuses on: a window larger
          than the model's max-context, or no materialized runtime. *)
  | Not_agent_core of { runtime_id : string }
      (** An official-client runtime: the spawned client owns its context
          window and masc applies no Agent Core cut. *)

val window_refusal_to_string : window_refusal -> string

type history_cut =
  | Cut of
      { kept_atoms : int
      ; transmitted_bytes : int
            (** Pinned messages, kept atoms and the preamble, as the cut's
                encoder counts them; excludes [reserved_bytes] and
                [pinned_bytes] of the prompt. *)
      ; preamble_bytes : int option
            (** The synthetic "[context window]" message the cut prepends when
                the oldest kept atom is not a user message; [None] when none. *)
      ; fit : Runtime_model_input_tail_window.target_fit
      }
  | Newest_atom_only of { transmitted_bytes : int }
      (** The runtime has no density yet, so the turn would send the
          smallest request that carries it. *)

(** One piece of the request in the position it travels. The order is the
    turn's: the system prompt and the tool array ride beside the messages;
    the messages are the cut's preamble when it prepended one, the kept
    history oldest first, the wake line, and last the ["[system context]"]
    message that {!Agent_core.Agent_turn.prepare_messages} appends so the
    conversation prefix stays byte-identical for provider caches. *)
type slot =
  | System_prompt of { bytes : int }
  | Tools of { bytes : int }
  | Preamble of { bytes : int }
  | History of { atoms : int; of_atoms : int; bytes : int }
      (** [atoms] kept of [of_atoms] in the checkpoint, the wake line not
          counted on either side. *)
  | Wake_line of { bytes : int }
  | System_context of { bytes : int; blocks : (Prompt_block_id.t * int) list }

type candidate =
  { runtime_id : string
  ; window : (Keeper_context_window.t, window_refusal) result
  ; capacity : Keeper_context_window.capacity option  (** [None] with [window = Error]. *)
  ; request_cap_bytes : int option
        (** What the provider accepts; [None] when the binding declares none
            or the runtime is not an Agent Core one. Judges, never shapes. *)
  ; parts : (measured_parts, parts_refusal) result
  ; history_atoms : int  (** Atoms in the checkpoint plus the wake line. *)
  ; cut : history_cut option  (** [None] when [window] or [parts] is refused. *)
  ; assembly : slot list option
        (** The request in travel order; [None] whenever [cut] is. *)
  }

type t =
  { keeper : string
  ; trace_id : string
  ; checkpoint_messages : int
  ; wake_line_bytes : int  (** The wake line as the cut's encoder counts it. *)
  ; candidates : candidate list
        (** The keeper's bound runtime. Failover candidates are not listed. *)
  }

val forecast : config:Workspace.config -> keeper_name:string -> (t, string) result
(** [Error] when the keeper is unknown or its checkpoint cannot be read. *)

val to_json : t -> Yojson.Safe.t

val cut_history
  :  measure:(Agent_core.Types.message -> int)
  -> capacity:Keeper_context_window.capacity
  -> reserved_bytes:int
  -> pinned_bytes:int
  -> Agent_core.Types.message list
  -> history_cut
(** The pure arithmetic, for tests: [project_target] at
    [capacity_bytes] with [reserved_bytes + pinned_bytes] taken off, or the
    newest atom alone when the capacity is [Unmeasured]. *)

val measure : Agent_core.Types.message -> int
(** Bytes of one message as the cut's encoder counts them. *)

type composition =
  { fixed_bytes : int  (** Tool schemas + keeper instructions. *)
  ; instructions_bytes : int
  ; schemas_bytes : int
  ; first_round_pinned_bytes : int option
        (** Every other prompt block, or [None] when the composition carries
            no block that only a first round injects: the post-tool shape. *)
  ; pinned_blocks : (Prompt_block_id.t * int) list
        (** Those blocks in assembly order; empty for the post-tool shape. *)
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

val assembly : wake_bytes:int -> history_atoms:int -> measured_parts -> history_cut -> slot list
(** The pure layout, for tests: the slots in travel order for one cut.
    [history_atoms] counts the wake line, as {!candidate.history_atoms} does. *)
