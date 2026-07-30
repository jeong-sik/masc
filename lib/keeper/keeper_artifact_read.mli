(** Explicit, bounded model read for content-addressed Tool results.

    A sha256 is the existing public-read artifact capability used by the HTTP
    endpoint. The handler introduces no second ownership or run-scope Gate.
    It returns one typed JSON page and never restores the full artifact into
    model history. *)

val default_max_bytes : int
val maximum_max_bytes : int
val minimum_max_bytes : int

type request =
  { sha256 : string
  ; offset : int
  ; max_bytes : int
  }

type page_encoding =
  | Utf_8
  | Base64

type page =
  { sha256 : string
  ; offset : int
  ; next_offset : int
  ; total_bytes : int
  ; eof : bool
  ; encoding : page_encoding
  ; content : string
  }

val handle :
  base_path:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

module For_testing : sig
  val request_of_json : Yojson.Safe.t -> (request, string) result
  val page : request -> string -> (page, string) result
  val page_to_json : page -> Yojson.Safe.t
end
