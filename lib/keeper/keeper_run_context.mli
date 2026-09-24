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

type prepare_error =
  | Checkpoint_unread of Keeper_checkpoint_store.checkpoint_load_error
  | Constitution_unreadable of World_constitution_store.read_error
      (** The world's constitution ledger exists but could not be read. The
          turn is refused rather than built without its articles; the next
          turn reads the ledger again (#38354). *)

val build_base_system_prompt :
     config:Workspace.config
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> meta:keeper_meta
  -> (string, World_constitution_store.read_error) result
(** Build the keeper base system prompt from the same persisted meta/profile
    inputs used by {!prepare_run_context}. This is the only system prompt a
    turn sends, direct or autonomous. *)

val prepare_run_context :
     config:Workspace.config
  -> meta:keeper_meta
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> base_dir:string
  -> runtime_id:string
  -> ?temperature:float
  -> ?shared_context:Agent_core.Context.t
  -> ?checkpoint:Agent_core.Checkpoint.t
  -> unit
  -> (run_context, prepare_error) result
(** Resolve [temperature] as the caller fallback; a temperature declared by the
    selected runtime model always wins. [profile_defaults] is the immutable
    pre-dispatch snapshot. [checkpoint] is an already admitted direct
    continuation; when supplied it is the history source instead of a second
    disk read. A missing or superseded checkpoint starts fresh; every other
    load failure returns its typed error before prompt construction. An
    unreadable constitution ledger returns [Constitution_unreadable]. *)

(** Whether the turn starts from a checkpoint it loaded. *)
val loaded_checkpoint_present : run_context -> bool
