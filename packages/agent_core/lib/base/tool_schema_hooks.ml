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

let current : (module S) option Atomic.t = Atomic.make None

let install hooks = Atomic.set current hooks

let with_provider_turn ~ordinal operation =
  match Atomic.get current with
  | None -> operation ()
  | Some (module H) -> H.with_provider_turn ~ordinal operation
;;

let with_site site operation =
  match Atomic.get current with
  | None -> operation ()
  | Some (module H) -> H.with_site site operation
;;

let measure ~site ?schema operation =
  match Atomic.get current with
  | None -> operation ()
  | Some (module H) -> H.measure ~site ?schema operation
;;

let encode ~site ~schema operation =
  match Atomic.get current with
  | None -> operation ()
  | Some (module H) -> H.encode ~site ~schema operation
;;

let surface ~site schemas =
  match Atomic.get current with
  | None -> ()
  | Some (module H) -> H.surface ~site schemas
;;

let cache ~schema outcome =
  match Atomic.get current with
  | None -> ()
  | Some (module H) -> H.cache ~schema outcome
;;
