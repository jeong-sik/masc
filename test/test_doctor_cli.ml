open Alcotest

module DC = Masc_mcp.Doctor_cli

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec mkdir_p path =
  if path = "" || path = Filename.dirname path then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let test_sidecar_request_parse () =
  (match DC.sidecar_request_of_string "discord" with
   | Ok (DC.Named DC.Discord) -> ()
   | Ok _ -> fail "expected discord request"
   | Error msg -> fail msg);
  (match DC.sidecar_request_of_string "all" with
   | Ok DC.All -> ()
   | Ok _ -> fail "expected all request"
   | Error msg -> fail msg);
  (match DC.sidecar_request_of_string "unknown" with
   | Ok _ -> fail "expected parse error for unknown sidecar"
   | Error _ -> ())

let test_known_sidecars_covers_all () =
  let names = DC.sidecar_names () in
  check (list string) "known sidecars" [ "discord" ] names

let test_find_repo_root_from_cwd_ancestor () =
  let root = temp_dir "doctor_cli_repo_" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir root)
    (fun () ->
      let marker =
        Filename.concat root "sidecars/discord-bot/run.sh"
      in
      write_file marker "#!/usr/bin/env bash\n";
      let cwd = Filename.concat root "nested/deeper" in
      mkdir_p cwd;
      match
        DC.find_repo_root_with
          ~cwd
          ~exe_path:"/tmp/main_eio.exe"
          ~file_exists:Sys.file_exists
          ()
      with
      | Ok actual -> check string "repo root resolved from cwd" root actual
      | Error msg -> fail msg)

let test_find_repo_root_from_exe_path_fallback () =
  let root = temp_dir "doctor_cli_exe_repo_" in
  let unrelated = temp_dir "doctor_cli_unrelated_" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir root;
      cleanup_dir unrelated)
    (fun () ->
      let marker =
        Filename.concat root "sidecars/discord-bot/run.sh"
      in
      write_file marker "#!/usr/bin/env bash\n";
      let exe =
        Filename.concat root "_build/default/bin/main_eio.exe"
      in
      write_file exe "";
      match
        DC.find_repo_root_with
          ~cwd:unrelated
          ~exe_path:exe
          ~file_exists:Sys.file_exists
          ()
      with
      | Ok actual -> check string "repo root resolved from executable path" root actual
      | Error msg -> fail msg)

let test_sidecar_run_spec () =
  let spec =
    DC.sidecar_run_spec
      ~repo_root:"/repo"
      ~sidecar:DC.Discord
      ~json:true
      ~fix:true
  in
  check string "script path" "/repo/sidecars/discord-bot/run.sh"
    spec.script_path;
  check (list string) "argv"
    [ "/bin/bash"; "/repo/sidecars/discord-bot/run.sh"; "doctor"; "--json"; "--fix" ]
    spec.argv;
  check string "display sidecar" "discord" (DC.sidecar_name spec.sidecar)

let () =
  run "doctor_cli"
    [
      ("parse", [ test_case "sidecar request parse" `Quick test_sidecar_request_parse ]);
      ("coverage", [ test_case "known sidecars covers all" `Quick test_known_sidecars_covers_all ]);
      ( "repo_root",
        [
          test_case "find from cwd ancestor" `Quick
            test_find_repo_root_from_cwd_ancestor;
          test_case "find from executable fallback" `Quick
            test_find_repo_root_from_exe_path_fallback;
        ] );
      ("spec", [ test_case "sidecar run spec" `Quick test_sidecar_run_spec ]);
    ]
