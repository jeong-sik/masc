(* keeper_run_context — Steps 0–4 of run_turn. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** What the turn knows, when it starts, about the history saved for its trace.
    A turn starts from an empty context in the last two cases alike, but only
    the first of them says that nothing is saved. *)
type saved_history =
  | Saved_history_loaded  (** The turn starts from it. It may hold no atom. *)
  | Saved_history_absent  (** The store has no checkpoint for the trace. *)
  | Saved_history_unread
      (** The load failed ({!Keeper_context_core.checkpoint_load}): what is
          saved was not seen and may still hold atoms. *)

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { meta : keeper_meta
  ; temperature : float
  ; context_injector : Agent_core.Hooks.context_injector
  ; shared_context : Agent_core.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; saved_history : saved_history
  ; base_system_prompt : string
  ; ctx_work : working_context
  ; resume_agent_core_checkpoint : Agent_core.Checkpoint.t option
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
  -> runtime_id:string
  -> ?temperature:float
  -> ?shared_context:Agent_core.Context.t
  -> unit
  -> run_context
(** Resolve [temperature] as the caller fallback; a temperature declared by the
    selected runtime model always wins. [profile_defaults] is the immutable
    pre-dispatch snapshot. *)

(** Whether the turn starts from a checkpoint it loaded. *)
val loaded_checkpoint_present : run_context -> bool
