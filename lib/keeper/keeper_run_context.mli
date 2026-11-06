(* keeper_run_context — Steps 0–4 of run_turn. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** What an admitted turn knows about the history saved for its trace. *)
type saved_history =
  | Saved_history_loaded  (** The turn starts from it. It may hold no atom. *)
  | Saved_history_absent  (** The store has no checkpoint for the trace. *)
  | Saved_history_superseded
      (** The checkpoint version was deliberately superseded. Its history
          remains on disk until this fresh turn's first accepted save.
          Other load failures return [Error] before a run context exists. *)

(** Resolved inference and session context needed before prompt construction. *)
type run_context =
  { meta : keeper_meta
  ; task_context : Keeper_turn_task_context.t
  ; temperature : float
  ; context_injector : Agent_core.Hooks.context_injector
  ; shared_context : Agent_core.Context.t
  ; session_dir : string
  ; session : Keeper_types.session_context
  ; saved_history : saved_history
  ; system : Keeper_turn_system.t
        (** The System every request of the turn sends, with the amendments
            its end context carries (RFC-0491 §3.2). *)
  ; workspace_root : string
  ; ctx_work : working_context
  ; resume_agent_core_checkpoint : Agent_core.Checkpoint.t option
  ; start_turn_count : int
  ; receipt_started_at : string
  ; config_root : string
  ; runtime_config_path : string option
  }

type base_prompt_error =
  | Workspace_unavailable of string
  | Constitution_unreadable of World_constitution_store.read_error

val base_prompt_error_to_string : base_prompt_error -> string

type prepare_error =
  | Checkpoint_unread of Keeper_checkpoint_store.checkpoint_load_error
  | Base_prompt_unavailable of base_prompt_error
      (** Namespace resolution or the constitution ledger prevented building
          an authoritative prompt. Nothing is dispatched. *)
  | Prompt_unrenderable of string
      (** A prompt slot the base system prompt needs is missing or fails to
          render (partial asset sync, operator edit). The turn is refused
          with this typed reason instead of crashing the cycle. *)
  | Turn_system_unreadable of string
      (** The loaded checkpoint's session context holds a malformed
          {!Keeper_turn_system.held} entry. *)

(** A native continuation's seed System and the runtime its call runs on. *)
type recorded_system =
  { runtime_id : string
  ; text : string
  }

val build_base_system_prompt :
     config:Workspace.config
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> meta:keeper_meta
  -> (string * string, base_prompt_error) result
(** Build the keeper base system prompt from the same persisted meta/profile
    inputs used by {!prepare_run_context}, rendered with the articles the
    world holds now. A turn sends {!run_context.system} instead, which an
    Agent Core turn may render with the articles of its last System. Returns
    the resolved workspace root and prompt together; no prompt is built with
    an unavailable namespace. *)

val prepare_run_context :
     config:Workspace.config
  -> meta:keeper_meta
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> base_dir:string
  -> runtime_id:string
  -> ?temperature:float
  -> ?shared_context:Agent_core.Context.t
  -> ?checkpoint:Agent_core.Checkpoint.t
  -> ?recorded_system:recorded_system
  -> unit
  -> (run_context, prepare_error) result
(** Resolve [temperature] as the caller fallback; a temperature declared by the
    selected runtime model always wins. [profile_defaults] is the immutable
    pre-dispatch snapshot. [checkpoint] is an already admitted direct
    continuation; when supplied it is the history source instead of a second
    disk read. A missing or superseded checkpoint starts fresh; every other
    load failure returns its typed error before prompt construction. An
    unreadable constitution ledger returns [Base_prompt_unavailable].

    [runtime_id] is the turn's assignment. The head of its fresh walk says
    whether the System may keep its last articles: for an Agent Core head
    the range the first request carries is predicted over the loaded
    history ({!Keeper_next_request_forecast.first_request}), and
    {!Keeper_turn_system.issue} decides over what the loaded checkpoint's
    session context holds. With [recorded_system] the turn resends those
    bytes ({!Keeper_turn_system.resend}). Either way the result is written
    into [shared_context], the context the turn's checkpoints persist. *)

(** Whether the turn starts from a checkpoint it loaded. *)
val loaded_checkpoint_present : run_context -> bool
