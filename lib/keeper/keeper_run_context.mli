(* keeper_run_context — Steps 0–4 of run_turn. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { meta : keeper_meta
  ; temperature : float
  ; context_injector : Agent_sdk.Hooks.context_injector
  ; shared_context : Agent_sdk.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; loaded_checkpoint_present : bool
  ; base_system_prompt : string
  ; ctx_work : working_context
  ; resume_oas_checkpoint : Agent_sdk.Checkpoint.t option
  ; pre_dispatch_compacted : bool
  ; pre_dispatch_compaction_trigger : string option
  ; pre_dispatch_compaction_before_tokens : int option
  ; pre_dispatch_compaction_after_tokens : int option
  ; pre_dispatch_checkpoint_error : Agent_sdk.Error.sdk_error option
  ; start_turn_count : int
  ; receipt_started_at : string
  ; config_root : string
  ; runtime_config_path : string option
  }

val build_base_system_prompt :
     config:Workspace.config
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> meta:keeper_meta
  -> string
(** Build the keeper base system prompt from the same persisted meta/profile
    inputs used by {!prepare_run_context}. *)

val prepare_run_context :
     config:Workspace.config
  -> meta:keeper_meta
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> base_dir:string
  -> max_context:int
  -> runtime_id:string
  -> ?temperature:float
  -> ?shared_context:Agent_sdk.Context.t
  -> generation:int
  -> unit
  -> run_context
(** Resolve [temperature] as the caller fallback; a temperature declared by the
    selected runtime model always wins. [profile_defaults] is the immutable
    pre-dispatch snapshot. *)
