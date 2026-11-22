(** Generic, domain-agnostic SDK hooks for observing tool schema wire JSON,
    byte-count caching, surface preparation, and provider turn boundaries.

    Agent Core has zero knowledge of any host domain (such as Keepers, routing
    runs, or lane attempts). A host may install an implementation via
    {!install}; when no hooks are installed every entry point is a direct
    zero-allocation pass-through. *)

type sdk_site =
  | Prepare_json
  | Wire_json
  | Byte_count_lookup
  | Byte_count_encode
  | Byte_count_publication

type json_lookup =
  | Existing_json
  | Created_json

type byte_lookup =
  | Existing_byte_count
  | Missing_byte_count

type publication =
  | Published_byte_count
  | Concurrent_byte_count_won

type cache_outcome =
  | Json_lookup of json_lookup
  | Byte_lookup of
      { json : json_lookup
      ; count : byte_lookup
      }
  | Byte_publication of publication

module type S = sig
  val with_provider_turn : ordinal:int -> (unit -> 'a) -> 'a
  val with_site : sdk_site -> (unit -> 'a) -> 'a
  val measure : site:sdk_site -> ?schema:Types.tool_schema -> (unit -> 'a) -> 'a
  val encode : site:sdk_site -> schema:Types.tool_schema -> (unit -> string) -> string
  val surface : site:sdk_site -> (unit -> Types.tool_schema list) -> unit
  val cache : schema:Types.tool_schema -> cache_outcome -> unit
end

val install : (module S) option -> unit
val with_provider_turn : ordinal:int -> (unit -> 'a) -> 'a
val with_site : sdk_site -> (unit -> 'a) -> 'a
val measure : site:sdk_site -> ?schema:Types.tool_schema -> (unit -> 'a) -> 'a
val encode : site:sdk_site -> schema:Types.tool_schema -> (unit -> string) -> string
val surface : site:sdk_site -> (unit -> Types.tool_schema list) -> unit
val cache : schema:Types.tool_schema -> cache_outcome -> unit
