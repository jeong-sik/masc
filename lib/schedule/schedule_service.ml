type service_error =
  | Invalid_request of string
  | Store_error of Schedule_store.store_error
  | Creation_rejected of string
  | Due_already_past of
      { due_at : float
      ; now : float
      }

let ( let* ) = Result.bind

let service_error_to_string = function
  | Invalid_request msg -> "invalid request: " ^ msg
  | Store_error err -> Schedule_store.store_error_to_string err
  | Creation_rejected detail -> detail
  | Due_already_past { due_at; now } ->
    Printf.sprintf
      "due time %s is before now (%s); a wake is due at or after the current second"
      (Time_codec.rfc3339_of_unix due_at)
      (Time_codec.rfc3339_of_unix now)
;;

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

let make_request
      ~schedule_id
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
  Schedule_domain.create_request ~schedule_id ~requested_by ~scheduled_by
    ~requested_at ~due_at ?expires_at ~payload ~source ?recurrence ()
  |> function
  | Ok request -> Ok request
  | Error msg -> Error (Invalid_request msg)
;;

(* The first due is checked here, when a call proposes it: a Scheduled row
   whose due has passed is not wrong in the store -- the runner's refresh
   exists to find exactly that -- so a past due is a caller's mistake only in
   the call that writes it. [update] proposes one too; the store judges that
   one under its lock, because "unchanged" is read against the stored row. *)
let due_not_before_now ~now ~due_at =
  let current_second = Float.floor now in
  if Float.compare due_at current_second < 0
  then Error (Due_already_past { due_at; now = current_second })
  else Ok ()
;;

let create
  config
  ~now
  ~runner_tick_sec
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
  let* () = due_not_before_now ~now ~due_at in
  let schedule_id = schedule_id provided_schedule_id in
  let* request =
    make_request ~schedule_id ?requested_at ?expires_at ~requested_by
      ~scheduled_by ~due_at ~payload ~source ?recurrence ()
  in
  Schedule_store.insert_request config ~runner_tick_sec request |> map_store
;;

let update
      config
      ~now
      ~runner_tick_sec
      ~schedule_id
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
  let* request =
    make_request ~schedule_id ?requested_at ?expires_at ~requested_by
      ~scheduled_by ~due_at ~payload ~source ?recurrence ()
  in
  Schedule_store.update_request config ~now ~runner_tick_sec request |> map_store
;;

let cancel config ~schedule_id =
  Schedule_store.cancel_request config ~schedule_id |> map_store
;;

let prune config =
  match Schedule_store.prune_completed config with
  | Error err -> Error (Store_error err)
  | Ok (state, count) -> Ok (state, count)
;;
