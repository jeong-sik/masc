val json_member : string -> Yojson.Safe.t -> Yojson.Safe.t
val json_string : string -> Yojson.Safe.t -> string option
val json_int : string -> Yojson.Safe.t -> int option
val json_float : string -> Yojson.Safe.t -> float option
val json_bool : string -> Yojson.Safe.t -> bool option
val compact_receipt_error_json : Yojson.Safe.t -> Yojson.Safe.t
val compact_receipt_runtime_json : Yojson.Safe.t -> Yojson.Safe.t
val json_number : string -> Yojson.Safe.t -> float option
val json_assoc : string -> Yojson.Safe.t -> Yojson.Safe.t option
val string_has_prefix : prefix:string -> string -> bool
val tool_call_output_text : Yojson.Safe.t -> string option
val parse_tool_call_output : Yojson.Safe.t -> Yojson.Safe.t option
val claim_status_of_output : Yojson.Safe.t -> string
val composite_claim_attempt_absent :
  [> `Assoc of
       (string *
        [> `Bool of bool | `List of 'a list | `Null | `String of string ])
       list ]
val claim_rows_per_keeper : int
(** Rows of one keeper's tool-call history a claim lookup considers. *)

val claim_window_rows : int
(** Fleet-wide rows {!read_claim_window} reads:
    [claim_rows_per_keeper * Keeper_tool_call_log.read_over_scan_factor], which
    is the coverage a per-keeper [read_recent ~n:claim_rows_per_keeper] had. *)

type claim_window
(** One fleet-wide tail of tool-call rows, read once and shared by every keeper
    in the same composite envelope instead of re-read per keeper, or the
    detail of the index read that could not produce it. Abstract so a caller
    cannot substitute a list read with a different window. *)

val read_claim_window : unit -> claim_window
(** Read the shared window. One store read per envelope, not one per keeper.
    An index that cannot be read yields the unavailable window, never an
    empty one. *)

val latest_task_claim_row :
  claim_window ->
  keeper_name:string ->
  (Yojson.Safe.t option, Keeper_tool_call_log.index_error) result
(** The keeper's most recent [Keeper_tooling.Name.Task_claim] row within the
    window, by row order; [Ok None] if it did not claim inside it; the
    [Error] when the window itself could not be read. *)

val composite_claim_attempt_json :
  claim_window:claim_window ->
  keeper_name:string -> [> `Assoc of (string * Yojson.Safe.t) list ]
(** The claim attempt for [keeper_name] inside the window. An unreadable
    window renders [status = "tool_log_unavailable"] with the index's
    [detail], not the [not_observed] shape. *)
val find_override_field_source :
  string -> Yojson.Safe.t -> Yojson.Safe.t option
val composite_config_drift_json :
  config:Workspace.config ->
  keeper_name:string -> [> `Assoc of (string * Yojson.Safe.t) list ]
val composite_execution_receipt_json :
  config:Workspace.config ->
  claim_window:claim_window ->
  keeper_name:string -> [> `Assoc of (string * Yojson.Safe.t) list ]
val lower_string_opt : string option -> string option
val string_opt_is_any : string option -> string list -> bool
val string_opt_present : string option -> bool
val json_string_eq : string -> Yojson.Safe.t -> String.t -> bool
val composite_latest_activity_epoch :
  Yojson.Safe.t -> Yojson.Safe.t -> float option
val composite_snapshot_is_idle : Yojson.Safe.t -> bool
val composite_execution_config_blocked : Yojson.Safe.t -> bool
val composite_execution_claim_no_eligible : Yojson.Safe.t -> bool
val composite_execution_config_drift : Yojson.Safe.t -> bool
val keeper_activation_readiness_json :
  Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
val composite_execution_blocked : Yojson.Safe.t -> bool
val composite_execution_receipt_present : Yojson.Safe.t -> bool
val composite_execution_receipt_epoch : Yojson.Safe.t -> float option
val composite_live_turn_started_epoch : Yojson.Safe.t -> float option
val composite_live_turn_last_progress_epoch : Yojson.Safe.t -> float option
val composite_execution_current_for_runtime_state :
  snapshot:Yojson.Safe.t -> execution:Yojson.Safe.t -> bool

(** The closed set of [runtime_attention.state] wire values. The registry
    judgment ({!composite_runtime_attention}) yields the first five; the
    offline fallback for a keeper without a registry entry yields
    [Attention_paused] or [Attention_offline]. *)
type runtime_attention_state =
  | Attention_blocked
  | Attention_stop_requested
  | Attention_idle_stale
  | Attention_stale
  | Attention_ok
  | Attention_paused
  | Attention_offline

val runtime_attention_state_to_wire : runtime_attention_state -> string
type composite_runtime_attention = {
  cra_is_live : bool;
  cra_fiber_stop_requested : bool;
  cra_stale_long_enough : bool;
  cra_idle_attention : bool;
  cra_blocked : bool;
  cra_execution_current : bool;
  cra_stale_execution_receipt : bool;
  cra_live_turn_started_at : float option;
  cra_live_turn_last_progress_at : float option;
  cra_stale_without_live_turn : bool;
  cra_needs_attention : bool;
  cra_reason : string option;
  cra_state : runtime_attention_state;
}
val composite_runtime_attention :
  snapshot:Yojson.Safe.t ->
  execution:Yojson.Safe.t -> composite_runtime_attention
val composite_runtime_attention_json :
  composite_runtime_attention ->
  snapshot:Yojson.Safe.t -> [> `Assoc of (string * Yojson.Safe.t) list ]
