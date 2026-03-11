open Alcotest

module Dashboard_mission_briefing = Masc_mcp.Dashboard_mission_briefing
module Room = Masc_mcp.Room

let temp_dir () =
  let dir = Filename.temp_file "test_dashboard_mission_briefing_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path
        |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  rm dir

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let test_disabled_override_returns_unavailable () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let config = Room.default_config base_path in
      ignore (Room.init config ~agent_name:None);
      with_env "MASC_DASHBOARD_BRIEFING_MODELS" "disabled" (fun () ->
        let json =
          Dashboard_mission_briefing.json
            ~config ~sw ~clock ~proc_mgr:None ()
        in
        let open Yojson.Safe.Util in
        check string "status" "unavailable"
          (json |> member "status" |> to_string);
        check bool "refreshing false" false
          (json |> member "refreshing" |> to_bool);
        check string "error reason"
          "No dashboard briefing model is available in the current environment."
          (json |> member "error" |> to_string)))

let () =
  run "Dashboard Mission Briefing"
    [
      ( "env override",
        [
          test_case "disabled override returns unavailable" `Quick
            test_disabled_override_returns_unavailable;
        ] );
    ]
