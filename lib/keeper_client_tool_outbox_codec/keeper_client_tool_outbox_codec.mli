(** Pure codec for committed official-client tool-result receipts. The runtime
    outbox and offline blob maintenance share this source authority. *)

type receipt =
  { thread_id : string
  ; turn_id : string
  ; call_id : string
  ; tool_name : string
  ; arguments : Yojson.Safe.t
  ; response : Yojson.Safe.t
  }

val to_json : receipt -> Yojson.Safe.t

val host_to_json :
  producer_id:string -> runtime_label:string -> turn_count:int ->
  invocation_index:int -> call_id:string -> tool_name:string ->
  arguments:Yojson.Safe.t -> response:Yojson.Safe.t -> Yojson.Safe.t

val filename : Yojson.Safe.t -> string
(** SHA256 of the exact compact JSON followed by [.json]. *)

val validate : path:string -> Yojson.Safe.t -> (unit, string) result
(** Accept only the complete vendor six-field or host eight-field envelope,
    including nonempty identities, UUIDv7 host producer, nonnegative host
    ordinals and exact filename digest. [arguments] and [response] are arbitrary
    JSON data. This performs no file I/O or runtime scheduling. *)
