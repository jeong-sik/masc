(** Pure immutable registry transitions for per-provider admission schedulers. *)

type key

val key :
  kind:string -> base_url:string -> secret:Secret.identity option -> key

type conflict =
  { kind : string
  ; base_url : string
  ; authoritative_max : int
  ; declared_max : int
  }

type 'scheduler resolution =
  { scheduler : 'scheduler
  ; conflict : conflict option
  }

type 'scheduler t

val empty : 'scheduler t

val resolve_existing :
  key ->
  declared_max:int ->
  'scheduler t ->
  ('scheduler t * 'scheduler resolution) option
(** Resolve an existing scheduler and claim the one-shot conflict report when
    [declared_max] differs from its authoritative declaration. *)

val install :
  key ->
  declared_max:int ->
  candidate:'scheduler ->
  'scheduler t ->
  'scheduler t * 'scheduler resolution
(** Install [candidate] only when the key is still absent. A concurrent winner
    is reused and conflict reporting follows {!resolve_existing}. *)

val find_scheduler : key -> 'scheduler t -> 'scheduler option
