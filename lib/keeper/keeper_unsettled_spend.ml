type outcome =
  { scanned_rows : int
  ; settled_turns : int
  ; settled_readings : int
  ; unplaced_rows : int
  }

(* A ledger line can be any JSON value; only an object has fields. *)
let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let belongs_to ~agent_name json =
  match member "agent" json with
  | Some (`String agent) -> String.equal agent agent_name
  | Some _ | None -> false
;;

let is_resolved (row : Cost_ledger.t) =
  match row.usage_projection with
  | Cost_ledger.Resolved_delta | Cost_ledger.Resolved_attempt_delta _ -> true
  | Cost_ledger.Raw_observation _ -> false
;;

let unsettled_rows ~agent_name newest_first =
  let rec take acc = function
    | [] -> acc
    | json :: older ->
      if not (belongs_to ~agent_name json)
      then take acc older
      else (
        match Cost_ledger.of_json json with
        | Ok row when is_resolved row -> acc
        | Ok _ | Error _ -> take (json :: acc) older)
  in
  take [] newest_first
;;

type placed =
  { turn : string * int
  ; task_id : string option
  ; attempt : string * string * int
  ; observation : Keeper_spend_observation.t
  }

let int_member key json =
  match member key json with
  | Some (`Int value) -> Some value
  | Some _ | None -> None
;;

let string_member key json =
  match member key json with
  | Some (`String value) when not (String.equal (String.trim value) "") -> Some value
  | Some _ | None -> None
;;

let attempt_of_json json =
  match
    string_member "routing_run_id" json, string_member "runtime_id" json,
    int_member "lane_attempt_index" json
  with
  | Some run, Some runtime, Some index -> Some (run, runtime, index)
  | _ -> None
;;

(* A row without the observation was written before rows carried one, or is
   a count the spend did not read (an official client's own response); either
   way there is nothing to observe again. A conversation-cumulative report is
   read against the committed cursor, so the next count of its conversation
   already covers it. *)
let observation_of_json json =
  match member Keeper_spend_observation.field json with
  | None | Some `Null -> None
  | Some observation_json ->
    (match Keeper_spend_observation.of_json observation_json with
     | Error _ -> None
     | Ok (Keeper_spend_observation.Client_report { usage_scope = Runtime_usage_scope.Conversation_cumulative; _ }) ->
       None
     | Ok
         ((Keeper_spend_observation.Agent_core_response _
          | Keeper_spend_observation.Client_report
              { usage_scope =
                  ( Runtime_usage_scope.Per_request
                  | Runtime_usage_scope.Turn_total
                  | Runtime_usage_scope.Usage_scope_unavailable )
              ; _
              }) as observation) -> Some observation)
;;

let place json =
  match Cost_ledger.of_json json with
  | Error _ -> None
  | Ok row ->
    (match row.source, row.usage_projection with
     | Cost_ledger.Auto_trajectory identity, Cost_ledger.Raw_observation _ ->
       (match attempt_of_json json, observation_of_json json with
        | Some attempt, Some observation ->
          Some
            { turn = identity.trace_id, identity.keeper_turn_id
            ; task_id = row.task_id
            ; attempt
            ; observation
            }
        | None, _ | _, None -> None)
     | Cost_ledger.Manual_cli, _
     | Cost_ledger.Auto_trajectory _, (Cost_ledger.Resolved_delta | Cost_ledger.Resolved_attempt_delta _)
       -> None)
;;

(* Keys in order of first appearance, each with its values in order. *)
let group_in_order key_of values =
  let keys_rev, table =
    List.fold_left
      (fun (keys_rev, table) value ->
         let key = key_of value in
         match List.assoc_opt key table with
         | Some members -> keys_rev, (key, value :: members) :: List.remove_assoc key table
         | None -> key :: keys_rev, (key, [ value ]) :: table)
      ([], [])
      values
  in
  List.rev_map (fun key -> key, List.rev (List.assoc key table)) keys_rev
;;

let spend_of_attempts attempts =
  List.fold_left
    (fun spend ((routing_run_id, runtime_id, lane_attempt_index), rows) ->
       let started =
         Keeper_turn_spend.start_attempt spend ~routing_run_id ~runtime_id ~lane_attempt_index
       in
       List.fold_left
         (fun spend placed ->
            match Keeper_spend_observation.observe spend placed.observation with
            | Ok spend -> spend
            (* Unreachable: the attempt was started just above. *)
            | Error Keeper_turn_spend.No_attempt_started -> spend)
         started
         rows)
    Keeper_turn_spend.empty
    attempts
;;

let settle_rows ~masc_root ~agent_name ~observed_at rows =
  let placed = List.filter_map place rows in
  let turns = group_in_order (fun placed -> placed.turn) placed in
  let settled_readings =
    List.fold_left
      (fun settled ((trace_id, keeper_turn_id), turn_rows) ->
         let attempts = group_in_order (fun placed -> placed.attempt) turn_rows in
         let resolved, (_ : Keeper_usage_resolution.cursor option) =
           Keeper_turn_spend.resolve
             ~cursor:None
             ~observed_at
             (Keeper_turn_spend.attempts (spend_of_attempts attempts))
         in
         let task_id = List.find_map (fun placed -> placed.task_id) turn_rows in
         Keeper_turn_spend_ledger.write
           ~masc_root
           ~agent_name
           ~task_id
           ~trace_id
           ~keeper_turn_id
           resolved;
         settled + List.length resolved)
      0
      turns
  in
  { scanned_rows = List.length rows
  ; settled_turns = List.length turns
  ; settled_readings
  ; unplaced_rows = List.length rows - List.length placed
  }
;;

let settle ~masc_root ~agent_name ~observed_at =
  let store = Cost_ledger.store_of_masc_root masc_root in
  let scanned = ref 0 in
  (* The Keeper's rows as visited, newest first, down to and including its
     newest resolved row; [unsettled_rows] decides what lies above it. *)
  let visited_oldest_first = ref [] in
  let stop_at_newest_resolved = function
    | Dated_jsonl.Malformed_json _ -> None
    | Dated_jsonl.Parsed json ->
      incr scanned;
      if not (belongs_to ~agent_name json)
      then None
      else (
        visited_oldest_first := json :: !visited_oldest_first;
        match unsettled_rows ~agent_name [ json ] with
        | [] -> Some ()
        | _ :: _ -> None)
  in
  match Dated_jsonl.find_latest_entry_result store stop_at_newest_resolved with
  | Error error -> Error error
  | Ok (_ : unit option) ->
    let rows = unsettled_rows ~agent_name (List.rev !visited_oldest_first) in
    let outcome = settle_rows ~masc_root ~agent_name ~observed_at rows in
    Ok { outcome with scanned_rows = !scanned }
;;

let settle_before_execution ~masc_root ~agent_name =
  match settle ~masc_root ~agent_name ~observed_at:(Time_compat.now ()) with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Log.Keeper.warn ~keeper_name:agent_name
      "settling a cancelled execution's spend raised: %s" (Printexc.to_string exn)
  | Ok { settled_readings = 0; unplaced_rows = 0; _ } -> ()
  | Ok outcome ->
    Log.Keeper.info ~keeper_name:agent_name
      "settled spend a cancelled execution left out: turns=%d readings=%d unplaced=%d scanned=%d"
      outcome.settled_turns outcome.settled_readings outcome.unplaced_rows outcome.scanned_rows
  | Error error ->
    Log.Keeper.warn ~keeper_name:agent_name
      "could not read the cost ledger to settle a cancelled execution's spend: %s"
      (Dated_jsonl.read_error_to_string error)
;;
