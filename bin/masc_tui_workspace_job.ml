type event = Cancellation_requested | Registration_released
let fork ?(observation = false) ?(key = ref ()) ?(on_withdrawn = fun () -> ()) ?(observe = fun _ -> ())
    (state : Masc_tui_types.state) ~sw run =
  let exception Workspace_withdrawn in
  let authority = state.workspace_authority in
  let context = ref None in
  let withdrawn = ref false in
  let token = key in
  let cancel () =
    withdrawn := true;
    Fun.protect
      ~finally:(fun () -> Option.iter (fun context -> Eio.Cancel.cancel context Workspace_withdrawn) !context)
      (fun () -> observe Cancellation_requested)
  in
  state.workspace_cancellations <- (token, cancel) :: state.workspace_cancellations;
  if observation then
    state.workspace_observation_cancellations <-
      (token, cancel) :: state.workspace_observation_cancellations;
  match Eio.Fiber.fork_daemon ~sw (fun () ->
    Fun.protect
      ~finally:(fun () ->
        context := None;
        state.workspace_cancellations <-
          List.filter (fun (held, _) -> held != token) state.workspace_cancellations;
        state.workspace_observation_cancellations <-
          List.filter (fun (held, _) -> held != token) state.workspace_observation_cancellations;
        observe Registration_released)
      (fun () ->
        try
          Eio.Cancel.sub (fun cancellation ->
            context := Some cancellation;
            if not !withdrawn && authority = state.workspace_authority then run ()
            else on_withdrawn ())
        with Eio.Cancel.Cancelled Workspace_withdrawn -> ());
    `Stop_daemon) with
  | () -> ()
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    state.workspace_cancellations <-
      List.filter (fun (held, _) -> held != token) state.workspace_cancellations;
    state.workspace_observation_cancellations <-
      List.filter (fun (held, _) -> held != token) state.workspace_observation_cancellations;
    observe Registration_released;
    Printexc.raise_with_backtrace exn backtrace


let cancel_observation (state : Masc_tui_types.state) ~key =
  match List.find_opt (fun (token, _) -> token == key)
      state.workspace_observation_cancellations with
  | None -> ()
  | Some (_, cancel) -> cancel ()
