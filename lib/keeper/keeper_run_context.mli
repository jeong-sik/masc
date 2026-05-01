(* keeper_run_context — Steps 0–4 of run_turn. *)

open Keeper_types

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { temperature : float
  ; max_tokens : int
  ; context_injector : Agent_sdk.Hooks.context_injector
  ; shared_context : Oas.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; loaded_checkpoint_present : bool
  ; base_system_prompt : string
  ; ctx_work : working_context
  ; resume_oas_checkpoint : Oas.Checkpoint.t option
  ; pre_dispatch_compacted : bool
  ; pre_dispatch_checkpoint_error : Oas.Error.sdk_error option
  ; start_turn_count : int
  ; receipt_started_at : string
  ; config_root : string
  ; cascade_config_path : string option
  ; gemini_mcp_disabled : bool
  ; approval_mode_effective : string option
  ; approval_mode_derived : bool
  ; keeper_oas_context : Keeper_types_profile.keeper_oas_context
  }

val prepare_run_context :
     config:Coord.config
  -> meta:keeper_meta
  -> base_dir:string
  -> max_context:int
  -> cascade_name:Keeper_cascade_profile.runtime_name
  -> ?temperature:float
  -> ?max_tokens:int
  -> ?shared_context:Oas.Context.t
  -> generation:int
  -> unit
  -> run_context
