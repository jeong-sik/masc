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

let of_json = function
  | `Assoc kv -> (
      match List.assoc_opt "kind" kv with
      | Some (`String "lazy") -> Ok (Lazy_payload (fun () -> ""))
      | Some (`String "blob_ref") -> (
          match List.assoc_opt "ref" kv with
          | Some (`String s) -> Ok (Blob_ref s)
          | _ -> Error "blob_ref payload missing 'ref' string field")
      | Some (`String "streaming") -> (
          match List.assoc_opt "bytes" kv with
          | Some (`Int n) -> Ok (Streaming n)
          | _ -> Error "streaming payload missing 'bytes' int field")
      | Some (`String other) ->
          Error (Printf.sprintf "unknown payload kind: %s" other)
      | _ -> Error "payload missing 'kind' string field")
  | _ -> Error "payload must be a JSON object"
