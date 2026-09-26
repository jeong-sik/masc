type count_after =
  | Count_continues
  | Count_restarts_from_zero

type reading =
  { reading_index : int
  ; response_id : string
  ; ordinal : int
  ; model : string
  ; basis : Keeper_usage_resolution.basis
  ; observation : Keeper_usage_resolution.sample option
  ; count_after : count_after
  }

type attempt =
  { routing_run_id : string
  ; runtime_id : string
  ; lane_attempt_index : int
  ; readings : reading list
  }

(* Attempts newest first, and each attempt's readings newest first. *)
type t = attempt list

type unplaced = No_attempt_started

let empty = []

let start_attempt t ~routing_run_id ~runtime_id ~lane_attempt_index =
  { routing_run_id; runtime_id; lane_attempt_index; readings = [] } :: t
;;

let attempts t =
  List.rev_map (fun attempt -> { attempt with readings = List.rev attempt.readings }) t
;;

let with_current_attempt t f =
  match t with
  | [] -> Error No_attempt_started
  | current :: earlier -> Ok (f current :: earlier)
;;

let append attempt reading_of_index =
  { attempt with
    readings = reading_of_index (List.length attempt.readings) :: attempt.readings
  }
;;

let replace attempt (updated : reading) =
  { attempt with
    readings =
      List.map
        (fun (reading : reading) ->
           if reading.reading_index = updated.reading_index then updated else reading)
        attempt.readings
  }
;;

let observation_of_count = function
  | Keeper_client_usage_report.Running_count usage ->
    Some (Keeper_usage_resolution.sample_of_api_usage usage)
  | Keeper_client_usage_report.Count_replaced -> None
;;

(* The newest reading of [conversation_id] in the attempt. *)
let conversation_reading attempt ~conversation_id =
  List.find_opt
    (fun (reading : reading) ->
       match reading.basis with
       | Keeper_usage_resolution.Conversation_counter { conversation_id = existing; _ } ->
         String.equal existing conversation_id
       | Keeper_usage_resolution.Per_request
       | Keeper_usage_resolution.Turn_total
       | Keeper_usage_resolution.Unavailable -> false)
    attempt.readings
;;

let client_turn_reading attempt ~basis ~response_id =
  List.find_opt
    (fun (reading : reading) ->
       reading.basis = basis && String.equal reading.response_id response_id)
    attempt.readings
;;

(* A newer count of the same reading: a count replaces the observation, and
   a replacement leaves the last count and marks what follows it. *)
let update (reading : reading) (report : Keeper_client_usage_report.t) =
  match report.count with
  | Keeper_client_usage_report.Running_count _ ->
    { reading with
      response_id = report.response_id
    ; ordinal = report.official_turn
    ; model = report.model
    ; observation = observation_of_count report.count
    }
  | Keeper_client_usage_report.Count_replaced ->
    { reading with count_after = Count_restarts_from_zero }
;;

let new_reading ~basis (report : Keeper_client_usage_report.t) reading_index =
  { reading_index
  ; response_id = report.response_id
  ; ordinal = report.official_turn
  ; model = report.model
  ; basis
  ; observation = observation_of_count report.count
  ; count_after =
      (match report.count with
       | Keeper_client_usage_report.Running_count _ -> Count_continues
       | Keeper_client_usage_report.Count_replaced -> Count_restarts_from_zero)
  }
;;

let observe_conversation_count attempt (report : Keeper_client_usage_report.t) =
  let conversation_id = report.conversation_id in
  let basis position =
    Keeper_usage_resolution.Conversation_counter
      { runtime_id = attempt.runtime_id; conversation_id; position }
  in
  match conversation_reading attempt ~conversation_id, report.count with
  | ( None
    , (Keeper_client_usage_report.Running_count _ | Keeper_client_usage_report.Count_replaced) )
    -> append attempt (new_reading ~basis:(basis report.position) report)
  | ( Some ({ count_after = Count_continues; _ } as reading)
    , (Keeper_client_usage_report.Running_count _ | Keeper_client_usage_report.Count_replaced) )
    -> replace attempt (update reading report)
  | Some { count_after = Count_restarts_from_zero; _ }, Keeper_client_usage_report.Running_count _
    ->
    (* The count after a replacement starts from zero, so it resumes from
       the zero the replaced reading leaves behind. *)
    append attempt (new_reading ~basis:(basis Keeper_usage_resolution.Resumed) report)
  | Some { count_after = Count_restarts_from_zero; _ }, Keeper_client_usage_report.Count_replaced
    ->
    (* Replaced again before anything was counted: nothing new to read. *)
    attempt
;;

let observe_client_turn_count attempt ~basis (report : Keeper_client_usage_report.t) =
  match client_turn_reading attempt ~basis ~response_id:report.response_id with
  | None -> append attempt (new_reading ~basis report)
  | Some reading -> replace attempt (update reading report)
;;

let observe_client_report t (report : Keeper_client_usage_report.t) =
  with_current_attempt t (fun attempt ->
    match report.usage_scope with
    | Runtime_usage_scope.Conversation_cumulative -> observe_conversation_count attempt report
    | Runtime_usage_scope.Turn_total ->
      observe_client_turn_count attempt ~basis:Keeper_usage_resolution.Turn_total report
    | Runtime_usage_scope.Per_request ->
      observe_client_turn_count attempt ~basis:Keeper_usage_resolution.Per_request report
    | Runtime_usage_scope.Usage_scope_unavailable ->
      observe_client_turn_count attempt ~basis:Keeper_usage_resolution.Unavailable report)
;;

let observe_agent_core_response t ~response_id ~ordinal ~model usage =
  with_current_attempt t (fun attempt ->
    append attempt (fun reading_index ->
      { reading_index
      ; response_id
      ; ordinal
      ; model
      ; basis = Keeper_usage_resolution.Per_request
      ; observation = Option.map Keeper_usage_resolution.sample_of_api_usage usage
      ; count_after = Count_continues
      }))
;;

type resolved =
  { routing_run_id : string
  ; runtime_id : string
  ; lane_attempt_index : int
  ; reading : reading
  ; resolution : Keeper_usage_resolution.t
  }

(* Where a replaced count starts again. The cost starts from zero too, so a
   later exact cost is its own delta. *)
let zero_count : Keeper_usage_resolution.sample =
  { input_tokens = 0
  ; output_tokens = 0
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd = Some 0.0
  }
;;

let cursor_after (reading : reading) cursor =
  match reading.count_after, reading.basis with
  | Count_restarts_from_zero, Keeper_usage_resolution.Conversation_counter { runtime_id; conversation_id; _ } ->
    Some { Keeper_usage_resolution.runtime_id; conversation_id; cumulative = zero_count }
  | ( Count_restarts_from_zero
    , ( Keeper_usage_resolution.Per_request
      | Keeper_usage_resolution.Turn_total
      | Keeper_usage_resolution.Unavailable ) )
  | Count_continues, _ -> cursor
;;

(* Resolved per attempt, in order: each reading against the cursor the one
   before it left, across attempts too. *)
let resolve_by_attempt ~cursor ~observed_at attempts =
  let by_attempt_rev, cursor =
    List.fold_left
      (fun (by_attempt_rev, cursor) (attempt : attempt) ->
         let resolved_rev, cursor =
           List.fold_left
             (fun (resolved_rev, cursor) (reading : reading) ->
                let resolution, cursor =
                  Keeper_usage_resolution.resolve
                    ~cursor
                    ~basis:reading.basis
                    ~observation:reading.observation
                    ~observed_at
                in
                let resolved =
                  { routing_run_id = attempt.routing_run_id
                  ; runtime_id = attempt.runtime_id
                  ; lane_attempt_index = attempt.lane_attempt_index
                  ; reading
                  ; resolution
                  }
                in
                resolved :: resolved_rev, cursor_after reading cursor)
             ([], cursor)
             attempt.readings
         in
         resolved_rev :: by_attempt_rev, cursor)
      ([], cursor)
      attempts
  in
  by_attempt_rev, cursor
;;

let resolve ~cursor ~observed_at attempts =
  let by_attempt_rev, cursor = resolve_by_attempt ~cursor ~observed_at attempts in
  List.concat_map List.rev (List.rev by_attempt_rev), cursor
;;

type turn_resolution =
  { turn_reading : resolved option
  ; other_readings : resolved list
  ; cursor : Keeper_usage_resolution.cursor option
  }

let resolve_turn ~cursor ~observed_at attempts =
  let by_attempt_rev, cursor = resolve_by_attempt ~cursor ~observed_at attempts in
  let in_order readings_rev = List.concat_map List.rev (List.rev readings_rev) in
  match by_attempt_rev with
  | (turn_reading :: last_attempt_earlier_rev) :: earlier_attempts_rev ->
    { turn_reading = Some turn_reading
    ; other_readings =
        in_order earlier_attempts_rev @ List.rev last_attempt_earlier_rev
    ; cursor
    }
  | [] :: earlier_attempts_rev ->
    { turn_reading = None; other_readings = in_order earlier_attempts_rev; cursor }
  | [] -> { turn_reading = None; other_readings = []; cursor }
;;
