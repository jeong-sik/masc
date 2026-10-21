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

let fact_id fact =
  "fact-" ^ Digestif.SHA256.(digest_string
    (Yojson.Safe.to_string (Ledger.fact_ref_to_json fact)) |> to_hex)

let keeper_id = function
  | Ledger.Ordinary { keeper_id; _ } | Ledger.Source_bound { keeper_id; _ } -> keeper_id

let pending_json (pending : Ledger.pending_fact) =
  `Assoc ["id", `String (fact_id pending.fact);
          "fact", Ledger.fact_ref_to_json pending.fact; "claim", `String pending.claim]

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

let batch_schema = "workspace.memory.classification-batch.v1"
let batch_to_json (batch : batch) =
  let stats = batch.index_stats in
  `Assoc ["schema", `String batch_schema; "input", batch.input;
    "rendered_prompt", `String batch.rendered_prompt;
    "selected", `List (List.map pending_json batch.selected);
    "remaining", `List (List.map pending_json batch.remaining);
    "index_stats", `Assoc ["index_builds", `Int stats.index_builds;
      "indexed_rows", `Int stats.indexed_rows; "queries_executed", `Int stats.queries_executed]]

let snapshot_fields names = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
  | _ -> Error "batch snapshot has unknown, missing or repeated fields"
let snapshot_text = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error "batch snapshot expects nonblank text"
let snapshot_array decode = function
  | `List rows ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | row :: rest -> let* value = decode row in loop (value :: acc) rest in
    loop [] rows
  | _ -> Error "batch snapshot expects an array"
let pending_of_json json =
  let* fields = snapshot_fields ["id"; "fact"; "claim"] json in
  let* fact = Ledger.fact_ref_of_json (List.assoc "fact" fields) in
  let* claim = snapshot_text (List.assoc "claim" fields) in
  let* id = snapshot_text (List.assoc "id" fields) in
  let claim_sha256 = match fact with
    | Ledger.Ordinary {claim_sha256;_} | Ledger.Source_bound {claim_sha256;_} -> claim_sha256 in
  if not (String.equal id (fact_id fact)) then Error "snapshot fact id does not match its full source identity"
  else if not (String.equal claim_sha256 Digestif.SHA256.(digest_string claim |> to_hex))
  then Error "snapshot claim does not match its source hash"
  else Ok {Ledger.fact;claim}
let unique_facts facts =
  let rec loop seen = function
    | [] -> Ok ()
    | (fact : Ledger.pending_fact) :: rest ->
      let id = fact_id fact.fact in
      if Set_util.StringSet.mem id seen then Error "snapshot repeats a fact identity"
      else loop (Set_util.StringSet.add id seen) rest in
  loop Set_util.StringSet.empty facts

let batch_of_json ~ledger json =
  let decode () =
    let* fields = snapshot_fields ["schema"; "input"; "rendered_prompt"; "selected"; "remaining"; "index_stats"] json in
    let* schema = snapshot_text (List.assoc "schema" fields) in
    let* () = if String.equal schema batch_schema then Ok () else Error "unknown classification batch schema" in
    let* selected = snapshot_array pending_of_json (List.assoc "selected" fields) in
    let* remaining = snapshot_array pending_of_json (List.assoc "remaining" fields) in
    let* () = if selected = [] then Error "classification batch has no selected facts" else unique_facts (selected @ remaining) in
    let module Facts = Set.Make (struct type t = Ledger.fact_ref let compare = Stdlib.compare end) in
    let disposed = Ledger.dispositions ledger |> List.map fst |> Facts.of_list in
    let* () = if List.exists (fun (fact : Ledger.pending_fact) -> Facts.mem fact.fact disposed)
        (selected @ remaining)
      then Error "snapshot pending fact already has a captured ledger disposition" else Ok () in
    let* rendered_prompt = snapshot_text (List.assoc "rendered_prompt" fields) in
    let* stats = snapshot_fields ["index_builds"; "indexed_rows"; "queries_executed"] (List.assoc "index_stats" fields) in
    let count key = match List.assoc key stats with
      | `Int count when count >= 0 -> Ok count
      | _ -> Error "snapshot index statistics must be nonnegative integers" in
    let* index_builds = count "index_builds" in
    let* indexed_rows = count "indexed_rows" in
    let* queries_executed = count "queries_executed" in
    let input = List.assoc "input" fields in
    let* input_fields = snapshot_fields ["new_facts"] input in
    let* rows = snapshot_array (fun row -> Ok row) (List.assoc "new_facts" input_fields) in
    let rec validate facts rows = match facts, rows with
      | [], [] -> Ok ()
      | (fact : Ledger.pending_fact) :: facts, row :: rows ->
        let* fields = snapshot_fields ["new_fact"; "neighbors"; "related_claims"; "related_conflicts"] row in
        let* neighbors = snapshot_array pending_of_json (List.assoc "neighbors" fields) in
        let* () = unique_facts neighbors in
        let* () = if List.exists (fun (neighbor : Ledger.pending_fact) ->
            String.equal (keeper_id neighbor.fact) (keeper_id fact.Ledger.fact)) neighbors
          then Error "snapshot neighbor belongs to the selected fact's Keeper" else Ok () in
        let* () = if Yojson.Safe.equal row (row_json ~ledger fact neighbors) then Ok ()
          else Error "snapshot row differs from its selected fact or captured ledger context" in
        validate facts rows
      | [], _ :: _ | _ :: _, [] -> Error "snapshot rows do not match selected facts" in
    let* () = validate selected rows in
    Ok {input;rendered_prompt;selected;remaining;index_stats={Index.index_builds;indexed_rows;queries_executed}} in
  decode () |> Result.map_error (fun detail -> Invalid_batch detail)

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
