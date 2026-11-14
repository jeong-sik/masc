val with_http :
  (Eio.Switch.t -> float Eio.Time.clock_ty Eio.Resource.t -> 'a) -> 'a
(** One Eio run with the HTTP client pool these commands use. *)

val with_selected_owner :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  server:Server_upgrade_preparation.single_user_server ->
  agent:string ->
  expected_version:string ->
  login:(unit -> int) ->
  (Server_upgrade_preparation.t -> ('a, Server_upgrade_preparation.error) result) ->
  ('a, Server_upgrade_preparation.error) result
(** In order: asks the kernel again whether it names [server] as lease owner
    and announcer of its port, reads the compact [/health] version there and
    requires [expected_version], and only then signs in as [agent]
    ([Server_upgrade_preparation.authorize_initial]); then captures the lease
    owner's identity, asks the kernel again and proves admin access with the
    bearer ([Server_upgrade_preparation.prepare]); then hands the prepared
    owner to the caller and closes it afterwards. Nothing is signalled here;
    the caller decides whether to request termination. *)

val inspect : base_path:string -> port:int -> int
val stop : base_path:string -> port:int -> agent:string -> expected_version:string -> login:(unit -> int) -> int
(** Requests graceful termination only after explicit selection. Never forces a
    process down; waits for the authenticated workspace owner's lease release. *)
