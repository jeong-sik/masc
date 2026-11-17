module Setup = Masc.Exact_addon_setup

let failed_package_exit = 1
let refused_exit = 2
let docker_command = "docker"

let run ~base_path ~declared =
  let scope = if declared then Setup.Declared else Setup.Every_carried in
  match Setup.run ~base_path ~docker:docker_command ~scope with
  | Error error ->
    prerr_endline ("masc exact-addon-setup: " ^ Setup.error_message error);
    refused_exit
  | Ok { Setup.reports; unread } ->
    List.iter (fun issue -> prerr_endline ("masc exact-addon-setup: " ^ Setup.unread_line issue)) unread;
    List.iter (fun (report : Setup.report) ->
        match report.result with
        | Ok _ -> print_endline (Setup.report_line report)
        | Error _ -> prerr_endline (Setup.report_line report))
      reports;
    if List.for_all (fun (report : Setup.report) -> Result.is_ok report.result) reports then 0
    else failed_package_exit
