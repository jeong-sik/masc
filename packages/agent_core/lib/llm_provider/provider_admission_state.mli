(** Pure immutable registry transitions for per-provider admission schedulers. *)

type key

val key :
  kind:string -> base_url:string -> secret:Secret.identity option -> key

(** What one config declares for its endpoint identity: the permit count
    and the priority run limit. *)
type allowance =
  { max : int
  ; priority_run_limit : int option
  }

type conflict =
  { kind : string
  ; base_url : string
  ; authoritative : allowance
  ; declared : allowance
  }

type 'scheduler resolution =
  { scheduler : 'scheduler
  ; conflict : conflict option
  }

type 'scheduler t

val empty : 'scheduler t

val resolve_existing :
  key ->
  declared:allowance ->
  'scheduler t ->
  ('scheduler t * 'scheduler resolution) option
(** Resolve an existing scheduler and report a conflict on every resolution
    whose [declared] allowance differs from its authoritative declaration. Consumers
    reject the conflict before taking a permit; rejection must not make the
    next conflicting request admissible. *)

val install :
  key ->
  declared:allowance ->
  candidate:'scheduler ->
  'scheduler t ->
  'scheduler t * 'scheduler resolution
(** Install [candidate] only when the key is still absent. A concurrent winner
    is reused and conflict reporting follows {!resolve_existing}. *)

val find_scheduler : key -> 'scheduler t -> 'scheduler option
