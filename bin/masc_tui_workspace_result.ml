type 'message ready = { ready_at_ns : int64; message : 'message }
type 'message open_state =
  { pending : unit ref list
  ; ready_rev : 'message ready list
  }
type 'message contents = Open of 'message open_state | Closed
type 'message t = 'message contents Atomic.t

let create () = Atomic.make (Open { pending = []; ready_rev = [] })

let rec remove_pending token prefix = function
  | [] -> None
  | current :: rest when current == token -> Some (List.rev_append prefix rest)
  | current :: rest -> remove_pending token (current :: prefix) rest

let register results =
  let token = ref () in
  let rec claim () =
    let before = Atomic.get results in
    match before with
    | Closed -> None
    | Open state ->
      if Atomic.compare_and_set results before (Open { state with pending = token :: state.pending })
      then Some token else claim () in
  claim ()

let retire_pending results token =
  let rec retire () =
    let before = Atomic.get results in
    match before with
    | Closed -> ()
    | Open state ->
      (match remove_pending token [] state.pending with
       | None -> ()
       | Some pending ->
         if not (Atomic.compare_and_set results before (Open { state with pending })) then retire ()) in
  retire ()

let publish results token message =
  let ready = {ready_at_ns = Mtime_clock.elapsed_ns (); message} in
  let rec commit () =
    let before = Atomic.get results in
    match before with
    | Closed -> ()
    | Open state ->
      (match remove_pending token [] state.pending with
       | None -> ()
       | Some pending ->
         let after = Open { pending; ready_rev = ready :: state.ready_rev } in
         if not (Atomic.compare_and_set results before after) then commit ()) in
  commit ()

let publish_progress results token message =
  let ready={ready_at_ns=Mtime_clock.elapsed_ns ();message} in
  let rec commit () =
    let before=Atomic.get results in
    match before with
    | Closed -> ()
    | Open state ->
      if List.exists (fun held -> held==token) state.pending then
        let after=Open {state with ready_rev=ready::state.ready_rev} in
        if not (Atomic.compare_and_set results before after) then commit () in
  commit ()

let take_ready results =
  let rec take () =
    let before = Atomic.get results in
    match before with
    | Closed -> []
    | Open { ready_rev = []; _ } -> []
    | Open ({ ready_rev = _ :: _; _ } as state) ->
      if Atomic.compare_and_set results before (Open { state with ready_rev = [] })
      then List.rev state.ready_rev else take () in
  take ()

let close results = Atomic.set results Closed

type 'message cancellation = Propagate | Publish_cancelled of 'message
let launch_registered ~cancellation ~dispatch ~on_not_run ~results ~boundary_error ~not_started_error ~deliver perform =
  match register results with
  | None -> on_not_run ()
  | Some token ->
    let deliver_result result = publish results token (deliver result) in
    let publish_cancelled () = match cancellation with
      | Propagate -> () | Publish_cancelled message -> publish results token message in
    let propagate_cancelled exn =
      let backtrace=Printexc.get_raw_backtrace () in
      publish_cancelled ();
      Printexc.raise_with_backtrace exn backtrace in
    let run () = Fun.protect ~finally:(fun () -> retire_pending results token) (fun () ->
      let result = try perform (publish_progress results token) with
        | Eio.Cancel.Cancelled _ as exn -> propagate_cancelled exn
        | exn -> Error (boundary_error (Printexc.to_string exn)) in
      deliver_result result) in
    let not_run ~error detail = Fun.protect ~finally:(fun () -> retire_pending results token) (fun () ->
      on_not_run ();
      deliver_result (Error (error detail))) in
    match Eio_context.get_switch_opt () with
    | None -> not_run ~error:not_started_error "Eio switch is unavailable"
    | Some sw ->
      (match Eio.Switch.check sw with
       | () ->
         (match dispatch ~sw ~on_withdrawn:(fun () -> publish_cancelled ();retire_pending results token) run with
          | () -> ()
          | exception (Eio.Cancel.Cancelled _ as exn) ->
            Fun.protect ~finally:(fun () -> retire_pending results token) (fun () -> propagate_cancelled exn)
          | exception exn -> not_run ~error:boundary_error (Printexc.to_string exn))
       | exception (Eio.Cancel.Cancelled _ as exn) ->
         let backtrace=Printexc.get_raw_backtrace () in
         Fun.protect ~finally:(fun () -> retire_pending results token) (fun () ->
           (match cancellation with Propagate -> () | Publish_cancelled _ -> on_not_run ());
           publish_cancelled ();
           Printexc.raise_with_backtrace exn backtrace)
       | exception exn -> not_run ~error:boundary_error (Printexc.to_string exn))

let launch ?key ?(observation = false) ?observe_job ?(on_not_run = fun () -> ())
    state ~results ~boundary_error ~deliver perform =
  launch_registered ~cancellation:Propagate ~results ~on_not_run ~boundary_error ~not_started_error:boundary_error ~deliver
    ~dispatch:(fun ~sw ~on_withdrawn run ->
      Masc_tui_workspace_job.fork ?key ~observation ?observe:observe_job
        ~on_withdrawn state ~sw run) (fun _publish -> perform ())

let launch_session ~results ~boundary_error ~deliver perform =
  launch_registered ~cancellation:Propagate ~results ~on_not_run:(fun () -> ()) ~boundary_error ~not_started_error:boundary_error ~deliver
    ~dispatch:(fun ~sw ~on_withdrawn:_ run ->
      Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)) (fun _publish -> perform ())

let launch_observation ?key ?observe_job ?(on_not_run=fun () -> ())
    state ~results ~boundary_error ~not_started ~cancelled ~progress ~deliver perform =
  launch_registered ~cancellation:(Publish_cancelled cancelled) ~results ~on_not_run ~boundary_error ~not_started_error:not_started ~deliver
    ~dispatch:(fun ~sw ~on_withdrawn run ->
      Masc_tui_workspace_job.fork ?key ~observation:true ?observe:observe_job
        ~on_withdrawn:(fun () -> Fun.protect ~finally:on_withdrawn on_not_run)
        state ~sw run)
    (fun publish -> perform (fun part -> publish (progress part)))
