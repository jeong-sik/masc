(** Product-owned durable recovery policy for OAS Agent executions. *)

type init_error
type prepare_error
type finish_error
type prepared

val initialize
  :  sw:Eio.Switch.t
  -> domain_mgr:[> Eio.Domain_manager.ty ] Eio.Domain_manager.t
  -> fs:Eio.Fs.dir_ty Eio.Path.t
  -> base_path:string
  -> domain_count:int
  -> (unit, init_error) result
(** Create the application-lifetime OAS execution runtime and the private
    [base_path/.masc/oas-execution/{runs,slots}] roots. *)

val prepare
  :  sw:Eio.Switch.t
  -> recovery_key:string
  -> Agent_sdk.Agent.t
  -> (prepared, prepare_error) result
(** Bind one Agent API call to its durable execution scope.

    A stable [recovery_key] is required. Its durable slot and the exact
    versioned record in the Agent's Session context must agree before an
    existing scope is resumed. Calls without a caller-owned stable identity
    are rejected; there is no non-durable compatibility path. *)

val execution_store : prepared -> Agent_sdk.Agent.execution_store

val finish : prepared -> (unit, finish_error) result
(** Retire the recovery slot after a successful or typed non-Internal Agent
    terminal return. The durable slot is removed before the Session-context
    record. Callers must use {!retain_failure} for [Error.Internal], which is
    also OAS's public category for unknown effect settlement. *)

val finish_checkpoint
  :  prepared
  -> Agent_sdk.Checkpoint.t
  -> (Agent_sdk.Checkpoint.t, finish_error) result
(** Retire the recovery slot and return a copy of the consumer checkpoint with
    the MASC recovery record removed. The caller must durably persist the
    returned checkpoint at the same consumer-settlement boundary. *)

val retain_failure : prepared -> unit
(** Release the in-process claim without deleting the durable slot or context
    record. Callers use this for OAS Internal errors and unexpected exceptions,
    where starting a fresh scope could duplicate an effect with unknown
    settlement. *)

val init_error_to_string : init_error -> string
val prepare_error_to_string : prepare_error -> string
val finish_error_to_string : finish_error -> string
