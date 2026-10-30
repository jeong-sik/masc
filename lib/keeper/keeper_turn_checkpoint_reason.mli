(** Why a healthy Keeper turn checkpointed before it completed.

    Produced by the turn from the runtime's typed stop reason
    ({!Keeper_unified_turn.turn_success_of_stop_reason}); consumed by the
    heartbeat loop for batch acknowledgement and by the next turn's prompt,
    which tells the model why its previous turn ended. The prompt module
    cannot see {!Keeper_unified_turn} (that module builds the prompt), so the
    reason lives here, below both. *)

type t =
  | Operation_queued
      (** A chat operation was queued for this keeper; the turn yielded the
          slot to it. *)
  | Durable_stimulus_arrived
      (** A newer durable stimulus arrived; the turn yielded so the next
          turn carries it. *)
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
      (** An explicit runtime/host stop reported repeated calls. This carrier
          preserves that report; Keeper does not infer it from equal receipts. *)
  | Repeated_assistant_text of { repeated_count : int }
      (** An explicit runtime/host stop reported repeated assistant text.
          Equal text alone does not authorize a Keeper-generated stop. *)
