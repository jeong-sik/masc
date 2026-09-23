(** Keeper_next_request_forecast — what the next Agent Core request would
    carry, computed from the same values a turn uses, without a turn.

    RFC keeper-context-window-in-tokens §10.4, run forward: the range
    {!Keeper_turn_driver_try_provider.compose_carried_model_input} composes
    over the durable checkpoint with the autonomous wake line appended as
    the newest atom. The Librarian continuity comes first, chosen as the
    turn chooses it ({!Keeper_turn_driver_try_provider.choose_continuity}):
    a fitting snapshot opens the range at its end with its working state
    prepended, and the Librarian's read position opens it there. With no
    Librarian point, the pair's front. A valid pair ledger
    is projected through the same high/low-water decision the driver applies
    at the next turn boundary; this calculation leaves the observed ledger
    unchanged. [counted_tokens] remains its last measured total, not the
    projected total after eviction. Nothing here
    dispatches, advances a cursor, consumes a note, or writes a front.

    Live at the time of the call: the pair's ledger (process-local, absent
    after a restart until the first response observation), the binding's marks, and
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
    lane, each came from.

    Beside the figures, {!candidate.assembly} lays the same parts out in
    the order the request carries them. *)

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
  ; preamble_bytes : int option
        (** The synthetic ["[context window]"] message the range prepends
            when the oldest carried atom is not a user message, as the same
            encoder counts it; [None] when none rides. Part of
            [transmitted_bytes]. *)
  ; working_state_bytes : int option
        (** The Librarian working state the range carries in place of the
            atoms a fitting snapshot covers
            ({!Keeper_turn_driver_try_provider.working_state_text}), as the
            same encoder counts it; [None] when the range does not open at a
            snapshot. Part of [transmitted_bytes]. *)
  ; origin : Keeper_carried_front.origin
  ; counted_tokens : int option
        (** The ledger's measured total for its last sample, a request
            without the turn context, when known; what the marks are read
            against. *)
  }

(** One piece of the request in the position it travels. The order is the
    turn's: the system prompt and the tool array ride beside the messages;
    the messages are the preamble when the range prepended one, the
    Librarian working state when a snapshot opens the range, the carried
    history oldest first, the wake line, and last the ["[system context]"]
    message that {!Agent_core.Agent_turn.prepare_messages} appends so the
    conversation prefix stays byte-identical for provider caches. *)
type slot =
  | System_prompt of { bytes : int }
  | Tools of { bytes : int }
  | Preamble of { bytes : int }
  | Working_state of { bytes : int }
  | History of { atoms : int; of_atoms : int; bytes : int }
      (** [atoms] carried of [of_atoms] in the checkpoint, the wake line
          not counted on either side; [bytes] is what the range transmits
          less the preamble, the working state and the wake line. *)
  | Wake_line of { bytes : int }
  | System_context of { bytes : int; blocks : (Prompt_block_id.t * int) list }
      (** [blocks] in the order the assembly concatenates them. *)

(** Where a candidate stands in the walk the next fresh cycle takes: the
    lane as declared, then quota and backpressure demotion
    ({!Keeper_turn_driver.assignment_walk_order}). Two things the walk does
    are not forecast: a head replaced for an input modality it cannot take
    (RFC-0265), and a turn that failed and deferred its input, whose next
    cycle walks the remaining candidates instead; that hint lives in the
    heartbeat loop. *)
type place =
  { walks_at : int  (** 0 walks first. *)
  ; declared_at : int option
        (** The candidate's index in the lane's declaration; [None] when the
            walk carries an id the lane does not declare. *)
  ; rest : Keeper_turn_driver.path_rest
        (** Whether the path rests now (RFC-provider-path-rest §3.3). *)
  }

type walk =
  { lane_id : string
  ; declared : string list  (** The lane as declared, head first. *)
  }

type walk_refusal = Keeper_turn_driver.assignment_refusal
(** The driver would not dispatch the assignment at all: no lane or runtime
    of that id, or no capability catalog entry for it. *)

val walk_refusal_to_string : walk_refusal -> string

type candidate =
  { runtime_id : string
  ; lane : (unit, lane_refusal) result
  ; marks : Runtime_schema.context_marks option
        (** As the binding declares them; [None] leaves eviction to a
            refusal. *)
  ; parts : (measured_parts, parts_refusal) result
  ; history_atoms : int  (** Atoms in the checkpoint plus the wake line. *)
  ; carried : carried option  (** [None] when [lane] is refused. *)
  ; assembly : slot list option
        (** The request in travel order; [None] whenever [carried] or
            [parts] is. *)
  ; place : place
  }

type t =
  { keeper : string
  ; trace_id : string
  ; checkpoint_messages : int
  ; wake_line_bytes : int
        (** The wake line as the composition's encoder counts it, the
            figure the assembly subtracts from the transmitted bytes. *)
  ; walk : (walk, walk_refusal) result
  ; candidates : candidate list
        (** Every candidate of the keeper's lane, in the order the next
            fresh cycle walks them; each with its own ledger front and marks,
            and the seed the trace gives them alike when the pair has no
            ledger. Empty when [walk] is refused. *)
  }

val forecast : config:Workspace.config -> keeper_name:string -> (t, string) result
(** [Error] when the keeper is unknown or its checkpoint cannot be read. *)

val to_json : t -> Yojson.Safe.t

val declared_at : declared:string list -> string -> int option
(** The index of a runtime id in a lane's declaration, [None] when absent. *)

val carry
  :  measure:(Agent_core.Types.message -> int)
  -> ?continuity:Keeper_turn_driver_try_provider.continuity
  -> front:Keeper_carried_front.seed option
  -> turn_start:Keeper_carried_front.turn_start
  -> counted_tokens:int option
  -> Agent_core.Types.message list
  -> carried
(** The range {!Keeper_turn_driver_try_provider.compose_carried_model_input}
    composes, read as the forecast reports it, with nothing demoted: a
    [continuity] with a Librarian point opens it there; without one the
    seeded front, once {!Keeper_carried_front.for_history} admits it against
    this history; without that [turn_start]: the end of the last completed
    turn on this history (RFC keeper-context-window-in-tokens §13.4), or the
    newest atom alone when that boundary is unknown. [counted_tokens] rides
    along only when the range opened at [front]. *)


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

val assembly : wake_bytes:int -> history_atoms:int -> measured_parts -> carried -> slot list
(** The pure layout, for tests: the slots in travel order for one carried
    range. [history_atoms] counts the wake line, as {!candidate.history_atoms}
    does, and the range always carries it as its newest atom. *)
