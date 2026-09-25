(** Durable next-cycle runtime authority.

    A provider response can checkpoint before MASC's accept predicate rejects
    it. The input may not be admitted again in the same cycle, so the remaining
    lane suffix belongs to the next cycle. This store gives that authority the
    same restart lifetime as the checkpoint it escapes. *)

type error =
  | Invalid_keeper_name of string
  | Malformed of string
  | Io_error of string

val error_to_string : error -> string

(** [keepers_dir] is the cluster-aware keeper runtime directory
    ({!Workspace.keepers_runtime_dir}); two named clusters with the same keeper
    name keep separate hints. [base_path] is the durable-write ownership root. *)
val path_for : keepers_dir:string -> keeper_name:string -> string

val load :
  keepers_dir:string ->
  keeper_name:string ->
  (Keeper_turn_driver.deferred_runtime_lane option, error) result

val save :
  base_path:string ->
  keepers_dir:string ->
  keeper_name:string ->
  Keeper_turn_driver.deferred_runtime_lane ->
  (unit, error) result

val clear :
  base_path:string ->
  keepers_dir:string ->
  keeper_name:string ->
  (unit, error) result

