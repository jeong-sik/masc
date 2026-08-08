(** Private ownership wrapper for one fresh Agent execution journal. *)

type runtime
type store
type locator

type terminal_outcome =
  | Terminal_succeeded
  | Terminal_failed
  | Terminal_cancelled

type operator_repair_reason = Execution_agent_scope.operator_repair_reason =
  | Effect_outcome_unknown

type recovery_action = Execution_agent_scope.recovery_action =
  | Retire
  | Operator_repair_required of operator_repair_reason

type terminal_disposition =
  { outcome : terminal_outcome
  ; recovery : recovery_action
  }

val create_runtime
  :  sw:Eio.Switch.t
  -> domain_mgr:_ Eio.Domain_manager.t
  -> domain_count:int
  -> (runtime, Error.sdk_error) result

val runtime_codec : runtime -> Execution_codec_executor.t

val store
  :  runtime:runtime
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> ?on_scope_ready:(locator -> (unit, string) result)
  -> ?on_terminal_disposition:(terminal_disposition -> (unit, string) result)
  -> ?resume:locator
  -> unit
  -> store

val locator_to_yojson : locator -> Yojson.Safe.t
val locator_of_yojson : Yojson.Safe.t -> (locator, string) result
val locator_run_id : locator -> Execution_event.Run_id.t

val with_fresh
  :  store
  -> Agent_types.t
  -> (sw:Eio.Switch.t
      -> Execution_agent_scope.t
      -> ('a, Provider_failure_attribution.detailed_error) result)
  -> ('a, Provider_failure_attribution.detailed_error) result

val with_store
  :  store
  -> Agent_types.t
  -> (sw:Eio.Switch.t
      -> Execution_agent_scope.t
      -> ('a, Provider_failure_attribution.detailed_error) result)
  -> ('a, Provider_failure_attribution.detailed_error) result

val is_resume : store -> bool

val with_scope
  :  ?on_terminal_disposition:(terminal_disposition -> (unit, string) result)
  -> Execution_agent_scope.t
  -> (unit -> ('a, Provider_failure_attribution.detailed_error) result)
  -> ('a, Provider_failure_attribution.detailed_error) result
