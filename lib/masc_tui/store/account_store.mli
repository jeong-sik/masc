(** Pure immutable TEA sub-store for the Account/Session overlay, runtime
    Bearer/PAT token entry/rotation/clear, and Multi-Account own-provider
    inspection & management.

    Security invariant: the runtime token draft is never rendered in plaintext,
    never logged, never toasted, and is wiped immediately on submit, cancel,
    overlay close, or auth-session transition. *)

open Masc_tui_core
open Masc_tui_protocol

type token_source =
  | Token_startup_default
  | Token_runtime_set
  | Token_runtime_cleared

val equal_token_source : token_source -> token_source -> bool

type token_editor = {
  active : bool;
  draft : string;
  error : string option;
}

type t = {
  token_source : token_source;
  token_editor : token_editor;
  clear_token_armed : bool;
  provider_accounts : Wire_account.provider_accounts_snapshot Observed.t;
  integrations : Wire_account.person_integrations_snapshot Observed.t;
  own_provider_forbidden : string option;
  last_verification : (string * Wire_account.account_verify_response) option;
  selected_account_idx : int;
  scroll_offset : int;
}

val empty : t

(** {1 Masked Token Editor Helpers} *)

val sanitize_token_chunk : string -> string
(** Strip CR, LF, NUL, and ASCII control bytes from pasted or typed token text. *)

val masked_draft_display : token_editor -> string
(** Return strictly masked bullets plus character count (never a single
    character from [draft]). *)

val open_token_editor : t -> t
val close_token_editor : t -> t
val wipe_token_draft : t -> t
val append_token_text : string -> t -> t
val backspace_token_text : t -> t
val set_token_editor_error : string -> t -> t
val mark_token_runtime_set : t -> t
val mark_token_runtime_cleared : t -> t
val mark_token_startup_default : t -> t
val arm_clear_token : t -> t
val disarm_clear_token : t -> t

(** {1 Multi-Account Own-Provider State} *)

val apply_provider_accounts :
  observed_at:Clock.Mono.t -> Wire_account.provider_accounts_snapshot -> t -> t

val apply_integrations :
  observed_at:Clock.Mono.t -> Wire_account.person_integrations_snapshot -> t -> t

val mark_own_provider_forbidden : at:Clock.Mono.t -> reason:string -> t -> t

val apply_verification :
  provider_account_id:string -> Wire_account.account_verify_response -> t -> t

val purge_own_provider_data : t -> t
(** Drop cached MA own-provider snapshots, verification receipts, and forbidden
    notices while preserving [token_source]. *)

val mark_stale : t -> t

val accounts_list : t -> Wire_account.provider_account list
val integrations_list : t -> Wire_account.person_integration list
val selected_provider_account : t -> Wire_account.provider_account option

val runtimes_for_account :
  provider_account_id:string -> t -> Wire_account.provider_runtime list

val all_runtimes : t -> Wire_account.provider_runtime list

val integration_by_id :
  integration_id:string -> t -> Wire_account.person_integration option

val move_selection : delta:int -> t -> t
