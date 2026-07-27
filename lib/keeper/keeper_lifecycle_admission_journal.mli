(** Private current-schema journal authority for lifecycle admission. *)

val journal_leaf : string -> string

val authority_lock_path :
  Workspace.config ->
  string ->
  (string, Keeper_lifecycle_admission_durable_types.authority_failure) result

val decode_exact :
  string ->
  (Keeper_lifecycle_admission_durable_types.decoded, unit) result

val journal_parent :
  Workspace.config ->
  ( Eio.Fs.dir_ty Eio.Path.t
  , Keeper_lifecycle_admission_durable_types.authority_failure )
  result

val journal_entropy :
  unit ->
  ( Eio.Flow.source_ty Eio.Resource.t
  , Keeper_lifecycle_admission_durable_types.authority_failure )
  result

val read_locked :
  Workspace.config ->
  string ->
  Keeper_lifecycle_admission_durable_types.decision
