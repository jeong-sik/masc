(** Read/cache boundary for the legacy aggregate transcript endpoint. History
    authority includes retained stores, independently of live mutation rights.
    Callers validate [keeper_name] with [Keeper_config.validate_name] first. *)

type error = Unknown_keeper | History_unavailable of string

val error_to_string : error -> string
(** Static public refusal text. Internal diagnostic detail is retained only
    in [History_unavailable], never interpolated into the HTTP body. *)

val read_json :
  config:Workspace.config -> keeper_name:string ->
  render:(Keeper_chat_store.chat_message list ->
          Keeper_autonomous_turn_source.turn list -> Yojson.Safe.t) ->
  (Yojson.Safe.t, error) result

val cached_json :
  config:Workspace.config -> keeper_name:string -> ttl:float ->
  render:(Keeper_chat_store.chat_message list ->
          Keeper_autonomous_turn_source.turn list -> Yojson.Safe.t) ->
  (Yojson.Safe.t, error) result
(** Unknown names and failed reads never publish successful cache values.
    Freshness is observed before lookup and around a compute, including absent
    files and device/inode identity. A later change retires cache ownership but
    still returns the already-read body; the next request reads the newer source.
    These observations do not make multiple stores an atomic snapshot. *)

module For_testing : sig
  val with_after_read_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  (** Run after strict source reads and before rendering. The process-wide hook
      is restored on return or exception; tests must not overlap other reads. *)
end
