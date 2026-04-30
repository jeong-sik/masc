(* Tool_emission — see tool_emission.mli for design. *)

let multimodal_kind_key = "__multimodal_kind"
let multimodal_id_key = "__multimodal_id"
let multimodal_metadata_key = "__multimodal_metadata"

let lookup_string (result : Yojson.Safe.t) (key : string) : string option =
  match result with
  | `Assoc kv -> (
      match List.assoc_opt key kv with
      | Some (`String s) -> Some s
      | _ -> None)
  | _ -> None

let lookup_field (result : Yojson.Safe.t) (key : string)
    : Yojson.Safe.t option =
  match result with
  | `Assoc kv -> List.assoc_opt key kv
  | _ -> None

let extract_kind_from_result (result : Yojson.Safe.t)
    : Artifact.kind_tag option =
  match lookup_string result multimodal_kind_key with
  | Some s -> Multimodal_keeper_bridge.parse_kind_hint s
  | None -> None

let extract_id_from_result (result : Yojson.Safe.t) : string option =
  lookup_string result multimodal_id_key

let strip_reserved_keys (result : Yojson.Safe.t) : Yojson.Safe.t =
  match result with
  | `Assoc kv ->
      let reserved =
        [
          multimodal_kind_key;
          multimodal_id_key;
          multimodal_metadata_key;
        ]
      in
      `Assoc (List.filter (fun (k, _) -> not (List.mem k reserved)) kv)
  | other -> other

let emit_from_tool_result
    ~(working_context : Yojson.Safe.t option)
    ~(result : Yojson.Safe.t) : Yojson.Safe.t option =
  match extract_kind_from_result result with
  | None -> working_context
  | Some kind_tag -> (
      match extract_id_from_result result with
      | None -> working_context
      | Some id ->
          let metadata =
            match lookup_field result multimodal_metadata_key with
            | Some (`Assoc _ as m) -> m
            | _ -> `Assoc []
          in
          let payload_json = strip_reserved_keys result in
          Keeper_emitter.emit ~working_context ~id ~kind_tag
            ~payload_json ~metadata)

let emit_from_tool_results
    ~(working_context : Yojson.Safe.t option)
    (results : Yojson.Safe.t list) : Yojson.Safe.t option =
  List.fold_left
    (fun wc result -> emit_from_tool_result ~working_context:wc ~result)
    working_context results
