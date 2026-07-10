type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error

let ( let* ) = Result.bind

let service_error_to_string = function
  | Invalid_request msg -> "invalid request: " ^ msg
  | Store_error err -> Schedule_store.store_error_to_string err
;;

let map_store = function
  | Ok value -> Ok value
  | Error err -> Error (Store_error err)
;;

(* NDT-OK: service boundary clock; callers can pass explicit timestamps for replay/tests. *)
let now () = Unix.gettimeofday ()

let id_counter = Atomic.make 0

let mint_id prefix =
  let micros = int_of_float (now () *. 1_000_000.0) in
  let serial = Atomic.fetch_and_add id_counter 1 in
  (* NDT-OK: ID entropy only; schedule ordering and eligibility never branch on it. *)
  let entropy = Hashtbl.hash (Unix.getpid (), micros, serial) land 0xFFFFFF in
  Printf.sprintf "%s-%d-%06x-%d" prefix micros entropy serial
;;

let schedule_id = function
  | Some id -> id
  | None -> mint_id "sched"
;;

let grant_id = function
  | Some id -> id
  | None -> mint_id "grant"
;;

let create
  config
  ?schedule_id:provided_schedule_id
  ?requested_at
  ?expires_at
  ?(approval_required = false)
  ~requested_by
  ~scheduled_by
  ~due_at
  ~payload
  ~risk_class
  ~source
  ?recurrence
  ()
  =
  (* NDT-OK: API boundary default; callers may provide requested_at explicitly. *)
  let requested_at = Option.value requested_at ~default:(now ()) in
  let schedule_id = schedule_id provided_schedule_id in
  let* request =
    Schedule_domain.create_request ~schedule_id ~requested_by ~scheduled_by
      ~requested_at ~due_at ?expires_at ~payload ~risk_class
      ~approval_required ~source ?recurrence ()
    |> function
    | Ok request -> Ok request
    | Error msg -> Error (Invalid_request msg)
  in
  Schedule_store.insert_request config request |> map_store
;;

let list config ?status () =
  let schedules = Schedule_store.list_schedules config in
  match status with
  | None -> schedules
  | Some expected ->
    List.filter
      (fun (request : Schedule_domain.schedule_request) ->
        request.status = expected)
      schedules
;;

let get config ~schedule_id = Schedule_store.get_schedule config ~schedule_id

let decision_grant
  config
  ?grant_id:provided_grant_id
  ?approved_at
  ?(scope = Schedule_domain.Grant_occurrence)
  ~schedule_id
  ~approved_by
  ~decision
  ()
  =
  match Schedule_store.get_schedule config ~schedule_id with
  | None -> Error (Store_error Schedule_store.Schedule_not_found)
  | Some request -> (* NDT-OK: API boundary default; explicit approved_at is supported. *)
    let approved_at = Option.value approved_at ~default:(now ()) in
    let grant_id = grant_id provided_grant_id in
    let grant =
      Schedule_domain.create_execution_grant ~grant_id ~approved_by
        ~approved_at ~decision ~scope request
    in
    Schedule_store.record_grant config grant |> map_store
;;

let approve config ?grant_id ?approved_at ?scope ~schedule_id ~approved_by () =
  decision_grant config ?grant_id ?approved_at ?scope ~schedule_id ~approved_by
    ~decision:Schedule_domain.Approve ()
;;

let reject config ?grant_id ?approved_at ~schedule_id ~approved_by ~reason () =
  decision_grant config ?grant_id ?approved_at ~schedule_id ~approved_by
    ~decision:(Schedule_domain.Reject reason) ()
;;

let cancel config ~schedule_id =
  Schedule_store.cancel_request config ~schedule_id |> map_store
;;

let update config ~schedule_id ~due_at ~expires_at ~payload =
  Schedule_store.update_request config ~schedule_id ~due_at ~expires_at ~payload
  |> map_store
;;

let due_candidates config ~now =
  match Schedule_store.refresh_due config ~now with
  | Error err -> Error (Store_error err)
  | Ok (state, _) -> Ok (Schedule_store.due_execution_candidates state)
;;

let prune config =
  match Schedule_store.prune_completed config with
  | Error err -> Error (Store_error err)
  | Ok (state, count) -> Ok (state, count)
;;
