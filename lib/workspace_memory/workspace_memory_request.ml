module Ledger = Workspace_memory_ledger
module Index = Keeper_memory_search_index

type error =
  | Invalid_limit
  | Index_unavailable of string
  | Fact_exceeds_limit of Ledger.fact_ref

type batch =
  { input : Yojson.Safe.t
  ; rendered_prompt : string
  ; selected : Ledger.pending_fact list
  ; remaining : Ledger.pending_fact list
  ; index_stats : Index.batch_stats
  }

let error_to_string = function
  | Invalid_limit -> "workspace curator request limit must be positive"
  | Index_unavailable detail -> "workspace curator neighbor index: " ^ detail
  | Fact_exceeds_limit _ -> "one workspace fact and its neighbors exceed the admitted input limit"

let fact_ref_json = function
  | Ledger.Ordinary { keeper_id; claim_sha256 } ->
    `Assoc ["keeper_id", `String keeper_id; "store", `String "ordinary";
            "claim_sha256", `String claim_sha256]
  | Ledger.Source_bound { keeper_id; path; claim_sha256 } ->
    `Assoc ["keeper_id", `String keeper_id; "store", `String "source_bound";
            "path", `String path; "claim_sha256", `String claim_sha256]

let keeper_id = function
  | Ledger.Ordinary { keeper_id; _ } | Ledger.Source_bound { keeper_id; _ } -> keeper_id

let pending_json (pending : Ledger.pending_fact) =
  `Assoc ["fact", fact_ref_json pending.fact; "claim", `String pending.claim]

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

let prepare ~max_input_bytes ~neighbor_limit ~render ~ledger ~current ~pending =
  if max_input_bytes <= 0 || neighbor_limit < 0 then Error Invalid_limit
  else match pending with
  | [] -> Ok None
  | _ :: _ ->
    (* The index still holds every current fact, but ask it only about facts
       whose bare rows could fit in this request. Otherwise the first fill
       would issue thousands of needless BM25 queries. *)
    let rec candidates selected rows = function
      | [] -> Ok (List.rev selected, [])
      | (fact : Ledger.pending_fact) :: rest as remaining ->
        let proposed = row_json ~ledger fact [] :: rows in
        if String.length (render (input (List.rev proposed))) > max_input_bytes then
          (match selected with
           | [] -> Error (Fact_exceeds_limit fact.fact)
           | _ :: _ -> Ok (List.rev selected, remaining))
        else candidates (fact :: selected) proposed rest
    in
    let ( let* ) = Result.bind in
    let* candidates, tail = candidates [] [] pending in
    let texts = List.map (fun (fact : Ledger.pending_fact) ->
      keeper_id fact.fact, fact.claim) current in
    let queries = List.map (fun (fact : Ledger.pending_fact) ->
      keeper_id fact.fact, fact.claim) candidates in
    (match Index.rank_many_excluding_owners ~queries ~texts ~max_results:neighbor_limit with
     | Error error -> Error (Index_unavailable (Index.error_to_string error))
     | Ok (rankings, index_stats) ->
       let sources = Array.of_list current in
       let neighbors (pending : Ledger.pending_fact) ranked =
         let rec take count selected = function
           | [] -> List.rev selected
           | _ when count >= neighbor_limit -> List.rev selected
           | (ordinal, _) :: rest ->
             let candidate = sources.(ordinal) in
             if String.equal (keeper_id pending.fact) (keeper_id candidate.fact)
                || candidate.fact = pending.fact
             then take count selected rest
             else take (count + 1) (candidate :: selected) rest
         in
         take 0 [] ranked in
       let rec choose selected rows last_rendered = function
         | [] ->
           let payload = input (List.rev rows) in
           (match last_rendered with
            | Some rendered_prompt ->
              Ok (Some { input = payload; rendered_prompt;
                         selected = List.rev selected; remaining = tail; index_stats })
            | None -> Error Invalid_limit)
         | (fact, ranked) :: rest as remaining ->
           let rec fit neighbors =
             let proposed = row_json ~ledger fact neighbors :: rows in
             let payload = input (List.rev proposed) in
             let rendered = render payload in
             if String.length rendered <= max_input_bytes
             then Some (proposed, payload, rendered)
             else match List.rev neighbors with
               | [] -> None
               | _ :: prior -> fit (List.rev prior)
           in
           (match fit (neighbors fact ranked) with
            | Some (proposed, payload, rendered) ->
              (match rest with
               | [] -> Ok (Some { input = payload; rendered_prompt = rendered;
                                selected = List.rev (fact :: selected); remaining = tail;
                                index_stats })
               | _ :: _ -> choose (fact :: selected) proposed (Some rendered) rest)
            | None ->
              (match selected, last_rendered with
               | [], _ -> Error (Fact_exceeds_limit fact.fact)
               | _ :: _, Some rendered_prompt ->
                 let payload = input (List.rev rows) in
                 Ok (Some { input = payload; rendered_prompt;
                            selected = List.rev selected;
                            remaining = List.map fst remaining @ tail;
                            index_stats })
               | _ :: _, None -> Error Invalid_limit))
       in
       choose [] [] None (List.combine candidates rankings))
