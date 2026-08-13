(** Durable effect shell for one Keeper Agent Core API-call execution store.

    Operation identity is computed by {!Keeper_agent_core_execution_identity}
    before this module is entered.  This shell alone creates the scope
    directory, persists the opaque Agent Core locator, selects fresh versus
    crash-resume mode, and retires or retains recovery authority after the
    terminal journal disposition. *)

type execution_mode =
  | Fresh_scope
  | Crash_resume of Agent_core.Agent.execution_locator

type terminal_record = Agent_core.Agent.execution_terminal_disposition

type prepare_error =
  | Runtime_owner_unavailable
  | Filesystem_unavailable
  | Scope_directory_creation_failed of
      { path : string
      ; detail : string
      }
  | Scope_directory_without_locator of string
  | Locator_invalid of
      { path : string
      ; detail : string
      }
  | Terminal_record_present of terminal_record
  | Terminal_record_invalid of
      { path : string
      ; detail : string
      }

type prepared = private
  { operation_id : Keeper_agent_core_execution_identity.operation_id
  ; mode : execution_mode
  ; execution_store : Agent_core.Agent.execution_store
  }

type factory =
  Keeper_agent_core_execution_identity.t -> (prepared, prepare_error) result

val prepare
  :  base_path:string
  -> owner:Runtime_agent_execution_owner.t
  -> Keeper_agent_core_execution_identity.t
  -> (prepared, prepare_error) result
(** Prepare exactly one store at the Agent API-call boundary.  An absent scope
    directory creates a fresh store.  A valid retained locator creates a
    resume store.  A directory without locator or a terminal record fails
    closed; it is never deleted, rewritten, or guessed into a fresh call. *)

val current_owner_factory : base_path:string -> factory
(** Resolve the application-lifetime runtime owner only when the factory is
    invoked at the API-call boundary.  Absence is a typed failure, never an
    inline execution-runtime fallback. *)

val operation_directory
  :  base_path:string
  -> Keeper_agent_core_execution_identity.operation_id
  -> string

val execution_mode_to_string : execution_mode -> string
val prepare_error_to_string : prepare_error -> string
val prepare_error_to_core_error : prepare_error -> Agent_core.Error.t
