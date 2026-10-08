let install_activity_observers ~sw =
  let observe enabled () =
    match Runtime.machine_configuration () with
    | None -> Machine_configuration.Unobserved
    | Some config -> if enabled config then Machine_configuration.Enabled else Disabled
  in
  Msx_lane.install_activity_observer (Some (observe (fun c -> c.Machine_configuration.msx_enabled)));
  Dos_lane.install_activity_observer (Some (observe (fun c -> c.Machine_configuration.dos_enabled)));
  Eio.Switch.on_release sw (fun () ->
    Msx_lane.install_activity_observer None;
    Dos_lane.install_activity_observer None)
