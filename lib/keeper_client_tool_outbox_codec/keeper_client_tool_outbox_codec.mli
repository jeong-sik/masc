(** Pure codec for committed official-client tool-result receipts. The runtime
    outbox and offline blob maintenance share this source authority. *)

(** The call arguments a receipt echoes. [Unknown] is a receipt written for a
    call whose arguments were not recorded; no value stands in for them. On
    disk [Known v] is [{"known": v}] and [Unknown] is [{"unknown": true}], so a
    receipt written before this type, whose [arguments] is the bare value, is
    refused by {!validate} and not read as [Known]. *)
type arguments =
  | Known of Yojson.Safe.t
  | Unknown

type receipt =
  { thread_id : string
  ; turn_id : string
  ; call_id : string
  ; tool_name : string
  ; arguments : arguments
  ; response : Yojson.Safe.t
  }

val arguments_of_json : Yojson.Safe.t -> (arguments, string) result
(** The inverse of the [arguments] field of {!to_json}. Anything but the two
    encodings is an [Error], including a bare value. *)

val to_json : receipt -> Yojson.Safe.t

val host_to_json :
  producer_id:string -> runtime_label:string -> turn_count:int ->
  invocation_index:int -> call_id:string -> tool_name:string ->
  arguments:arguments -> response:Yojson.Safe.t -> Yojson.Safe.t

val filename : Yojson.Safe.t -> string
(** SHA256 of the exact compact JSON followed by [.json]. *)

val validate : path:string -> Yojson.Safe.t -> (unit, string) result
(** Accept only the complete vendor six-field or host eight-field envelope,
    including nonempty identities, UUIDv7 host producer, nonnegative host
    ordinals and exact filename digest. [arguments] must be one of the two
    {!arguments} encodings and [response] is arbitrary JSON data. This performs
    no file I/O or runtime scheduling. *)
