(* Wirein_helpers — see wirein_helpers.mli for design rationale. *)

let multimodal_key = "multimodal_artifacts"

let parse_raw_artifact ~index (json : Yojson.Safe.t)
    : (Multimodal_keeper_bridge.raw_artifact, string) result =
  let context = Printf.sprintf "multimodal_artifacts[%d]" index in
  match json with
  | `Assoc fields ->
    let expected = [ "id"; "kind_hint"; "payload_json"; "metadata" ] in
    let actual = List.map fst fields in
    if List.length actual <> List.length expected
       || not (List.for_all (fun key -> List.mem key actual) expected)
    then
      Error
        (Printf.sprintf
           "%s fields must be exactly [%s]"
           context
           (String.concat "," expected))
    else
      (match List.assoc "id" fields, List.assoc "kind_hint" fields with
       | `String id, `String kind_hint when String.trim id <> "" ->
         Ok
           { Multimodal_keeper_bridge.id
           ; kind_hint
           ; payload_json = List.assoc "payload_json" fields
           ; metadata = List.assoc "metadata" fields
           }
       | `String _, `String _ -> Error (context ^ ".id must not be empty")
       | _ -> Error (context ^ ".id and .kind_hint must be strings"))
  | _ -> Error (context ^ " must be an object")

let extract_raw_artifacts
    (working_context : Yojson.Safe.t option)
    : (Multimodal_keeper_bridge.raw_artifact list * Yojson.Safe.t option, string) result =
  match working_context with
  | Some (`Assoc kv) ->
      let artifact_fields, kv_rest =
        List.partition (fun (k, _) -> k = multimodal_key) kv
      in
      (match artifact_fields with
       | [] -> Ok ([], working_context)
       | [ (_, `List entries) ] ->
         let rec parse index acc = function
           | [] -> Ok (List.rev acc, Some (`Assoc kv_rest))
           | entry :: rest ->
             (match parse_raw_artifact ~index entry with
              | Error _ as error -> error
              | Ok artifact -> parse (index + 1) (artifact :: acc) rest)
         in
         parse 0 [] entries
       | [ _ ] -> Error "working_context.multimodal_artifacts must be a list"
       | _ -> Error "working_context has duplicate multimodal_artifacts fields")
  | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
    Ok ([], working_context)

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
