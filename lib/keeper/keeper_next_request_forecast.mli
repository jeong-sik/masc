(** Keeper_next_request_forecast — what the next Agent Core request would
    carry, computed from the same values a turn uses, without a turn.

    RFC keeper-context-window-in-tokens §10.3, run forward: capacity
    [B = W × density], history room [A = B − R − pinned], and the cut is
    {!Runtime_model_input_tail_window.project_target} over the durable
    checkpoint with the autonomous wake line appended as the newest atom.
    Nothing here dispatches, advances a cursor, or consumes a note.

    Live at the time of the call: the declared window, the runtime's density
    (process-local, absent after a restart until the first response), the
    request-body cap, and the checkpoint. As last measured, from the turn
    records of completed turns on the same runtime: [R] (tool schemas +
    keeper instructions) from the newest composition, and the pinned blocks
    (memory recall, dynamic context, ...) from the newest composition that
    is a first round's. A record describes the turn's latest request; a
    post-tool round drops every block
    {!Prompt_block_id.injected_on_post_tool_round} refuses, so only a record
    carrying such a block says what the next first round pins, while the
    schemas ride every round and the newest record has the current surface.
    An errored turn's record names the requested runtime, not the one whose
    composition it holds, so it is not read. {!measured_parts} carries the
    turn each figure came from. *)

type measured_parts =
  { reserved_turn : int  (** The completed turn [reserved_bytes] was read from. *)
  ; reserved_bytes : int  (** Tool schemas + keeper instructions. *)
  ; pinned_turn : int  (** The completed first-round turn [pinned_bytes] was read from. *)
  ; pinned_bytes : int  (** Every other prompt block, never cut. *)
  }

type parts_refusal =
  | No_composition_on_runtime of { records_read : int }
      (** No completed turn on this runtime carried an exact composition. *)
  | No_first_round_composition of { records_read : int; newest_turn : int }
      (** Completed turns on this runtime carried compositions, all of them
          post-tool rounds; [newest_turn] is the newest of those. *)

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
      ; fit : Runtime_model_input_tail_window.target_fit
      }
  | Newest_atom_only of { transmitted_bytes : int }
      (** The runtime has no density yet, so the turn would send the
          smallest request that carries it. *)

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
  ; first_round_pinned_bytes : int option
        (** Every other prompt block, or [None] when the composition carries
            no block that only a first round injects: the post-tool shape. *)
  }

val read_composition : Turn_record.input_component list -> composition

val select_parts
  :  records_read:int
  -> (int * composition) list
  -> (measured_parts, parts_refusal) result
(** Over the completed turns on one runtime, oldest first: [reserved] from
    the newest composition, [pinned] from the newest first-round one. *)
