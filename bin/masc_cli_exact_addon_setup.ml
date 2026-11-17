module Setup = Masc.Exact_addon_setup

let failed_package_exit = 1
let refused_exit = 2
let docker_command = "docker"

let run ~base_path =
  match Setup.run ~base_path ~docker:docker_command with
  | Error error ->
    prerr_endline ("masc exact-addon-setup: " ^ Setup.error_message error);
    refused_exit
  | Ok reports ->
    List.iter (fun (report : Setup.report) ->
        match report.result with
        | Ok _ -> print_endline (Setup.report_line report)
        | Error _ -> prerr_endline (Setup.report_line report))
      reports;
    if List.for_all (fun (report : Setup.report) -> Result.is_ok report.result) reports then 0
    else failed_package_exit
