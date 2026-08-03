type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error
  | Creation_rejected of string

type keeper_wake_creation_gate =
  Workspace_utils.config ->
  keeper_name:string ->
  (unit -> (Schedule_domain.schedule_request, service_error) result) ->
  (Schedule_domain.schedule_request, service_error) result

let ( let* ) = Result.bind

let service_error_to_string = function
  | Invalid_request msg -> "invalid request: " ^ msg
  | Store_error err -> Schedule_store.store_error_to_string err
  | Creation_rejected detail -> detail
;;

let keeper_wake_creation_gate : keeper_wake_creation_gate Atomic.t =
  Atomic.make (fun _config ~keeper_name:_ _create ->
    Error (Creation_rejected "keeper-wake creation admission gate is not installed"))
;;

let set_keeper_wake_creation_gate gate = Atomic.set keeper_wake_creation_gate gate

let map_store = function
  | Ok value -> Ok value
  | Error err -> Error (Store_error err)
;;

(* NDT-OK: service boundary clock; callers can pass explicit timestamps for replay/tests. *)
let now () = Unix.gettimeofday ()

let schedule_id = function
  | Some id -> id
  | None -> Random_id.prefixed ~prefix:"sched-" ~bytes:16
;;

let create
  config
  ?schedule_id:provided_schedule_id
  ?requested_at
  ?expires_at
  ?keeper_wake_target
  ~requested_by
  ~scheduled_by
  ~due_at
  ~payload
  ~source
  ?recurrence
  ()
  =
  (* NDT-OK: API boundary default; callers may provide requested_at explicitly. *)
  let requested_at = Option.value requested_at ~default:(now ()) in
  let schedule_id = schedule_id provided_schedule_id in
  let create_request () =
    let* request =
      Schedule_domain.create_request ~schedule_id ~requested_by ~scheduled_by
        ~requested_at ~due_at ?expires_at ~payload ~source ?recurrence ()
      |> function
      | Ok request -> Ok request
      | Error msg -> Error (Invalid_request msg)
    in
    Schedule_store.insert_request config request |> map_store
  in
  match keeper_wake_target with
  | None -> create_request ()
  | Some keeper_name ->
    (Atomic.get keeper_wake_creation_gate) config ~keeper_name create_request
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
