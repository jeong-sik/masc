(** Pure immutable TEA sub-store for Multi-Account Personal Keepers
    ([/api/v1/auth/keepers*], [Manage_own_keeper]).

    All state is completely purged on session epoch changes, token swaps/clears,
    logout, or privilege demotion. HTTP 403 scope denials
    ([Pat_scope_lacks_own_keeper]) arm a non-retryable guard so background view
    fetches never loop. *)

open Masc_tui_core
open Masc_tui_protocol

type ephemeral_turn = {
  keeper_id : string;
  message : string;
  answer : Wire_personal_keepers.turn_answer;
}

type t = {
  keepers : Wire_personal_keepers.personal_keeper list Observed.t;
  own_keeper_forbidden : string option;
  selected_keeper_idx : int;
  selected_keeper_id : string option;
  conversation : (string * Wire_personal_keepers.conversation_snapshot) Observed.t;
  requested_conversation_id : string option;
  selected_conv_idx : int;
  conversation_forbidden : string option;
  ephemeral_turns : ephemeral_turn list;
  turn_in_flight : (string * string) option;
  last_turn_error : (string * string) option;
  delete_armed_conv_id : string option;
  last_delete_notice : string option;
  transcript_scroll : int;
}

val empty : t
val purge : t -> t
val mark_stale : t -> t

val keepers_list : t -> Wire_personal_keepers.personal_keeper list
val selected_keeper : t -> Wire_personal_keepers.personal_keeper option
val selected_keeper_id : t -> string option
val conversation_for_selected : t -> Wire_personal_keepers.conversation_snapshot option
val selected_conversation_summary : t -> Wire_personal_keepers.conversation_summary option
val delete_target_conversation_id : t -> string option
val ephemeral_turns_for : keeper_id:string -> t -> ephemeral_turn list

val apply_keepers :
  observed_at:Clock.Mono.t ->
  Wire_personal_keepers.personal_keeper list ->
  t ->
  t

val apply_conversation :
  observed_at:Clock.Mono.t ->
  keeper_id:string ->
  Wire_personal_keepers.conversation_snapshot ->
  t ->
  t

val mark_own_keeper_forbidden : at:Clock.Mono.t -> reason:string -> t -> t
val mark_conversation_forbidden : at:Clock.Mono.t -> reason:string -> t -> t
val clear_forbidden : t -> t

val select_keeper_by_id : string -> t -> t
val move_keeper_selection : delta:int -> t -> t
val select_conversation_by_delta : delta:int -> t -> t * string option
val set_requested_conversation : string option -> t -> t
val scroll_transcript : delta:int -> t -> t

val start_turn_in_flight : keeper_id:string -> preview:string -> t -> t
val finish_turn_ok :
  keeper_id:string ->
  message:string ->
  Wire_personal_keepers.turn_answer ->
  t ->
  t
val finish_turn_error : keeper_id:string -> reason:string -> t -> t

val arm_delete : conversation_id:string -> t -> t
val disarm_delete : t -> t
val set_delete_notice : string option -> t -> t
