module Ledger = Workspace_memory_ledger
module Context = Workspace_memory_context

let ( let* ) = Result.bind

let current_facts ~base_path ledger =
  match Context.collect ~base_path with
  | Error detail -> Error detail
  | Ok context ->
    Ok (context, (Ledger.reconcile ledger (Context.keepers context)).current_facts)

let store_unavailable context = function
  | Ledger.Ordinary { keeper_id; _ } ->
    (match List.find_opt (fun (row : Context.keeper) -> row.keeper_id = keeper_id)
       (Context.keepers context) with
     | Some { ordinary = Context.Unavailable _; _ } -> true
     | _ -> false)
  | Ledger.Source_bound { keeper_id; _ } ->
    (match List.find_opt (fun (row : Context.keeper) -> row.keeper_id = keeper_id)
       (Context.keepers context) with
     | Some { source_bound = Context.Unavailable _; _ } -> true
     | _ -> false)

let read ~base_path =
  match Ledger.observe ~base_path with
  | Ledger.Missing -> Ok (`Assoc ["status", `String "missing"])
  | Ledger.Unavailable detail -> Error detail
  | Ledger.Available descriptor ->
    let* ledger = Ledger.load ~base_path in
    let loaded_sha256 = Digestif.SHA256.(digest_string
      (Yojson.Safe.to_string (Ledger.to_json ledger)) |> to_hex) in
    if loaded_sha256 <> descriptor.ledger_sha256
    then Error "workspace ledger changed during the read"
    else
    let current = current_facts ~base_path ledger in
    let current_by_ref = Hashtbl.create (List.length (Ledger.dispositions ledger)) in
    (match current with
     | Error _ -> ()
     | Ok (_, rows) -> List.iter (fun (row : Ledger.pending_fact) ->
         Hashtbl.replace current_by_ref row.fact row.claim) rows);
    let facts =
      Ledger.to_json ledger |> Yojson.Safe.Util.member "facts" |> Yojson.Safe.Util.to_list in
    let enriched = List.map2 (fun (fact, _) json ->
      let observed = Hashtbl.find_opt current_by_ref fact in
      let source_state = match observed, current with
        | Some _, _ -> "present"
        | None, Error _ -> "unavailable"
        | None, Ok (context, _) when store_unavailable context fact -> "unavailable"
        | None, Ok _ -> "absent" in
      match json with
      | `Assoc fields -> `Assoc (fields @
          ["current_claim", (match observed with None -> `Null | Some claim -> `String claim);
           "source_state", `String source_state])
      | _ -> json)
      (Ledger.dispositions ledger) facts in
    Ok (`Assoc
      [ "status", `String "available"
      ; "semantic_verification", `String "not_performed"
      ; "ledger_sha256", `String descriptor.ledger_sha256
      ; "source_resolution", (match current with
          | Ok _ -> `Assoc ["status", `String "available"]
          | Error detail -> `Assoc ["status", `String "unavailable"; "detail", `String detail])
      ; "ledger", (match Ledger.to_json ledger with
          | `Assoc fields -> `Assoc (List.map (fun (key, value) ->
              if key = "facts" then key, `List enriched else key, value) fields)
          | json -> json) ])

let member_refs facts ~kind ~id =
  facts |> List.filter_map (function
    | `Assoc fields as row ->
      (match List.assoc_opt "disposition" fields with
       | Some (`Assoc disposition) when List.assoc_opt "kind" disposition = Some (`String kind)
         && List.assoc_opt (kind ^ "_id") disposition = Some (`String id) ->
         Some (`Assoc (List.filter (fun (key, _) -> key <> "disposition") fields))
       | _ -> None)
    | _ -> None)

let summary ~base_path =
  match Ledger.observe ~base_path with
  | Ledger.Missing -> Ok (`Assoc ["status", `String "missing"])
  | Ledger.Unavailable detail -> Error detail
  | Ledger.Available descriptor ->
    let* ledger = Ledger.load ~base_path in
    let facts = Ledger.to_json ledger |> Yojson.Safe.Util.member "facts"
      |> Yojson.Safe.Util.to_list in
    let rows kind entries = List.map (fun (id, text) ->
      `Assoc ["id", `String id; "text", `String text;
              "members", `List (member_refs facts ~kind ~id)]) entries in
    Ok (`Assoc ["status", `String "available";
                "semantic_verification", `String "not_performed";
                "ledger_sha256", `String descriptor.ledger_sha256;
                "claims", `List (rows "claim" (Ledger.claims ledger));
                "conflicts", `List (rows "conflict" (Ledger.conflicts ledger));
                "classified_count", `Int descriptor.classified_count])

let detail ~base_path ~id =
  let* full = read ~base_path in
  match full with
  | `Assoc fields when List.assoc_opt "status" fields = Some (`String "missing") ->
    Ok (`Assoc ["found", `Bool false; "status", `String "missing"; "id", `String id])
  | `Assoc fields ->
    let ledger = List.assoc "ledger" fields in
    let entries kind field text_field =
      let rows = Yojson.Safe.Util.member field ledger |> Yojson.Safe.Util.to_list in
      List.find_map (function
        | `Assoc values when List.assoc_opt (kind ^ "_id") values = Some (`String id) ->
          Option.map (fun text -> kind, text) (match List.assoc_opt text_field values with
            | Some (`String text) -> Some text | _ -> None)
        | _ -> None) rows in
    (match entries "claim" "claims" "claim" with
     | Some row -> Some row
     | None -> entries "conflict" "conflicts" "description")
    |> (function
      | None -> Ok (`Assoc ["found", `Bool false; "id", `String id])
      | Some (kind, text) ->
        let facts = Yojson.Safe.Util.member "facts" ledger |> Yojson.Safe.Util.to_list in
        Ok (`Assoc ["found", `Bool true; "id", `String id;
                    "kind", `String kind; "text", `String text;
                    "semantic_verification", `String "not_performed";
                    "source_resolution", List.assoc "source_resolution" fields;
                    "members", `List (member_refs facts ~kind ~id)]))
  | _ -> Error "workspace ledger view has an invalid shape"
