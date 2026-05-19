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

let json_kind_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"
  | `Tuple _ -> "tuple"
  | `Variant _ -> "variant"

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
