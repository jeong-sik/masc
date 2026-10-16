(** Read/cache boundary for the legacy aggregate transcript endpoint. History
    authority includes retained stores, independently of live mutation rights.
    Callers validate [keeper_name] with [Keeper_config.validate_name] first. *)

type error = Unknown_keeper | History_unavailable of string

val error_to_string : error -> string

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
    files and device/inode identity. These observations refuse detected drift;
    they do not make multiple stores an atomic snapshot. *)
