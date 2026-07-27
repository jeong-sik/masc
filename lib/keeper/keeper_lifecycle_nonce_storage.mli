(** Private current-schema durable HEAD storage for lifecycle nonces. *)

module Head = Fs_compat.Capability_head

val fd_backed_parent_opening_key : unit Eio.Fiber.key

val ( let* ) :
  ('a, 'error) result ->
  ('a -> ('b, 'error) result) ->
  ('b, 'error) result

val with_head_parent :
  Eio.Fs.dir_ty Eio.Path.t ->
  (Eio.Fs.dir_ty Eio.Path.t -> 'a) ->
  'a

val root_path : Workspace.config -> string
val authority_leaf : keeper_id:string -> string

val decode_row :
  keeper_id:string ->
  string ->
  ( Keeper_lifecycle_nonce_types.row
  , Keeper_lifecycle_nonce_types.corruption )
  result

val prepare_root :
  Workspace.config ->
  (Eio.Fs.dir_ty Eio.Path.t, Keeper_lifecycle_nonce_types.error) result

val entropy_source :
  unit ->
  ( Eio.Flow.source_ty Eio.Resource.t
  , Keeper_lifecycle_nonce_types.error )
  result

val observed_nonce : keeper_id:string -> string option -> int64 option
val runtime_max_nonce : int64

val next_for_config_with_hooks :
  snapshot_warnings:(Head.snapshot -> Head.settlement_warning list) ->
  compare_and_swap:
    (secure_random:Eio.Flow.source_ty Eio.Resource.t ->
     parent:Eio.Fs.dir_ty Eio.Path.t ->
     leaf:string ->
     expected:Head.cursor ->
     row:string ->
     (Head.publication, Head.failure) result) ->
  config:Workspace.config ->
  keeper_id:string ->
  owner_id:string ->
  ?expected_source:Keeper_lifecycle_nonce_types.identity ->
  ?floor:int64 ->
  unit ->
  (int64, Keeper_lifecycle_nonce_types.error) result
