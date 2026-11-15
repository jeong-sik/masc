(** runtime.toml edits through the running server of the workspace
    (RFC-0482 §3.2). The server of a single user that the kernel names as
    lease owner and announcer of the port is the one writer while it runs;
    the command writes the file itself only when nothing holds the lease. *)

type server
(** A server that {!find} named through the kernel. Only {!find} makes one,
    and every request below asks the kernel again right before it sends the
    bearer. *)

type target =
  | Running_server of server
  | No_server  (** Nothing holds the lease: the command is the writer. *)

type saved =
  | Unchanged
  | Saved of { path : string }

val find :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  base_path:string -> port:int -> agent:string -> (target, string) result
(** [No_server] when nothing holds the lease of [base_path], without any
    request. [Running_server] when the kernel names the server of a single
    user as lease owner and announcer of [port], it answers [/health/ready]
    with 200, and [agent] has a persisted sign-in. Every other answer is an
    [Error] that says what holds the workspace and that nothing was saved. *)

(** The runtime.toml text the server reads, with the revision and path it
    read it at. *)
type source = { text : string; revision : string; path : string }

val fetch :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server -> (source, string) result

val save :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server ->
  edit:(string -> (string, string) result) -> (saved, string) result

val store :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server -> source -> edited:string ->
  (saved, string) result
(** Save [edited] over [source] with the revision and path it was read at. *)

(** What voice-local-setup decides its changes against. *)
type voice_ground =
  { revision : string
  ; standalone : string option
  ; speaking : (string * Voice_config.endpoint_kind option) list
  }

val fetch_voice_ground :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server -> (voice_ground, string) result

val apply_voice_setup :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server -> revision:string ->
  Voice_setup.change list -> (unit, string) result

val publish_setup_text :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server -> source -> text:string ->
  (Runtime_setup_batch.commit_record, Runtime_setup_batch.error) result

val table_store :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> server ->
  (Masc.Runtime_table_edit.store, string) result

val with_client :
  (clock:float Eio.Time.clock_ty Eio.Resource.t -> 'a) -> 'a
