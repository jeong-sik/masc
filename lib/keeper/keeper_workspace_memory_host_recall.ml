module Selection = Keeper_workspace_memory_selection
module View = Workspace_memory_ledger_view
module IO = Keeper_workspace_memory_selection_io
let ( let* ) = Result.bind

let decode_summary ~is_excluded json =
  let open Yojson.Safe.Util in
  try
    match json |> member "status" |> to_string with
    | "missing" -> Ok None
    | "available" ->
      let ledger_sha256 = json |> member "ledger_sha256" |> to_string in
      let rows field = json |> member field |> to_list in
      let permitted,withheld = List.partition_map (fun row ->
        let id = row |> member "id" |> to_string in
        let owners = row |> member "members" |> to_list
          |> List.map (fun member -> member |> Yojson.Safe.Util.member "keeper_id" |> to_string) in
        if owners=[] || List.exists is_excluded owners then Either.Right id
        else Either.Left {Selection.id=id;summary=row |> member "text" |> to_string})
        (rows "claims" @ rows "conflicts") in
      Ok (Some (ledger_sha256,permitted,withheld))
    | _ -> Error "shared memory inventory is unavailable"
  with Yojson.Safe.Util.Type_error _ -> Error "shared memory inventory has an invalid shape"

let bound_detail ~detail ~ledger_sha256 ~id =
  let* value = detail ~id in
  let open Yojson.Safe.Util in
  if member "found" value <> `Bool true then Error "selected memory is no longer available"
  else if member "ledger_sha256" value <> `String ledger_sha256
  then Error "shared ledger changed during selection"
  else Ok value

let deferred_reason = function
  | Selection.Evaluation_failed detail -> "evaluation_failed",detail
  | Capacity_unresolved detail -> "capacity_unresolved",detail
  | Invalid_answer detail -> "invalid_answer",detail
  | Source_unavailable detail -> "source_unavailable",detail
  | Applicability_unresolved -> "applicability_unresolved","source scope remains unresolved"

let collect_with ~is_excluded ~summary ~detail_snapshot ~evaluate ~purpose =
  let* initial = summary () in
  let* snapshot = decode_summary ~is_excluded initial in
  match snapshot with
  | None -> Ok (`Assoc ["status",`String "missing"])
  | Some (ledger_sha256,candidates,withheld) ->
    let resolve = bound_detail ~detail:(detail_snapshot ()) ~ledger_sha256 in
    let decisions = Selection.select_many ~evaluate ~resolve ~purpose candidates in
    (* Revalidate after model execution, including sources that can change
       independently of the Curator ledger. No stale selection is published. *)
    let* final = summary () in
    let* final_snapshot = decode_summary ~is_excluded final in
    let* () = match final_snapshot with
      | Some (current,_,final_withheld) when String.equal current ledger_sha256 && final_withheld=withheld -> Ok ()
      | Some _ | None -> Error "shared ledger changed before retrieval publication" in
    let resolve = bound_detail ~detail:(detail_snapshot ()) ~ledger_sha256 in
    let* selected = List.fold_left (fun result decision ->
      let* rows = result in
      match decision with
      | Selection.Selected {candidate;use;source_detail} ->
        let* current_detail = resolve ~id:candidate.id in
        if current_detail <> source_detail then Error "shared memory sources changed before retrieval publication"
        else Ok (`Assoc
          ["id",`String candidate.id;
           "use",`String (match use with For_current_decision -> "current_decision" | For_comparison -> "comparison");
           "shared_interpretation",`String candidate.summary;
           "sources",source_detail] :: rows)
      | Not_needed _ | Deferred _ -> Ok rows) (Ok []) decisions in
    let deferred = List.filter_map (function
      | Selection.Deferred {candidate;reason} ->
        let kind,detail = deferred_reason reason in
        Some (`Assoc ["id",`String candidate.id;"kind",`String kind;"detail",`String detail])
      | Selected _ | Not_needed _ -> None) decisions in
    Ok (`Assoc
      ["status",`String (if deferred=[] && withheld=[] then "selected" else "partially_unavailable");
       "ledger_sha256",`String ledger_sha256;
       "semantic_verification",`String "not_performed";
       "selected",`List (List.rev selected);
       "unresolved",`List deferred;
       "source_policy_withheld_count",`Int (List.length withheld);
       "not_needed_count",`Int (List.fold_left (fun count -> function
         | Selection.Not_needed _ -> count+1 | Selected _ | Deferred _ -> count) 0 decisions)])

let collect ?(is_excluded = fun _ -> false) ~summary ~detail ~evaluate ~purpose () =
  collect_with ~is_excluded ~summary
    ~detail_snapshot:(fun () -> detail) ~evaluate ~purpose

let render_payload payload =
  match Prompt_registry.render_prompt_template
      Prompt_names.keeper_context_workspace_memory_host_selected
      ["payload",Yojson.Safe.to_string payload] with
  | Ok text -> "\n\n" ^ text
  | Error _ -> "\n\nShared memory host retrieval could not be rendered; availability is unknown."

type prepared =
  { mutable payload : Yojson.Safe.t
  ; mutable text : string
  ; validate : Yojson.Safe.t -> (unit,string) result
  ; retain : reason:string -> payload:Yojson.Safe.t -> (unit,string) result
  }

let make_prepared ~payload ~validate ~retain =
  {payload;text=render_payload payload;validate;retain}

let unavailable_payload payload reason = `Assoc
  ["status",`String "unavailable";"reason",`String reason;
   "selection_id",Yojson.Safe.Util.member "selection_id" payload]

let render_prepared prepared =
  match prepared.validate prepared.payload with
  | Ok () -> prepared.text
  | Error reason ->
    let payload = unavailable_payload prepared.payload reason in
    let payload = match prepared.retain ~reason:"source_revalidation_failed" ~payload with
      | Ok () -> payload
      | Error _ -> unavailable_payload payload "source revalidation and projection receipt unavailable" in
    prepared.payload <- payload;
    prepared.text <- render_payload payload;
    prepared.text

let defer_for_capacity prepared ~refusal =
  let open Keeper_memory_delivery_reprojection in
  match prepared.payload with
  | `Assoc fields ->
    (match List.assoc_opt "selected" fields with
     | Some (`List (_ :: _ as rows)) ->
       let previous_deferred = match List.assoc_opt "capacity_deferred_count" fields with
         | Some (`Int n) -> n | _ -> 0 in
       let rec smaller keep =
         let kept = List.take keep rows in
         let payload = `Assoc
           (List.filter (fun (key,_) -> not (List.mem key
             ["selected";"status";"capacity_deferred_count"])) fields @
            ["status",`String "capacity_deferred";
             "selected",`List kept;
             "capacity_deferred_count",`Int (previous_deferred + List.length rows - keep)]) in
         let text = render_payload payload in
         if String.length text < String.length prepared.text then (
           let* () = prepared.retain
             ~reason:(Agent_core.Error.to_string refusal) ~payload in
           prepared.payload <- payload;
           prepared.text <- text;
           Ok Reprojected)
         else if keep=0 then Ok Unchanged else smaller (keep / 2) in
       smaller (List.length rows / 2)
     | Some _ | None -> Ok Unchanged)
  | _ -> Ok Unchanged

let prepare_available ~config ~keeper_id ~purpose =
  let result,adapter =
    match Typesafeai_config.workspace_memory_selection_destinations ~keeper_id with
      | Error reason -> Error (Typesafeai_config.unavailable_reason_to_string reason),None
      | Ok destinations ->
        let adapter = IO.create ~config ~keeper_id ~destinations in
        let base_path = config.Workspace.base_path in
        let summary () = Domain_pool_ref.submit_io_or_inline (fun () -> View.summary ~base_path) in
        let detail_snapshot () =
          let snapshot = Eio.Lazy.from_fun ~cancel:`Restart (fun () ->
            Domain_pool_ref.submit_io_or_inline (fun () -> View.resolve_snapshot ~base_path)) in
          fun ~id ->
            let* snapshot = Eio.Lazy.force snapshot in
            View.detail_in_snapshot snapshot ~id in
        let result = collect_with
          ~is_excluded:(fun keeper_id -> Typesafeai_config.is_excluded ~keeper_id) ~summary ~detail_snapshot
          ~evaluate:(IO.evaluate adapter) ~purpose in
        let result = match IO.retain_result adapter ~purpose result with
          | Ok () -> result
          | Error detail -> Error ("selection result persistence failed: " ^ detail) in
        result, Some adapter in
  let identity = match adapter with None -> `Null | Some adapter -> `String (IO.selection_id adapter) in
  let payload = match result with
    | Ok (`Assoc fields) ->
      let unresolved = match List.assoc_opt "unresolved" fields with
        | Some (`List rows) -> rows | _ -> [] in
      let failures = List.fold_left (fun grouped row ->
        let kind = Yojson.Safe.Util.member "kind" row in
        let previous = match List.assoc_opt kind grouped with None -> 0 | Some n -> n in
        (kind,previous+1) :: List.remove_assoc kind grouped) [] unresolved in
      `Assoc (List.filter (fun (name,_) -> name<>"unresolved") fields @
        ["selection_id",identity;
         "unresolved",`List (List.map (fun (kind,count) ->
           `Assoc ["kind",kind;"count",`Int count]) failures)])
    | Ok _ -> `Assoc ["status",`String "unavailable";"reason",`String "invalid retrieval result"]
    | Error detail -> `Assoc ["status",`String "unavailable";"reason",`String detail;
                             "selection_id",identity] in
  let validate payload =
    match Yojson.Safe.Util.member "selected" payload with
    | `List (_ :: _ as rows) ->
      let* _ = Typesafeai_config.workspace_memory_selection_destinations ~keeper_id
        |> Result.map_error Typesafeai_config.unavailable_reason_to_string in
      let* snapshot = Domain_pool_ref.submit_io_or_inline (fun () ->
        View.resolve_snapshot ~base_path:config.Workspace.base_path) in
      List.fold_left (fun result row ->
        let* () = result in
        let id = Yojson.Safe.Util.(row |> member "id" |> to_string) in
        let* current = View.detail_in_snapshot snapshot ~id in
        let excluded = match Yojson.Safe.Util.member "members" current with
          | `List members -> List.exists (fun member ->
              match Yojson.Safe.Util.member "keeper_id" member with
              | `String keeper_id -> Typesafeai_config.is_excluded ~keeper_id
              | _ -> true) members
          | _ -> true in
        if excluded then Error "selected source is now excluded from retrieval"
        else if current = Yojson.Safe.Util.member "sources" row then Ok ()
        else Error "selected source changed before retry publication") (Ok ()) rows
    | _ -> Ok () in
  let retain ~reason ~payload = match adapter with
    | Some adapter -> IO.retain_projection adapter ~reason ~payload
    | None -> Error "no durable selection adapter" in
  make_prepared ~payload ~validate ~retain

let prepare ~config ~keeper_id ~purpose =
  let empty text = {payload=`Null;text;validate=(fun _ -> Ok ());
    retain=(fun ~reason:_ ~payload:_ -> Error "no selected memory")} in
  match Domain_pool_ref.submit_io_or_inline (fun () ->
    Workspace_memory_ledger.observe ~base_path:config.Workspace.base_path) with
  | Workspace_memory_ledger.Missing -> empty ""
  | Available descriptor when descriptor.claim_count=0 && descriptor.conflict_count=0 -> empty ""
  | Unavailable _ -> empty "\n\nShared memory is unavailable; no selected evidence was retrieved."
  | Available _ -> prepare_available ~config ~keeper_id ~purpose

let render ~config ~keeper_id ~purpose =
  render_prepared (prepare ~config ~keeper_id ~purpose)

module For_testing = struct
  let prepare_projection = make_prepared
  let collect = collect
  let collect_with_snapshots ~summary ~detail_snapshot ~evaluate ~purpose =
    collect_with ~is_excluded:(fun _ -> false)
      ~summary ~detail_snapshot ~evaluate ~purpose
end
