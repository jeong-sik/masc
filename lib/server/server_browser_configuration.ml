let install_activity_observer ~sw =
  let observe lane =
    match Runtime.browser_configuration () with
    | None -> Browser_lane.Unobserved
    | Some config ->
      let enabled = match lane with
        | Browser_lane.Lane_name.Live -> config.Browser_configuration.live_enabled
        | Automation -> config.automation_enabled
        | Stagehand -> config.stagehand_enabled
      in
      if enabled then Browser_lane.Enabled else Browser_lane.Disabled
  in
  Browser_lane.install_activity_observer (Some observe);
  Eio.Switch.on_release sw (fun () -> Browser_lane.install_activity_observer None)
