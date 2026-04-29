(* Wirein_helpers — see wirein_helpers.mli for design rationale. *)

let masc_multimodal_enabled () =
  match Sys.getenv_opt "MASC_MULTIMODAL" with
  | Some ("1" | "true" | "yes" | "on") -> true
  | _ -> false

let multimodal_key = "multimodal_artifacts"

let parse_raw_artifact (json : Yojson.Safe.t)
    : Multimodal_keeper_bridge.raw_artifact option =
  match json with
  | `Assoc kv ->
      let lookup k =
        try Some (List.assoc k kv) with Not_found -> None
      in
      let id =
        match lookup "id" with Some (`String s) -> Some s | _ -> None
      in
      let kind_hint =
        match lookup "kind_hint" with
        | Some (`String s) -> Some s
        | _ -> None
      in
      let payload_json =
        match lookup "payload_json" with
        | Some j -> j
        | None -> `Null
      in
      let metadata =
        match lookup "metadata" with
        | Some j -> j
        | None -> `Null
      in
      (match (id, kind_hint) with
       | Some id, Some kind_hint ->
           Some
             {
               Multimodal_keeper_bridge.id;
               kind_hint;
               payload_json;
               metadata;
             }
       | _ -> None)
  | _ -> None

let extract_raw_artifacts
    (working_context : Yojson.Safe.t option)
    : Multimodal_keeper_bridge.raw_artifact list * Yojson.Safe.t option =
  match working_context with
  | Some (`Assoc kv) ->
      let raws_json, kv_rest =
        List.partition (fun (k, _) -> k = multimodal_key) kv
      in
      let raws =
        match raws_json with
        | [ (_, `List entries) ] ->
            List.filter_map parse_raw_artifact entries
        | _ -> []
      in
      let next_wc =
        if raws_json = [] then working_context
        else Some (`Assoc kv_rest)
      in
      (raws, next_wc)
  | _ -> ([], working_context)

let upsert_workspace_meta
    (working_context : Yojson.Safe.t option)
    (workspace_meta : Yojson.Safe.t) : Yojson.Safe.t option =
  let updated_kv =
    match working_context with
    | None -> [ ("workspace_meta", workspace_meta) ]
    | Some (`Assoc kv) ->
        let kv_without =
          List.filter (fun (k, _) -> k <> "workspace_meta") kv
        in
        ("workspace_meta", workspace_meta) :: kv_without
    | Some _ -> [ ("workspace_meta", workspace_meta) ]
  in
  Some (`Assoc updated_kv)
