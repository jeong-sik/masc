module Selection = Keeper_workspace_memory_selection
module View = Workspace_memory_ledger_view
module IO = Keeper_workspace_memory_selection_io
module String_map = Map.Make (String)
open Result.Syntax

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

type retrieval_phase =
  { summary : Yojson.Safe.t
  ; detail : id:string -> (Yojson.Safe.t, string) result
  }

let read_curator_phase ~base_path () =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let* snapshot = View.resolve_snapshot ~base_path in
    let* summary = View.summary_in_snapshot snapshot in
    Ok { summary; detail = View.detail_in_snapshot snapshot })
;;

let world_recall_record (fact : World_memory_types.world_fact) =
  let owners =
    match fact.provenance with
    | World_memory_types.Proposed_by { keeper_id; _ } -> [ keeper_id ]
    | World_memory_types.Cross_keeper_synthesized { keeper_ids; _ } -> keeper_ids
  in
  let members =
    List.sort_uniq String.compare owners
    |> List.map (fun keeper_id -> `Assoc [ "keeper_id", `String keeper_id ])
  in
  [ "id", `String fact.fact_id
  ; "text", `String fact.claim
  ; "scope", `String fact.scope
  ; "revision", `Int fact.revision
  ; "updated_seq", `Int fact.updated_seq
  ; "members", `List members
  ]
;;

let read_world_phase ~base_path () =
  let* snapshot =
    World_memory_store.read_snapshot ~include_inactive:false ~base_path ()
    |> Result.map_error World_memory_store.error_to_string
  in
  let records =
    List.fold_left
      (fun records (fact : World_memory_types.world_fact) ->
         if World_memory_types.is_private_scope fact.scope then records
         else String_map.add fact.fact_id (world_recall_record fact) records)
      String_map.empty
      snapshot.facts
  in
  let claims =
    String_map.bindings records |> List.map (fun (_, fields) -> `Assoc fields)
  in
  (* Digest jobs have their own cadence. Bind recall to the content read in
     this transaction, including changes between two digest publications. *)
  let ledger_sha256 =
    Agent_core_sha256.(digest_string (Yojson.Safe.to_string (`List claims)) |> to_hex)
  in
  let summary =
    `Assoc
      [ "status", `String "available"
      ; "ledger_sha256", `String ledger_sha256
      ; "claims", `List claims
      ; "conflicts", `List []
      ]
  in
  let detail ~id =
    match String_map.find_opt id records with
    | None -> Ok (`Assoc [ "found", `Bool false; "id", `String id ])
    | Some fields ->
      Ok
        (`Assoc
           ([ "found", `Bool true
            ; "kind", `String "claim"
            ; "ledger_sha256", `String ledger_sha256
            ; "semantic_verification", `String "not_performed"
            ] @ fields))
  in
  Ok { summary; detail }
;;

let phase_reader ~base_path =
  if World_memory_store.exists ~base_path then read_world_phase ~base_path
  else read_curator_phase ~base_path
;;

let collect_with ~is_excluded ~initial ~read_phase ~evaluate ~purpose =
  let* snapshot = decode_summary ~is_excluded initial.summary in
  match snapshot with
  | None -> Ok (`Assoc ["status",`String "missing"])
  | Some (ledger_sha256,candidates,withheld) ->
    let resolve = bound_detail ~detail:initial.detail ~ledger_sha256 in
    let decisions = Selection.select_many ~evaluate ~resolve ~purpose candidates in
    (* Revalidate after model execution, including sources that can change
       independently of the Curator ledger. No stale selection is published. *)
    let* final = read_phase () in
    let* final_snapshot = decode_summary ~is_excluded final.summary in
    let* () = match final_snapshot with
      | Some (current,_,final_withheld) when String.equal current ledger_sha256 && final_withheld=withheld -> Ok ()
      | Some _ | None -> Error "shared ledger changed before retrieval publication" in
    let resolve = bound_detail ~detail:final.detail ~ledger_sha256 in
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

let render_payload payload =
  let unavailable = "\n\nShared memory host retrieval could not be rendered; availability is unknown." in
  try
    match Prompt_registry.render_prompt_template
        Prompt_names.keeper_context_workspace_memory_host_selected
        ["payload",Yojson.Safe.to_string payload] with
    | Ok text -> "\n\n" ^ text
    | Error _ -> unavailable
  with
  | Sys_error detail ->
    Log.Keeper.warn "workspace memory host recall prompt unavailable: %s" detail;
    unavailable

(* A rendered projection belongs to its payload. Each observation retains
   the exact pair it checked while validation and persistence can yield. *)
type projection = { payload : Yojson.Safe.t; text : string }

type prepared =
  { projection : projection Atomic.t
  ; validate : Yojson.Safe.t -> (unit,string) result
  ; retain : reason:string -> payload:Yojson.Safe.t -> (unit,string) result
  }

let make_prepared ~payload ~validate ~retain =
  {projection=Atomic.make {payload;text=render_payload payload};validate;retain}

let unavailable_payload payload reason = `Assoc
  ["status",`String "unavailable";"reason",`String reason;
   "selection_id",Yojson.Safe.Util.member "selection_id" payload]

let projection_changed_text =
  "\n\nShared memory selection changed during revalidation; this host-selected projection is unavailable."

let render_prepared prepared =
  let current = Atomic.get prepared.projection in
  match prepared.validate current.payload with
  | Ok () ->
    if Atomic.get prepared.projection == current then current.text
    else projection_changed_text
  | Error reason ->
    if Atomic.get prepared.projection != current then projection_changed_text
    else
      let payload = unavailable_payload current.payload reason in
      let payload = match prepared.retain ~reason:"source_revalidation_failed" ~payload with
        | Ok () -> payload
        | Error _ -> unavailable_payload payload "source revalidation and projection receipt unavailable" in
      let projection = {payload;text=render_payload payload} in
      if Atomic.compare_and_set prepared.projection current projection then projection.text
      else projection_changed_text

let defer_for_capacity prepared ~refusal =
  let open Keeper_memory_delivery_reprojection in
  let current = Atomic.get prepared.projection in
  let changed = "shared memory projection changed during capacity reduction" in
  let unchanged () =
    if Atomic.get prepared.projection == current then Ok Unchanged else Error changed in
  match current.payload with
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
         if String.length text < String.length current.text then (
           if Atomic.get prepared.projection != current then Error changed
           else
             let* () = prepared.retain
               ~reason:(Agent_core.Error.to_string refusal) ~payload in
             if Atomic.compare_and_set prepared.projection current {payload;text}
             then Ok Reprojected else Error changed)
         else if keep=0 then unchanged () else smaller (keep / 2) in
       smaller (List.length rows / 2)
     | Some _ | None -> unchanged ())
  | _ -> unchanged ()

let prepare_available ~config ~keeper_id ~purpose ~initial ~read_phase =
  let result,adapter =
    match Typesafeai_config.workspace_memory_selection_destinations ~keeper_id with
      | Error reason -> Error (Typesafeai_config.unavailable_reason_to_string reason),None
      | Ok destinations ->
        let adapter = IO.create ~config ~keeper_id ~destinations in
        let result = collect_with
          ~is_excluded:(fun keeper_id -> Typesafeai_config.is_excluded ~keeper_id)
          ~initial ~read_phase
          ~evaluate:(IO.evaluate ~clock:(Eio_context.get_clock_opt ()) adapter) ~purpose in
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
      let* phase = read_phase () in
      List.fold_left (fun result row ->
        let* () = result in
        let id = Yojson.Safe.Util.(row |> member "id" |> to_string) in
        let* current = phase.detail ~id in
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
  let empty text = {projection=Atomic.make {payload=`Null;text};validate=(fun _ -> Ok ());
    retain=(fun ~reason:_ ~payload:_ -> Error "no selected memory")} in
  let read_phase = phase_reader ~base_path:config.Workspace.base_path in
  match read_phase () with
  | Error _ -> empty "\n\nShared memory is unavailable; no selected evidence was retrieved."
  | Ok initial ->
    let open Yojson.Safe.Util in
    if member "status" initial.summary = `String "missing"
       || (member "claims" initial.summary = `List [] && member "conflicts" initial.summary = `List [])
    then empty ""
    else prepare_available ~config ~keeper_id ~purpose ~initial ~read_phase


let render ~config ~keeper_id ~purpose =
  render_prepared (prepare ~config ~keeper_id ~purpose)

module For_testing = struct
  let prepare_projection = make_prepared

  let collect_fixture ~is_excluded ~summary ~detail_snapshot ~evaluate ~purpose =
    let read_phase () =
      let* summary = summary () in
      Ok { summary; detail = detail_snapshot () }
    in
    let* initial = read_phase () in
    collect_with ~is_excluded ~initial ~read_phase ~evaluate ~purpose

  let collect_with_snapshots ~summary ~detail_snapshot ~evaluate ~purpose =
    collect_fixture ~is_excluded:(fun _ -> false) ~summary ~detail_snapshot ~evaluate ~purpose

  let collect ?(is_excluded = fun _ -> false) ~summary ~detail ~evaluate ~purpose () =
    collect_fixture ~is_excluded ~summary ~detail_snapshot:(fun () -> detail) ~evaluate ~purpose

  let collect_from_store ~base_path ~is_excluded ~evaluate ~purpose =
    let read_phase = phase_reader ~base_path in
    let* initial = read_phase () in
    collect_with ~is_excluded ~initial ~read_phase ~evaluate ~purpose
end
