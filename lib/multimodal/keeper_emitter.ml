(* Keeper_emitter — see keeper_emitter.mli for design rationale. *)

let multimodal_key = "multimodal_artifacts"

let raw_artifact_to_json
    ~(id : string)
    ~(kind_tag : Artifact.kind_tag)
    ~(payload_json : Yojson.Safe.t)
    ~(metadata : Yojson.Safe.t) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String id);
      ("kind_hint", `String (Artifact.kind_tag_to_string kind_tag));
      ("payload_json", payload_json);
      ("metadata", metadata);
    ]

let append_to_list
    (existing : Yojson.Safe.t option)
    (entry : Yojson.Safe.t) : Yojson.Safe.t =
  match existing with
  | Some (`List xs) -> `List (xs @ [ entry ])
  | _ -> `List [ entry ]

let emit
    ~(working_context : Yojson.Safe.t option)
    ~(id : string)
    ~(kind_tag : Artifact.kind_tag)
    ~(payload_json : Yojson.Safe.t)
    ~(metadata : Yojson.Safe.t) : Yojson.Safe.t option =
  let entry = raw_artifact_to_json ~id ~kind_tag ~payload_json ~metadata in
  let kv =
    match working_context with
    | Some (`Assoc kv) -> kv
    | _ -> []
  in
  let prior_list = List.assoc_opt multimodal_key kv in
  let new_list = append_to_list prior_list entry in
  let kv_without =
    List.filter (fun (k, _) -> k <> multimodal_key) kv
  in
  Some (`Assoc ((multimodal_key, new_list) :: kv_without))

let emit_many
    ~(working_context : Yojson.Safe.t option)
    (entries :
      (string * Artifact.kind_tag * Yojson.Safe.t * Yojson.Safe.t)
      list) : Yojson.Safe.t option =
  List.fold_left
    (fun wc (id, kind_tag, payload_json, metadata) ->
      emit ~working_context:wc ~id ~kind_tag ~payload_json ~metadata)
    working_context entries
