(** Keeper_next_request_forecast — what the next Agent Core request would
    carry, computed from the same values a turn uses, without a turn.

    RFC keeper-context-window-in-tokens §10.3, run forward: capacity
    [B = W × density], history room [A = B − R − pinned], and the cut is
    {!Runtime_model_input_tail_window.project_target} over the durable
    checkpoint with the autonomous wake line appended as the newest atom.
    Nothing here dispatches, advances a cursor, or consumes a note.

    Live at the time of the call: the declared window, the runtime's density
    (process-local, absent after a restart until the first response), the
    request-body cap, and the checkpoint. As last measured: [R] (tool
    schemas + keeper instructions) and the pinned blocks (memory recall,
    dynamic context, ...), taken from the newest turn record on the same
    runtime that carried an exact composition, because a turn measures them
    with the encoder the cut uses. {!measured_parts.turn} says how old. *)

type measured_parts =
  { turn : int  (** The turn record the two figures were read from. *)
  ; reserved_bytes : int  (** Tool schemas + keeper instructions. *)
  ; pinned_bytes : int  (** Every other prompt block, never cut. *)
  }

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
  ; window : (Keeper_context_window.t, string) result
        (** [Error] names the same contradiction the turn driver refuses on:
            a window larger than the model's max-context, or no runtime. *)
  ; capacity : Keeper_context_window.capacity option  (** [None] with [window = Error]. *)
  ; request_cap_bytes : int option
        (** What the provider accepts; [None] when the binding declares none
            or the runtime cannot be resolved. Judges, never shapes. *)
  ; parts : measured_parts option
        (** [None] when no turn record on this runtime carried a composition. *)
  ; history_atoms : int  (** Atoms in the checkpoint plus the wake line. *)
  ; cut : history_cut option  (** [None] when [window] or [parts] is missing. *)
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
