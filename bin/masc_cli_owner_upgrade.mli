val with_http :
  (Eio.Switch.t -> float Eio.Time.clock_ty Eio.Resource.t -> 'a) -> 'a
(** One Eio run with the HTTP client pool these commands use. *)

val with_selected_owner :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  base_path:string ->
  port:int ->
  agent:string ->
  expected_version:string ->
  login:(unit -> int) ->
  (Server_upgrade_preparation.t -> ('a, Server_upgrade_preparation.error) result) ->
  ('a, Server_upgrade_preparation.error) result
(** Reads [/health?full=1] on loopback [port], requires this canonical
    [base_path] at [expected_version], signs in as [agent], proves admin access
    and captures the lease owner's identity, then hands the prepared owner to
    the caller and closes it afterwards. Nothing is signalled here; the caller
    decides whether to request termination. *)

val inspect : base_path:string -> port:int -> int
val stop : base_path:string -> port:int -> agent:string -> expected_version:string -> login:(unit -> int) -> int
(** Requests graceful termination only after explicit selection. Never forces a
    process down; waits for the authenticated workspace owner's lease release. *)
