(** Pure immutable registry transitions for per-provider admission schedulers. *)

type key

val key :
  kind:string -> base_url:string -> secret:Secret.identity option -> key

val key_equal : key -> key -> bool

(** What one config declares for its endpoint identity: the permit count
    and the priority run limit. *)
type allowance =
  { max : int
  ; priority_run_limit : int option
  }

val allowance_equal : allowance -> allowance -> bool

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
    next conflicting request admissible. An identity the consumer has
    published ({!publish}) reports no conflict: its scheduler runs under the
    published allowance, whatever an older config declared. *)

val install :
  key ->
  declared:allowance ->
  candidate:'scheduler ->
  'scheduler t ->
  'scheduler t * 'scheduler resolution
(** Install [candidate] only when the key is still absent. A concurrent winner
    is reused and conflict reporting follows {!resolve_existing}. *)

(** What {!publish} did to an identity's scheduler. *)
type 'scheduler publication =
  | Published_new of 'scheduler  (** [candidate] was installed. *)
  | Published_unchanged of 'scheduler  (** The allowance was already [declared]. *)
  | Published_changed of 'scheduler
      (** An existing scheduler whose allowance the caller now changes to
          [declared]. *)

val publish :
  key ->
  declared:allowance ->
  candidate:'scheduler ->
  'scheduler t ->
  'scheduler t * 'scheduler publication
(** Make [declared] the identity's allowance and mark it published,
    installing [candidate] when the identity has no scheduler yet. *)

val find_scheduler : key -> 'scheduler t -> 'scheduler option
