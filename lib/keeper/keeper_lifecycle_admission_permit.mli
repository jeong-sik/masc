(** Private counted-lease lifetime for durable lifecycle permits. *)

val active_permit_scope_key :
  Keeper_lifecycle_admission_durable_types.permit Eio.Fiber.key

val active_permit_lease_key :
  Keeper_lifecycle_admission_durable_types.permit_lease Eio.Fiber.key

val with_permit_lifecycle :
  Keeper_lifecycle_admission_durable_types.permit ->
  (Keeper_lifecycle_admission_durable_types.permit_lifecycle -> 'a) ->
  'a

val with_active_permit :
  base_path:string ->
  keeper_name:string ->
  evidence:Keeper_lifecycle_admission_durable_types.evidence option ->
  (Keeper_lifecycle_admission_durable_types.permit -> 'a) ->
  'a

val permit_scope_matches :
  Keeper_lifecycle_admission_durable_types.permit ->
  base_path:string ->
  string ->
  bool

val lease_is_live_for_permit :
  Keeper_lifecycle_admission_durable_types.permit ->
  Keeper_lifecycle_admission_durable_types.permit_lease option ->
  bool

val try_with_reentrant_lease :
  Keeper_lifecycle_admission_durable_types.permit ->
  (Keeper_lifecycle_admission_durable_types.permit -> 'a) ->
  'a option
