(* Independent whole-list oracle adapted from exact8e surface_digest. Only the
   schema projection is an explicit already-converted JSON carrier. This does
   not call the candidate, concatenate candidate chunks, or parse JSON bytes. *)
open Fixture_carrier

let source_to_json = function
  | Builtin -> `Assoc [ "kind", `String "builtin" ]
  | Attached { provider_id; endpoint; remote_name } ->
    `Assoc
      [ "kind", `String "attached"
      ; "provider_id", `String provider_id
      ; "endpoint", `String endpoint
      ; "remote_name", `String remote_name
      ]
;;

let canonical_bytes surface =
  `List
    (List.map
       (fun { source; schema_json } ->
          `Assoc [ "source", source_to_json source; "schema", schema_json ])
       surface)
  |> Yojson.Safe.sort
  |> Yojson.Safe.to_string
;;

let digest surface = canonical_bytes surface |> Digestif.SHA256.digest_string
;;

(* Kept separate for conversion-failure probes. No digest is published when
   conversion fails. The original projects every row before serialization. *)
let digest_projected ~to_json rows =
  `List (List.map to_json rows)
  |> Yojson.Safe.sort
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
;;
