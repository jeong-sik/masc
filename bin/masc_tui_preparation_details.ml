module Log = Masc_tui_keeper_chat_log
module Observation = Masc.Keeper_preparation_runtime_observation
module Manifest = Masc.Keeper_runtime_manifest
module Preview = Masc.Keeper_turn_preview

type target =
  { journal : Log.t
  ; revision : int
  ; keeper_name : string
  ; turn_ref : Ids.Turn_ref.t
  ; operation_id : Keeper_operation_id.t option
  }

let target ~journal ~execution_id ~reply_turn_ref =
  let open Result.Syntax in
  let* turn_ref, operation_id = match Log.source journal with
    | Log.Autonomous_turn turn_ref -> Ok (turn_ref, None)
    | Operation _ ->
      let* operation_id = Keeper_operation_id.of_string execution_id in
      let terminal_turn_ref = match Log.operation_state journal with
        | Some (Keeper_chat_operation.Succeeded {outcome_ref;_}) -> Some outcome_ref
        | Some (Failed {failure={outcome_ref;_};_}) -> outcome_ref
        | None | Some (Queued | Running _ | Cancelled _) -> None in
      let decode = function
        | None -> Ok None
        | Some value -> (match Ids.Turn_ref.of_string value with
          | Some turn_ref -> Ok (Some turn_ref) | None -> Error "기록된 턴 연결을 읽을 수 없음") in
      let* reply = decode reply_turn_ref in
      let* terminal = decode terminal_turn_ref in
      let* turn_ref = match reply, terminal with
        | None, None -> Error "원래 턴 연결이 아직 확인되지 않음"
        | Some turn_ref, None | None, Some turn_ref -> Ok turn_ref
        | Some reply, Some terminal when Ids.Turn_ref.equal reply terminal -> Ok reply
        | Some _, Some _ -> Error "응답과 operation의 원래 턴 연결이 일치하지 않음" in
      Ok (turn_ref, Some operation_id) in
  Ok {journal; revision=Log.revision journal; keeper_name=Log.keeper_name journal; turn_ref; operation_id}
;;

let equal a b =
  a.journal == b.journal && a.revision=b.revision
  && String.equal a.keeper_name b.keeper_name && Ids.Turn_ref.equal a.turn_ref b.turn_ref
  && (match a.operation_id, b.operation_id with
    | Some a, Some b -> Keeper_operation_id.equal a b
    | None, None -> true | Some _, None | None, Some _ -> false)
;;

let path target =
  Printf.sprintf "/api/v1/keepers/%s/runtime-trace?trace_id=%s&turn_id=%d"
    (Uri.pct_encode target.keeper_name)
    (Uri.pct_encode ~component:`Query_value (Ids.Turn_ref.trace_id target.turn_ref))
    (Ids.Turn_ref.absolute_turn target.turn_ref)
;;

type issue =
  | Partial_scan | Partial_return | Missing_manifest
  | Scan_unsupported_events of int
  | Scan_invalid_manifest_rows of int | Scan_invalid_json_rows of int
  | Unsupported_rows of int | Invalid_rows of int
  | Invalid_report of string | Duplicate_report of string | Unlinked_report
type snapshot = {observed_target : target; reports : Observation.report list; issues : issue list}

let field key = function
  | `Assoc fields -> (match List.filter (fun (name,_) -> String.equal name key) fields with
    | [_,value] -> Ok value | [] -> Error ("missing runtime-trace field: " ^ key)
    | _ -> Error ("duplicate runtime-trace field: " ^ key))
  | _ -> Error "runtime-trace object expected"
;;

let nonnegative = function
  | `Int value when value>=0 -> Ok value | _ -> Error "nonnegative runtime-trace count expected"
;;

let decode ~target json =
  let open Result.Syntax in
  let* keeper = field "keeper" json in
  let* trace = field "trace_id" json in
  let* turn = field "turn_id" json in
  let* () = if keeper=`String target.keeper_name
      && trace=`String (Ids.Turn_ref.trace_id target.turn_ref)
      && turn=`Int (Ids.Turn_ref.absolute_turn target.turn_ref) then Ok ()
    else Error "runtime-trace response belongs to another execution" in
  let* rows = field "manifest_rows" json in
  let* rows = match rows with `List rows -> Ok rows | _ -> Error "manifest rows must be an array" in
  let* returned = field "manifest_returned_rows" json in
  let* returned = nonnegative returned in
  let* total = field "manifest_total_rows" json in
  let* total = nonnegative total in
  let* () = if returned=List.length rows && total>=returned then Ok ()
    else Error "runtime-trace row counts are inconsistent" in
  let* exact = field "manifest_total_rows_exact" json in
  let* exact = match exact with `Bool value -> Ok value | _ -> Error "manifest scan coverage is missing" in
  let* present = field "manifest_path_present" json in
  let* present = match present with `Bool value -> Ok value | _ -> Error "manifest presence is missing" in
  let* () = if present || total=0 then Ok () else Error "missing manifest carries returned rows" in
  let* diagnostics = field "manifest_scan_diagnostics" json in
  let* schema = field "schema" diagnostics in
  let* () = if schema=`String "keeper.runtime_manifest_scan_diagnostics.v1" then Ok ()
    else Error "unsupported runtime-trace diagnostic schema" in
  let count key = let* value = field key diagnostics in nonnegative value in
  let* unsupported = count "unsupported_event_count" in
  let* invalid_rows = count "invalid_manifest_row_count" in
  let* invalid_json = count "invalid_json_row_count" in
  let issues = List.filter_map Fun.id
      [if exact then None else Some Partial_scan; if returned=total then None else Some Partial_return;
       if present then None else Some Missing_manifest;
       if unsupported=0 then None else Some (Scan_unsupported_events unsupported);
       if invalid_rows=0 then None else Some (Scan_invalid_manifest_rows invalid_rows);
       if invalid_json=0 then None else Some (Scan_invalid_json_rows invalid_json)] in
  let report_matches (report : Observation.report) =
    match target.operation_id, report.execution_scope with
    | Some expected, Some scope ->
      `Matches (Option.exists (Keeper_operation_id.equal expected)
        (Keeper_execution_scope_id.direct_operation_id scope))
    | Some _, None -> `Unlinked
    | None, None -> `Matches true
    | None, Some scope -> `Matches (Option.is_none (Keeper_execution_scope_id.direct_operation_id scope)) in
  let read_row (reports, issues, ids) raw =
    let reject issue = reports, issue::issues, ids in
    match Manifest.decode_persisted_row raw with
    | Error _ -> reject (Invalid_rows 1)
    | Ok (Manifest.Unsupported_row _) -> reject (Unsupported_rows 1)
    | Ok (Manifest.Active_row row) ->
      if row.keeper_name<>target.keeper_name || row.trace_id<>Ids.Turn_ref.trace_id target.turn_ref
         || row.keeper_turn_id<>Some (Ids.Turn_ref.absolute_turn target.turn_ref) then
        reject (Invalid_report "manifest row belongs to another turn")
      else if row.event<>Manifest.Preparation_observed then reports, issues, ids
      else
        let report = let* payload = field "preparation_report" row.decision in
          Observation.report_of_json payload in
        match report with
        | Error detail -> reject (Invalid_report detail)
        | Ok report ->
          let ids = report.report_id::ids in
          let reject issue = reports, issue::issues, ids in
          let clocks_match =
            let clocks = let* clocks = field "clock_refs" row.decision in
              let* edge = field "edge_id" clocks in
              let* clock = field "source_clock" clocks in
              let* role = field "payload_role" row.decision in
              Ok (edge=`String report.report_id && clock=`String "logical" && role=`String "operator_evidence") in
            clocks=Ok true in
          if not clocks_match then reject (Invalid_report "preparation report clock/role is inconsistent")
          else if not (Option.exists (Ids.Turn_ref.equal target.turn_ref) report.turn_ref)
             || not (List.for_all (fun (span : Preview.preparation_span) ->
               Option.exists (Ids.Turn_ref.equal target.turn_ref) span.preparation.turn_ref)
                 (Preview.preparation_spans report.timeline)) then
            reject (Invalid_report "preparation report has no exact original turn link")
          else match report_matches report with
            | `Unlinked -> reject Unlinked_report
            | `Matches false -> reports, issues, ids
            | `Matches true -> report::reports, issues, ids in
  let reports, issues, ids = List.fold_left read_row ([], List.rev issues, []) rows in
  let module Keys = Set.Make (String) in
  let _, duplicates = List.fold_left (fun (seen, duplicates) id ->
    Keys.add id seen, (if Keys.mem id seen then Keys.add id duplicates else duplicates))
      (Keys.empty, Keys.empty) ids in
  let reports = List.rev reports |> List.filter (fun (report : Observation.report) ->
    not (Keys.mem report.report_id duplicates)) in
  Ok {observed_target=target; reports; issues=List.rev issues @ List.map (fun id -> Duplicate_report id) (Keys.elements duplicates)}
;;

type request = {target : target; nonce : unit ref}
type t =
  { selected : target option
  ; pending : request option
  ; cached : (target * (snapshot, string) result) option
  ; retained : (target * snapshot) option
  }
type recheck = Recheck_pending | Recheck_loading | Recheck_failed of string
type view =
  | Not_loaded | Loading | Failed of string | Loaded of snapshot
  | Retained of { snapshot : snapshot; recheck : recheck }
let empty = {selected=None; pending=None; cached=None; retained=None}

let refresh ~keeper_name state =
  let pending = match state.pending with
    | Some request when String.equal keeper_name request.target.keeper_name -> None
    | (Some _ | None) as pending -> pending in
  let cached, retained = match state.cached with
    | Some (target, Ok snapshot) when String.equal keeper_name target.keeper_name ->
      None, Some (target,snapshot)
    | Some (target, Error _) when String.equal keeper_name target.keeper_name -> None, state.retained
    | Some (_, (Ok _ | Error _)) | None -> state.cached, state.retained in
  if pending==state.pending && cached==state.cached && retained==state.retained then state
  else {state with pending; cached; retained}
;;

let select selected state =
  match selected with
  | None when Option.is_none state.selected -> state, None
  | None -> {state with selected=None}, None
  | Some target ->
    let same_pending = Option.exists (fun request -> equal target request.target) state.pending in
    let same_cached = Option.exists (fun (previous,_) -> equal target previous) state.cached in
    let same_selected = Option.exists (equal target) state.selected in
    if same_pending && same_selected then state, None
    else if same_pending then {state with selected}, None
    else if same_cached && same_selected && Option.is_none state.pending then state, None
    else if same_cached then {state with selected; pending=None}, None
    else
      let request = {target; nonce=ref ()} in
      {state with selected; pending=Some request}, Some request
;;

let requested_target request = request.target

let last_observed target state =
  match state.cached with
  | Some (cached, Ok snapshot) when equal cached target -> Some snapshot
  | Some (_, (Ok _ | Error _)) | None ->
    match state.retained with
    | Some (cached, snapshot) when equal cached target -> Some snapshot
    | Some _ | None -> None
;;

let receive request result state =
  match state.pending with
  | Some pending when pending.nonce==request.nonce && equal pending.target request.target ->
    let target = pending.target in
    let result = match result with
      | Ok snapshot when not (equal target snapshot.observed_target) ->
        Error "preparation observation belongs to another selection"
      | Ok _ | Error _ -> result in
    let retained = match result with
      | Ok _ -> None
      | Error _ -> Option.map (fun snapshot -> target,snapshot) (last_observed target state) in
    {state with pending=None; cached=Some (target,result); retained}
  | Some _ | None -> state
;;

let view target state =
  match state.selected with
  | Some selected when equal target selected ->
    let retained recheck fallback = match last_observed target state with
      | Some snapshot -> Retained {snapshot;recheck}
      | None -> fallback in
    (match state.pending, state.cached with
     | Some request, (Some (_, (Ok _ | Error _)) | None) when equal request.target target ->
       retained Recheck_loading Loading
     | (Some _ | None), Some (cached, Ok snapshot) when equal cached target -> Loaded snapshot
     | (Some _ | None), Some (cached, Error detail) when equal cached target ->
       retained (Recheck_failed detail) (Failed detail)
     | (Some _ | None), (Some (_, (Ok _ | Error _)) | None) -> retained Recheck_pending Not_loaded)
  | Some _ | None -> Not_loaded
;;
