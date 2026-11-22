(** Turns carried across a runtime switch on one trace (RFC
    librarian-call-only-proposes §11.8): Agent Core taking over after official
    client turns, and an official client resuming its own session after turns
    on another runtime.

    The order of turns, where a history was saved, and where it restarted are
    read from the Keeper's turn log. Which turns an official client answered
    is not in the turn log: [Opened.runtime] is the first runtime a turn
    chose, and an empty [Closed.own] also fits an Agent Core turn that ended
    before its closing save. Those turns are kept in a ledger of their own,
    one line per turn, which an official-client turn appends when it ends. The
    last ledger line of a session is that session's cursor.

    A turn log line that does not decode or breaks the order, a ledger line
    that does not decode, and a history line that cannot be read are refused,
    never passed over. *)

(** Metadata key stamped on bridged [Agent_core.Types.message] values so
    stage-saved checkpoints never duplicate an already bridged turn. *)
val bridged_turn_ref_metadata_key : string

(** Extract the bridged turn reference stamped on [msg], if any. Pure. *)
val bridged_turn_ref_of_message : Agent_core.Types.message -> Ids.Turn_ref.t option

(** The session that settled a turn. *)
type session_key =
  { client_kind : Keeper_semantic_execution.official_client_kind
  ; runtime_id : string
  ; session_id : string
  }

(** One ledger line: a turn an official client answered. [session] is [None]
    for a turn that ended with an error or settled no session. *)
type client_turn =
  { turn_ref : Ids.Turn_ref.t
  ; session : session_key option
  }

(** Why the turn log gave no answer. *)
type turn_log_refusal =
  | Log_unread of Private_jsonl_scan.error
  | Line_undecodable of
      { offset : int
      ; reason : Keeper_turn_log_store.undecodable
      }
  | Line_out_of_order of
      { offset : int
      ; error : Keeper_turn_log.order_error
      }

type bridge_load_error =
  | Turn_log_refused of turn_log_refusal
  | Ledger_unreadable of string
  | Ledger_line_unreadable of
      { line : int (** Numbered from 1. *)
      ; detail : string
      }
  | Cursor_turn_not_in_log of Ids.Turn_ref.t
      (** The resumed session's last turn has no [Opened] in the turn log, so
          where the turns after it start is not known. *)
  | Fragment_store_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; detail : string
      }
  | Fragment_line_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; line : int
      ; error : Keeper_turn_fragments.read_error
      }

val bridge_load_error_to_string : bridge_load_error -> string

(** The history lines of the closed turns of [trace_id] an official client
    answered since the last Agent Core save of the head or the last counted
    reset, excluding turns already stamped on [existing_messages]. An Agent
    Core save is a closed turn the ledger does not name that completed or
    whose [own] names messages. Read-only. *)
val uncheckpointed_official_turns
  :  base_path:string
  -> keeper_name:string
  -> trace_id:string
  -> session_dir:string
  -> existing_messages:Agent_core.Types.message list
  -> (Agent_core.Types.message list, bridge_load_error) result

(** Append the ledger line of a turn an official client answered. Called once
    when the turn ends. A blank runtime or session id is refused and nothing
    is written. *)
val record_client_turn
  :  base_path:string
  -> keeper_name:string
  -> client_turn
  -> (unit, string) result

(** The turns of [trace_id] closed after the last turn the session
    [(client_kind, runtime_id, session_id)] settled, rendered for that
    session. A turn is carried when an official client answered it, when it
    closed [Completed] or [Stale_save], or when its [own] names messages: an
    Agent Core turn that ended before its closing save is not. A counted reset
    drops what came before it. [Ok None] when the session settled no turn in
    the ledger or nothing follows its turn. Read-only. *)
val intervening_context_for_official_resume
  :  base_path:string
  -> keeper_name:string
  -> trace_id:string
  -> client_kind:Keeper_semantic_execution.official_client_kind
  -> runtime_id:string
  -> session_id:string
  -> (string option, bridge_load_error) result

(** Convenience wrapper for official-client adapters entering [Resume]:
    when [input_source] carries a [trace_id], prepends any intervening context
    returned by {!intervening_context_for_official_resume} ahead of [goal];
    logs a warning and returns [goal] unchanged if the bridge refuses. *)
val prepend_resume_handoff
  :  input_source:Keeper_request_source.t
  -> base_path:string
  -> keeper_name:string
  -> client_kind:Keeper_semantic_execution.official_client_kind
  -> runtime_id:string
  -> session_id:string
  -> goal:string
  -> string
