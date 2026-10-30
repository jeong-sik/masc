(* Payload — Cycle 24 / Tier B8.
   See payload.mli for design rationale. *)

type t =
  | Lazy_payload of (unit -> string)
  | Blob_ref of string
  | Streaming of int

let to_json = function
  | Lazy_payload _ -> `Assoc [ ("kind", `String "lazy") ]
  | Blob_ref s ->
      `Assoc [ ("kind", `String "blob_ref"); ("ref", `String s) ]
  | Streaming n ->
      `Assoc [ ("kind", `String "streaming"); ("bytes", `Int n) ]

(* [Json_kind] is the yojson-only leaf this library can reach; masc_core,
   where the name used to live, is the dependency it must not take. *)
let json_kind_name = Shared_types.Json_kind.name

let of_json = function
  | `Assoc kv -> (
      match List.assoc_opt "kind" kv with
      | Some (`String "lazy") -> Ok (Lazy_payload (fun () -> ""))
      | Some (`String "blob_ref") -> (
          match List.assoc_opt "ref" kv with
          | Some (`String s) -> Ok (Blob_ref s)
          | None -> Error "blob_ref payload missing 'ref' field"
          | Some other ->
              Error
                (Printf.sprintf
                   "blob_ref payload 'ref' field must be a string (received %s)"
                   (json_kind_name other)))
      | Some (`String "streaming") -> (
          match List.assoc_opt "bytes" kv with
          | Some (`Int n) -> Ok (Streaming n)
          | None -> Error "streaming payload missing 'bytes' field"
          | Some other ->
              Error
                (Printf.sprintf
                   "streaming payload 'bytes' field must be an int (received %s)"
                   (json_kind_name other)))
      | Some (`String other) ->
          Error (Printf.sprintf "unknown payload kind: %s" other)
      | None -> Error "payload missing 'kind' field"
      | Some other ->
          Error
            (Printf.sprintf
               "payload 'kind' field must be a string (received %s)"
               (json_kind_name other)))
  | other ->
      Error
        (Printf.sprintf "payload must be a JSON object (received %s)"
           (json_kind_name other))
