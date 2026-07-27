(** Failure-atomic runtime/metadata convergence over the exact current journal. *)

type preference =
  [ `Rollback
  | `Forward
  ]

type resolution =
  | Rolled_back
  | Forward_committed

type recovery_failure =
  | Journal_failure of Keeper_runtime_meta_journal.error
  | Runtime_convergence_failed of string
  | Metadata_convergence_failed of string
  | Shutdown_supersession_failed of string
  | Shutdown_supersession_binding_invalid
  | Unrelated_runtime_observed of string option
  | Unrelated_metadata_observed
  | Both_directions_failed of
      { rollback : string
      ; forward : string
      }

type recovery_summary =
  { recovered : int
  ; cleared : int
  ; unresolved : (string * string) list
  }

val recovery_failure_to_string : recovery_failure -> string

val prepare :
  operation:Keeper_runtime_meta_journal.operation ->
  shutdown_supersession:Keeper_shutdown_supersession.t option ->
  config:Workspace.config ->
  keeper_name:string ->
  previous_runtime:string option ->
  candidate_runtime:string option ->
  previous_meta:Keeper_meta_contract.keeper_meta option ->
  candidate_meta:Keeper_meta_contract.keeper_meta ->
  (Keeper_runtime_meta_journal.intent, recovery_failure) result

val recover :
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  Workspace.config ->
  Keeper_runtime_meta_journal.intent ->
  prefer:preference ->
  (resolution, recovery_failure) result

val complete_forward :
  ?lifecycle_token:Keeper_lifecycle_reservation.token ->
  Keeper_lifecycle_admission.Durable_transaction.permit ->
  Workspace.config ->
  Keeper_runtime_meta_journal.intent ->
  (unit, recovery_failure) result

val recover_pending : Workspace.config -> recovery_summary

module For_testing : sig
  val with_metadata_convergence_failure :
    (preference -> string option) ->
    (unit -> 'a) ->
    'a
end
