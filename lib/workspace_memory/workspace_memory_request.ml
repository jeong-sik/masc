module Ledger = Workspace_memory_ledger
module Index = Keeper_memory_search_index

type error =
  | Invalid_limit
  | Render_failed of string
  | Index_unavailable of string
  | Invalid_batch of string

type batch =
  { input : Yojson.Safe.t
  ; rendered_prompt : string
  ; selected : Ledger.pending_fact list
  ; remaining : Ledger.pending_fact list
  ; index_stats : Index.batch_stats
  }

let error_to_string = function
  | Invalid_limit -> "workspace curator neighbor limit must be nonnegative"
  | Render_failed detail -> "workspace curator prompt render: " ^ detail
  | Index_unavailable detail -> "workspace curator neighbor index: " ^ detail
  | Invalid_batch detail -> "workspace curator inconsistent request: " ^ detail

let fact_ref_json = function
  | Ledger.Ordinary { keeper_id; claim_sha256 } ->
    `Assoc ["keeper_id", `String keeper_id; "store", `String "ordinary";
            "claim_sha256", `String claim_sha256]
  | Ledger.Source_bound { keeper_id; path; claim_sha256 } ->
    `Assoc ["keeper_id", `String keeper_id; "store", `String "source_bound";
            "path", `String path; "claim_sha256", `String claim_sha256]

let fact_id fact =
  "fact-" ^ Digestif.SHA256.(digest_string
    (Yojson.Safe.to_string (fact_ref_json fact)) |> to_hex)

let keeper_id = function
  | Ledger.Ordinary { keeper_id; _ } | Ledger.Source_bound { keeper_id; _ } -> keeper_id

let pending_json (pending : Ledger.pending_fact) =
  `Assoc ["id", `String (fact_id pending.fact);
          "fact", fact_ref_json pending.fact; "claim", `String pending.claim]

let referenced_entries ~ledger neighbors =
  let dispositions = Ledger.dispositions ledger in
  let claim_ids, conflict_ids =
    List.fold_left (fun (claims, conflicts) (pending : Ledger.pending_fact) ->
      match List.assoc_opt pending.fact dispositions with
      | Some (Ledger.Claim_member id) ->
        if List.mem id claims then claims, conflicts else id :: claims, conflicts
      | Some (Ledger.Conflict_member id) ->
        if List.mem id conflicts then claims, conflicts else claims, id :: conflicts
      | Some (Ledger.Excluded _) | None -> claims, conflicts)
      ([], []) neighbors in
  let entries ids source id_field text_field =
    source |> List.filter_map (fun (id, value) ->
      if List.mem id ids
      then Some (`Assoc [id_field, `String id; text_field, `String value])
      else None) in
  entries claim_ids (Ledger.claims ledger) "claim_id" "claim",
  entries conflict_ids (Ledger.conflicts ledger) "conflict_id" "description"

let row_json ~ledger (pending : Ledger.pending_fact) neighbors =
  let claims, conflicts = referenced_entries ~ledger neighbors in
  `Assoc ["new_fact", pending_json pending;
          "neighbors", `List (List.map pending_json neighbors);
          "related_claims", `List claims;
          "related_conflicts", `List conflicts]

let input rows = `Assoc ["new_facts", `List rows]

let ( let* ) = Result.bind

let prepare ~neighbor_limit ~render ~ledger ~current ~pending =
  if neighbor_limit < 0 then Error Invalid_limit
  else match pending with
  | [] -> Ok None
  | _ :: _ ->
    let texts = List.map (fun (fact : Ledger.pending_fact) ->
      keeper_id fact.fact, fact.claim) current in
    let queries = List.map (fun (fact : Ledger.pending_fact) ->
      keeper_id fact.fact, fact.claim) pending in
    let* rankings, index_stats =
      Index.rank_many_excluding_owners ~queries ~texts ~max_results:neighbor_limit
      |> Result.map_error (fun error -> Index_unavailable (Index.error_to_string error)) in
    let sources = Array.of_list current in
    let rows = List.map2 (fun fact ranked ->
      let neighbors = List.map (fun (ordinal, _) -> sources.(ordinal)) ranked in
      row_json ~ledger fact neighbors) pending rankings in
    let input = input rows in
    let* rendered_prompt = render input |> Result.map_error (fun detail -> Render_failed detail) in
    Ok (Some { input; rendered_prompt; selected = pending; remaining = []; index_stats })

let selected_rows batch =
  match batch.input with
  | `Assoc ["new_facts", `List rows] ->
    let rec aligned facts rows = match facts, rows with
      | [], [] -> true
      | (fact : Ledger.pending_fact) :: facts, `Assoc fields :: rows ->
        (match List.filter (fun (name, _) -> String.equal name "new_fact") fields with
         | ["new_fact", `Assoc new_fact] ->
           List.filter (fun (name, _) -> String.equal name "id") new_fact
           = ["id", `String (fact_id fact.fact)]
           && aligned facts rows
         | _ -> false)
      | _ -> false in
    if aligned batch.selected rows then Ok rows
    else Error (Invalid_batch "rows do not match the selected facts in order")
  | _ -> Error (Invalid_batch "expected the new_facts array")

let narrow ~render batch =
  let* rows = selected_rows batch in
  match batch.selected with
  | [] | [_] -> Ok None
  | _ :: _ :: _ ->
    (* Finite whole-row bisection follows an actual provider refusal. This is
       not a byte/token estimate and never trims a row's source context. *)
    let prefix_length = List.length batch.selected / 2 in
    let selected = List.take prefix_length batch.selected in
    let remaining = List.drop prefix_length batch.selected @ batch.remaining in
    let input = input (List.take prefix_length rows) in
    let* rendered_prompt = render input |> Result.map_error (fun detail -> Render_failed detail) in
    Ok (Some { input; rendered_prompt; selected; remaining; index_stats = batch.index_stats })
