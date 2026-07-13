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

let create
  config
  ?schedule_id:provided_schedule_id
  ?requested_at
  ?expires_at
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
  let* request =
    Schedule_domain.create_request ~schedule_id ~requested_by ~scheduled_by
      ~requested_at ~due_at ?expires_at ~payload ~source ?recurrence ()
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
