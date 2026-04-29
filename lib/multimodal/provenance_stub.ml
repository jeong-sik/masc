(* Provenance_stub — Cycle 24 / Tier B8. *)

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
        | _ -> Error "origin_artifact_ids must be a JSON list"
      in
      let created_by_result =
        match List.assoc_opt "created_by" kv with
        | Some (`String s) -> Ok s
        | _ -> Error "created_by must be a JSON string"
      in
      let created_at_result =
        match List.assoc_opt "created_at" kv with
        | Some (`Float f) -> Ok f
        | Some (`Int i) -> Ok (float_of_int i)
        | _ -> Error "created_at must be a JSON number"
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
  | _ -> Error "provenance_stub must be a JSON object"
