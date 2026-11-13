val with_http :
  (Eio.Switch.t -> float Eio.Time.clock_ty Eio.Resource.t -> 'a) -> 'a
(** One Eio run with the HTTP client pool these commands use. *)

val listener_refusal_message :
  base_path:string -> port:int -> Server_upgrade_preparation.listener_refusal -> string
(** Why no operator credential was sent to [port], up to what the command
    left undone, which the caller adds. *)

val with_selected_owner :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  listener:Server_upgrade_preparation.single_user_listener ->
  agent:string ->
  expected_version:string ->
  login:(unit -> int) ->
  (Server_upgrade_preparation.t -> ('a, Server_upgrade_preparation.error) result) ->
  ('a, Server_upgrade_preparation.error) result
(** Takes the workspace and the port from [listener], the word of the kernel
    that the owner of the lease listens there. Reads [/health?full=1] on that
    port, requires the workspace at [expected_version], signs in as [agent],
    proves admin access and captures the lease owner's identity, then hands
    the prepared owner to the caller and closes it afterwards. Nothing is
    signalled here; the caller decides whether to request termination. *)

val inspect : base_path:string -> port:int -> int
val stop : base_path:string -> port:int -> agent:string -> expected_version:string -> login:(unit -> int) -> int
(** Requests graceful termination only after explicit selection. Never forces a
    process down; waits for the authenticated workspace owner's lease release. *)
