module Current = Keeper_memory_os_current
module Source = Keeper_memory_source_current
module Memory = Keeper_memory_os_types
module Select = Keeper_workspace_memory_selection
module Io = Keeper_workspace_memory_selection_io
let ( let* ) = Result.bind
let sha text = Digestif.SHA256.(digest_string text |> to_hex)
let issue ?id kind detail = `Assoc
  (["kind",`String kind;"detail",`String detail] @ match id with None -> [] | Some id -> ["id",`String id])
type identity = Ordinary of Memory.fact | File of Source.fact
type candidate = { choice:Select.candidate; detail:Yojson.Safe.t; identity:identity }
type collected =
  { ordinary : (Current.successor_recall,string) result
  ; source : (Source.projection,string) result
  ; candidates : candidate list
  ; unavailable : Yojson.Safe.t list }
let binding_json (binding : Current.admission_recall_binding) =
  `Assoc ["request_id",`String binding.candidate_id.request_id;
    "queue_generation",`String binding.candidate_id.queue_generation;
    "sequence",`Int binding.candidate_id.sequence;
    "input_sha256",`String binding.candidate_id.input_sha256;
    "historical_source",Memory.fact_to_json binding.source_fact;
    "original_target_memory_id",`String binding.target_memory_id]
let source_id (fact : Source.fact) = "source:" ^ sha (Yojson.Safe.to_string
  (`Assoc ["path",`String fact.source.path;"sha256",`String fact.source.sha256;"claim",`String fact.claim]))
let source_json (fact : Source.fact) = `Assoc ["claim",`String fact.claim;
  "source_path",`String fact.source.path;"source_sha256",`String fact.source.sha256]
let collect ~config ~meta ~keepers_dir =
  (* File verification may perform endpoint I/O. Read ordinary state after it,
     without holding either store's lock across the other read. *)
  let source=Source.revalidate ~scope:Source.All_sources ~config ~meta ~keepers_dir ~now:(Time_compat.now ()) () in
  let ordinary=Domain_pool_ref.submit_io_or_inline (fun () ->
    Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id:meta.Keeper_meta_contract.name) in
  let ordinary_rows,ordinary_errors=match ordinary with
    | Error detail -> [],[issue "current_store_unavailable" detail]
    | Ok view ->
      let receipt_fields,receipt_errors=match view.receipt_verification with
        | Ok () -> [],[]
        | Error detail ->
          ["receipt_verification",`Assoc ["status",`String "unavailable";"detail",`String detail;
            "guidance",`String "Admission and successor provenance could not be verified. Empty witness lists do not establish absence of related history."]],
          [issue "receipt_verification_unavailable" detail] in
      let facts=match view.snapshot with None -> [] | Some snapshot -> snapshot.Current.facts in
      List.map (fun fact ->
        let id=Memory.memory_id fact in
        let direct=List.filter (fun (binding : Current.admission_recall_binding) -> binding.target_memory_id=id) view.direct_bindings in
        let successors=List.filter (fun (candidate : Current.successor_recall_candidate) -> Memory.memory_id candidate.target=id) view.successor_candidates in
        {choice={Select.id;summary=fact.claim};identity=Ordinary fact;
         detail=`Assoc (["store",`String "current_memory_snapshot";"memory_id",`String id;
           "current_fact",Memory.fact_to_json fact;
           "direct_admission_witnesses",`List (List.map binding_json direct);
           "successor_witnesses",`List (List.map Keeper_memory_successor_selection.candidate_to_json successors);
           "provenance_guidance",`String "Historical observations and lineage are lookup provenance, not additional current claims."] @ receipt_fields)}) facts,
      receipt_errors @ List.filter_map (fun (row : Current.recall_unresolved) -> match row.reason with
        | Current.Retired_without_successor _ -> None
        | History_unavailable _ | Missing_transition _ | Invalid_transition _ | Unrecorded_lineage _ ->
          Some (issue "lineage_unresolved" (Current.recall_unresolved_reason_to_string row.reason))) view.unresolved in
  let source_rows,source_errors=match source with
    | Error detail -> [],[issue "source_store_unavailable" detail]
    | Ok projection ->
      let verified,unverified=List.partition (fun (fact : Source.fact) ->
        not (List.mem fact.source.path projection.unverified_paths)) projection.facts in
      List.map (fun fact -> {choice={Select.id=source_id fact;summary=fact.Source.claim};identity=File fact;
        detail=`Assoc ["store",`String "source_bound_current_memory";"current_fact",source_json fact;
          "source_verified",`Bool true]}) verified,
      List.map (fun (fact : Source.fact) -> issue ~id:(source_id fact) "source_unverified"
        ("Source could not be verified: " ^ fact.source.path)) unverified in
  {ordinary;source;candidates=ordinary_rows @ source_rows;unavailable=ordinary_errors @ source_errors}
let deferred_label = function
  | Select.Evaluation_failed detail -> "evaluation_failed",detail
  | Capacity_unresolved detail -> "capacity_unresolved",detail
  | Invalid_answer detail -> "invalid_answer",detail
  | Source_unavailable detail -> "source_unavailable",detail
  | Applicability_unresolved -> "applicability_unresolved","The supplied sources did not settle how this memory should be used."
let parse = function
  | `Assoc fields ->
    if List.sort_uniq String.compare (List.map fst fields) <> List.sort String.compare (List.map fst fields)
       || List.exists (fun (key,_) -> key<>"purpose" && key<>"limit") fields then Error "Unknown or duplicate argument."
    else let* purpose=match List.assoc_opt "purpose" fields with
      | Some (`String text) when String.trim text<>"" -> Ok text
      | _ -> Error "purpose must be a nonblank string." in
    let* limit=match List.assoc_opt "limit" fields with
      | None -> Ok None | Some (`Int value) when value>0 -> Ok (Some value)
      | _ -> Error "limit must be a positive integer when supplied." in Ok (purpose,limit)
  | _ -> Error "Expected an argument object."
let handle ?turn_ref ~clock ~config ~(meta : Keeper_meta_contract.keeper_meta) ~args () =
  match parse args with
  | Error detail -> Keeper_tool_execution.failure_data ~class_:Tool_result.Policy_rejection ~message:detail
      (`Assoc ["error",`String detail])
  | Ok (query,limit) ->
    match Typesafeai_config.workspace_memory_selection_destinations ~keeper_id:meta.name with
    | Error reason -> Keeper_tool_execution.success_data (`Assoc ["status",`String "unavailable";
        "reason",`String (Typesafeai_config.unavailable_reason_to_string reason);
        "selected",`List [];"incomplete",`Bool true;
        "guidance",`String "Selection was unavailable; no relevance or absence judgment was made."])
    | Ok destinations ->
      let keepers_dir=Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
      let before=collect ~config ~meta ~keepers_dir in
      let purpose=`Assoc ["current_input",`String query;
        "request_context",`String "Explicit selection from this Keeper's ordinary and source-bound current memory. The request does not establish facts about ambiguous or unknown events.";
        "keeper_instructions",`String meta.instructions;
        "turn_ref",(match turn_ref with None -> `Null | Some turn -> Ids.Turn_ref.to_yojson turn)] in
      let io=Io.create ~config ~keeper_id:meta.name ~destinations in
      let outcomes=Select.select_resolved_many ~evaluate:(Io.evaluate ?clock io) ~purpose
        (List.map (fun row -> row.choice,row.detail) before.candidates) in
      let after=collect ~config ~meta ~keepers_dir in
      let publication_policy=Typesafeai_config.workspace_memory_selection_destinations ~keeper_id:meta.name in
      let ordinary_unchanged=match before.ordinary,after.ordinary with Ok a,Ok b -> a=b | _ -> false in
      let fresh row=match row.identity with
        | Ordinary _ -> ordinary_unchanged
        | File fact -> (match after.source with Error _ -> false | Ok projection ->
            not (List.mem fact.source.path projection.unverified_paths) && List.mem fact projection.facts) in
      let selected=ref [] and deferred=ref [] and not_needed=ref [] in
      List.iter (fun outcome ->
        let choice=match outcome with Select.Selected {candidate;_} | Deferred {candidate;_} | Not_needed candidate -> candidate in
        let row=List.find (fun row -> row.choice.id=choice.id) before.candidates in
        if Result.is_error publication_policy then deferred:=issue ~id:choice.id "selection_policy_changed"
          "Selection permission was revoked while evaluating memory." :: !deferred
        else if not (fresh row) then deferred:=issue ~id:choice.id "evidence_changed"
          "Current identity, incarnation, provenance or verified source changed during selection." :: !deferred
        else match outcome with
          | Select.Selected {use;source_detail=_;_} ->
            let delivered_detail=match row.identity with
              | File fact -> `Assoc ["store",`String "source_bound_current_memory";"current_fact",source_json fact]
              | Ordinary fact ->
                let count key=match Yojson.Safe.Util.member key row.detail with `List rows -> List.length rows | _ -> 0 in
                `Assoc ["store",`String "current_memory_snapshot";"memory_id",`String choice.id;
                  "current_fact",Memory.fact_to_json fact;
                  "direct_admission_witness_count",`Int (count "direct_admission_witnesses");
                  "successor_witness_count",`Int (count "successor_witnesses")] in
            selected:=(row,`Assoc ["id",`String choice.id;
              "use",`String (match use with For_current_decision -> "current_decision" | For_comparison -> "comparison");
              "current",delivered_detail]) :: !selected
          | Not_needed _ -> not_needed:=choice.id :: !not_needed
          | Deferred {reason;_} -> let kind,detail=deferred_label reason in deferred:=issue ~id:choice.id kind detail :: !deferred) outcomes;
      let selected=List.rev !selected in
      let delivered=match limit with None -> selected | Some limit -> List.take limit selected in
      let assessed_ids=List.map (fun row -> row.choice.id) before.candidates in
      let newly_visible=List.filter (fun row -> not (List.mem row.choice.id assessed_ids)) after.candidates in
      let unavailable=before.unavailable @ after.unavailable @ List.map (fun row ->
        issue ~id:row.choice.id "unassessed_current_candidate" "A current candidate appeared after selection began.") newly_visible in
      let output=`Assoc ["status",`String "completed";"purpose",`String query;
        "selected",`List (List.map snd delivered);"deferred",`List (List.rev !deferred);
        "unavailable",`List unavailable;
        "assessed_count",`Int (List.length before.candidates);"selected_count",`Int (List.length delivered);
        "not_needed_count",`Int (List.length !not_needed);"truncated_count",`Int (List.length selected-List.length delivered);
        "incomplete",`Bool (!deferred<>[] || unavailable<>[]);
        "selection_id",`String (Io.selection_id io);
        "snapshot_revision",(match after.ordinary with Ok {snapshot=Some snapshot;_} -> `Int snapshot.revision | _ -> `Null);
        "guidance",`String "Current-decision and comparison are retrieval roles, not truth verification. Omitted or unavailable results do not establish absence. Comparison retains its original scope."] in
      match Io.retain_result io ~purpose (Ok output) with
      | Error detail -> Keeper_tool_execution.success_data (`Assoc ["status",`String "unavailable";
          "reason",`String "selection_result_persistence_failed";"detail",`String detail;
          "selected",`List [];"incomplete",`Bool true])
      | Ok () ->
        let events=List.filter_map (fun (row,_) -> match row.identity with File _ -> None | Ordinary _ ->
          Some {Keeper_memory_os_events.recorded_at=Time_compat.now ();memory_id=row.choice.id;
            trace_id=Keeper_id.Trace_id.to_string meta.runtime.trace_id;
            kind=Keeper_memory_os_events.Retrieved {query}}) delivered in
        Domain_pool_ref.submit_io_or_inline (fun () -> Keeper_memory_os_events.append_all
          ~keepers_dir ~keeper_id:meta.name events) |> List.iter (fun error ->
            Log.Keeper.warn "memory select retrieval event unavailable: %s" (Keeper_memory_os_events.append_error_to_string error));
        Keeper_tool_execution.success_data output

let answer_of_output text =
  let rec unique_objects = function
    | `Assoc fields ->
      List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (_,value) -> unique_objects value) fields
    | `List rows -> List.for_all unique_objects rows
    | _ -> true in
  match Yojson.Safe.from_string text with
  | `Assoc fields ->
    let get key=List.assoc_opt key fields in
    let unique=unique_objects (`Assoc fields) in
    let text_field key=match get key with Some (`String _) -> true | _ -> false in
    let rows_field key=match get key with Some (`List rows) ->
      List.for_all (function `Assoc _ -> true | _ -> false) rows | _ -> false in
    let count_field key=match get key with Some (`Int value) -> value>=0 | _ -> false in
    let receipt=match get "selection_id" with Some (`String value) -> String.trim value<>"" | _ -> false in
    let incomplete=match get "incomplete" with Some (`Bool _) -> true | _ -> false in
    let revision=match get "snapshot_revision" with Some `Null | Some (`Int _) -> true | _ -> false in
    if unique && get "status"=Some (`String "completed") && receipt && incomplete && revision
       && List.for_all text_field ["purpose";"guidance"]
       && List.for_all rows_field ["selected";"deferred";"unavailable"]
       && List.for_all count_field ["assessed_count";"selected_count";"not_needed_count";"truncated_count"]
    then Some (`Assoc (List.filter (fun (key,_) -> key<>"selection_id") fields)) else None
  | _ -> None
  | exception Yojson.Json_error _ -> None
