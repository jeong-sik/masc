(* Provenance_stub — Cycle 24 / Tier B8. *)

(* Inline kind_name helper — multimodal sub-lib lists (libraries shared_types
   unix yojson) and intentionally excludes masc_core (Json_util's home) for
   RFC-0056 dependency-leaf isolation. The 12-line cost of an inline copy is
   the smaller trade-off vs widening the sub-lib's dependency surface. Iter#32
   PR #16534 set this same pattern for chronicle_event + autonomous/stimulus. *)
let kind_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"

type t = {
  origin_artifact_ids : Shared_types.Artifact_id.t list;
  created_by : string;
  created_at : float;
}

let empty ~created_by ~created_at =
  { origin_artifact_ids = []; created_by; created_at }

let to_json p =
  `Assoc
    [
      ( "origin_artifact_ids",
        `List
          (List.map Shared_types.Artifact_id.to_json p.origin_artifact_ids)
      );
      ("created_by", `String p.created_by);
      ("created_at", `Float p.created_at);
    ]

let of_json = function
  | `Assoc kv ->
      let origin_result =
        match List.assoc_opt "origin_artifact_ids" kv with
        | Some (`List xs) ->
            List.fold_right
              (fun j acc ->
                match (Shared_types.Artifact_id.of_json j, acc) with
                | Ok id, Ok rest -> Ok (id :: rest)
                | Error e, _ -> Error e
                | _, Error e -> Error e)
              xs (Ok [])
        | None -> Ok []
        | Some other ->
            Error
              (Printf.sprintf
                 "origin_artifact_ids must be a JSON list (got %s)"
                 (kind_name other))
      in
      let created_by_result =
        match List.assoc_opt "created_by" kv with
        | Some (`String s) -> Ok s
        | None -> Error "created_by is required"
        | Some other ->
            Error
              (Printf.sprintf
                 "created_by must be a JSON string (got %s)"
                 (kind_name other))
      in
      let created_at_result =
        match List.assoc_opt "created_at" kv with
        | Some (`Float f) -> Ok f
        | Some (`Int i) -> Ok (float_of_int i)
        | None -> Error "created_at is required"
        | Some other ->
            Error
              (Printf.sprintf
                 "created_at must be a JSON number (got %s)"
                 (kind_name other))
      in
      (match origin_result, created_by_result, created_at_result with
       | Ok ids, Ok name, Ok ts ->
           Ok
             {
               origin_artifact_ids = ids;
               created_by = name;
               created_at = ts;
             }
       | Error e, _, _ | _, Error e, _ | _, _, Error e -> Error e)
  | other ->
      Error
        (Printf.sprintf "provenance_stub must be a JSON object (got %s)"
           (kind_name other))
