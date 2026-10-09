module Ledger = Workspace_memory_ledger
module Context = Workspace_memory_context
module String_map = Map.Make (String)

let ( let* ) = Result.bind

(* Both the full view and the summary must bind their payload to the observed
   descriptor. An atomic writer may replace the file between these reads. *)
let load_observed ~load ~base_path ~ledger_sha256 =
  let* ledger = load ~base_path in
  let loaded_sha256 = Digestif.SHA256.(digest_string
    (Yojson.Safe.to_string (Ledger.to_json ledger)) |> to_hex) in
  if loaded_sha256 <> ledger_sha256
  then Error "workspace ledger changed during the read"
  else Ok ledger

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
    let* ledger = load_observed ~load:Ledger.load ~base_path
        ~ledger_sha256:descriptor.ledger_sha256 in
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
    | `Assoc fields ->
      (match List.assoc_opt "disposition" fields with
       | Some (`Assoc disposition) when List.assoc_opt "kind" disposition = Some (`String kind)
         && List.assoc_opt (kind ^ "_id") disposition = Some (`String id) ->
         Some (`Assoc (List.filter (fun (key, _) -> key <> "disposition") fields))
       | _ -> None)
    | _ -> None)

let grouped_member_refs facts =
  List.fold_left (fun (claims, conflicts) -> function
    | `Assoc fields ->
      let reference = `Assoc (List.filter (fun (key, _) -> key <> "disposition") fields) in
      (match List.assoc_opt "disposition" fields with
       | Some (`Assoc disposition) ->
         (match List.assoc_opt "kind" disposition with
          | Some (`String "claim") ->
            (match List.assoc_opt "claim_id" disposition with
             | Some (`String id) ->
               let previous = match String_map.find_opt id claims with
                 | Some members -> members | None -> [] in
               String_map.add id (reference :: previous) claims, conflicts
             | _ -> claims, conflicts)
          | Some (`String "conflict") ->
            (match List.assoc_opt "conflict_id" disposition with
             | Some (`String id) ->
               let previous = match String_map.find_opt id conflicts with
                 | Some members -> members | None -> [] in
               claims, String_map.add id (reference :: previous) conflicts
             | _ -> claims, conflicts)
          | _ -> claims, conflicts)
       | _ -> claims, conflicts)
    | _ -> claims, conflicts)
    (String_map.empty, String_map.empty) facts

let summary_with_load ~load ~base_path =
  match Ledger.observe ~base_path with
  | Ledger.Missing -> Ok (`Assoc ["status", `String "missing"])
  | Ledger.Unavailable detail -> Error detail
  | Ledger.Available descriptor ->
    let* ledger = load_observed ~load ~base_path
        ~ledger_sha256:descriptor.ledger_sha256 in
    let facts = Ledger.to_json ledger |> Yojson.Safe.Util.member "facts"
      |> Yojson.Safe.Util.to_list in
    let claim_members, conflict_members = grouped_member_refs facts in
    let rows members entries = List.map (fun (id, text) ->
      `Assoc ["id", `String id; "text", `String text;
              "members", `List (List.rev (String_map.find id members))]) entries in
    Ok (`Assoc ["status", `String "available";
                "semantic_verification", `String "not_performed";
                "ledger_sha256", `String descriptor.ledger_sha256;
                "claims", `List (rows claim_members (Ledger.claims ledger));
                "conflicts", `List (rows conflict_members (Ledger.conflicts ledger));
                "classified_count", `Int descriptor.classified_count])

let summary ~base_path = summary_with_load ~load:Ledger.load ~base_path

let briefing_fields = function
  | Error _ -> ["status", `String "unavailable"]
  | Ok Workspace_memory_briefing.Missing -> ["status", `String "pending"]
  | Ok (Workspace_memory_briefing.Current summary) ->
    ["status", `String "current"; "text", `String summary.text]
  | Ok (Workspace_memory_briefing.Stale summary) ->
    ["status", `String "stale"; "text", `String summary.text]

let observation ~include_briefing ~base_path =
  match Ledger.observe ~base_path with
  | Ledger.Missing -> Ok (`Assoc ["status", `String "missing"])
  | Ledger.Unavailable detail -> Error detail
  | Ledger.Available descriptor ->
    let briefing = briefing_fields descriptor.briefing in
    let briefing = if include_briefing then briefing
      else List.filter (fun (key, _) -> key <> "text") briefing in
    Ok (`Assoc
      ["status", `String "available";
       "semantic_verification", `String "not_performed";
       "ledger_sha256", `String descriptor.ledger_sha256;
       "claim_count", `Int descriptor.claim_count;
       "conflict_count", `Int descriptor.conflict_count;
       "classified_count", `Int descriptor.classified_count;
       "briefing", `Assoc briefing])

let inventory ~base_path = observation ~include_briefing:false ~base_path
let briefing ~base_path = observation ~include_briefing:true ~base_path

let ranking_failure_logged = Atomic.make false

let search_with_rank ~rank ~base_path ~query ~limit =
  if String.trim query = "" then Error "workspace memory query must be nonblank"
  else if limit <= 0 then Error "workspace memory result limit must be positive"
  else
    let* snapshot = summary ~base_path in
    let open Yojson.Safe.Util in
    let rows field kind = match snapshot |> member field with
      | `List rows -> List.map (fun row -> kind, row) rows
      | _ -> [] in
    let candidates = rows "claims" "claim" @ rows "conflicts" "conflict" in
    let texts = List.map (fun (_, row) -> row |> member "text" |> to_string) candidates in
    let ranked = match rank ~query texts with
      | Ok ranked -> ranked
      | Error error ->
        if Atomic.compare_and_set ranking_failure_logged false true then
          Log.Keeper.warn
            "workspace memory search answers in store order; the ranking index failed \
             (logged once per process): %s"
            (Keeper_memory_search_index.error_to_string error);
        [] in
    (* As in personal memory search, literal matches cover short Korean words
       and short ASCII terms that FTS5's trigram tokenizer cannot index. *)
    let literal = List.mapi (fun ordinal text -> ordinal, text) texts
      |> List.filter_map (fun (ordinal, text) ->
           if String_util.contains_query_term_ci text query then Some ordinal else None) in
    let fragments = List.map fst ranked in
    let remaining = List.mapi (fun ordinal text -> ordinal, text) texts
      |> List.filter_map (fun (ordinal, text) ->
           if String_util.contains_all_query_terms_ci text query then Some ordinal else None) in
    let selected = List.fold_left (fun ordered ordinal ->
      if List.mem ordinal ordered then ordered else ordinal :: ordered)
      [] (literal @ fragments @ remaining) |> List.rev in
    let candidates = Array.of_list candidates in
    let matches = List.take limit selected |> List.map (fun ordinal ->
      let kind, row = candidates.(ordinal) in
      `Assoc ["kind", `String kind; "id", member "id" row; "text", member "text" row]) in
    Ok (`Assoc ["status", member "status" snapshot;
      "semantic_verification", `String "not_performed";
      "ledger_sha256", member "ledger_sha256" snapshot;
      "query", `String query; "total_matches", `Int (List.length selected);
      "matches", `List matches])

let search = search_with_rank ~rank:Keeper_memory_search_index.rank

module For_testing = struct
  let search_with_rank = search_with_rank
  let summary_with_load = summary_with_load
end

type resolved_snapshot = Yojson.Safe.t

let resolve_snapshot = read

let detail_in_snapshot full ~id =
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
                    "ledger_sha256", List.assoc "ledger_sha256" fields;
                    "kind", `String kind; "text", `String text;
                    "semantic_verification", `String "not_performed";
                    "source_resolution", List.assoc "source_resolution" fields;
                    "members", `List (member_refs facts ~kind ~id)]))
  | _ -> Error "workspace ledger view has an invalid shape"

let detail ~base_path ~id =
  let* snapshot = resolve_snapshot ~base_path in
  detail_in_snapshot snapshot ~id
