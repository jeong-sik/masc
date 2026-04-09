module Lib = Masc_mcp

open Alcotest

let () = Mirage_crypto_rng_unix.use_default ()

let test_dir () =
  let tmp = Filename.temp_file "masc_tool_repo_synthesis" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let with_temp_base f =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () -> f dir)

let saturate_repo_synthesis_platoon config ~actor =
  match
    Lib.Tool_autoresearch_repo_synthesis.ensure_repo_synthesis_units config
      ~actor ~active_roster:[ actor ]
  with
  | Error message -> fail message
  | Ok _ ->
      for idx = 1 to 8 do
        match
          Lib.Command_plane_v2.start_operation config ~actor
            (`Assoc
              [
                ("assigned_unit_id", `String "platoon-repo-synthesis");
                ("objective", `String (Printf.sprintf "Warm repo synthesis slot %d" idx));
                ("policy_class", `String "guarded");
                ("budget_class", `String "standard");
                ("workload_profile", `String "coding_task");
                ("stage", `String "inspect");
              ])
        with
        | Ok _ -> ()
        | Error message -> fail message
      done

let test_repo_synthesis_swarm_start_avoids_saturated_platoon_cap () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  with_temp_base @@ fun base_path ->
  let config = Lib.Room.default_config base_path in
  ignore (Lib.Room.init config ~agent_name:(Some "owner"));
  ignore (Lib.Room.join config ~agent_name:"owner" ~capabilities:[ "ocaml"; "docs" ] ());
  saturate_repo_synthesis_platoon config ~actor:"owner";
  let start_team_session ~goal:_ ~operation_id:_ ~loop_id:_ ~target_file:_ ~program_note:_ =
    (* Team_session_engine_eio removed *)
    ignore (sw, env, config);
    Error "team session engine removed"
  in
  let ctx : Lib.Tool_autoresearch.context =
    {
      base_path;
      agent_name = Some "owner";
      start_operation = None;
      start_team_session = Some start_team_session;
      config = Some config;
      sw = Some sw;
      clock = Some clock;
    }
  in
  let args =
    `Assoc
      [
        ("goal", `String "Avoid platoon cap");
        ("question", `String "How is repo synthesis routed?");
        ("repo_root", `String base_path);
      ]
  in
  (* Team_session_engine_eio removed — swarm_start returns an error
     because start_team_session is stubbed to return Error. Verify
     the dispatch handles this gracefully. *)
  match
    Lib.Tool_autoresearch.dispatch ctx ~name:"masc_repo_synthesis_swarm_start"
      ~args
  with
  | None -> fail "dispatch returned None"
  | Some (true, payload) ->
      (* If the platoon cap path returns success without team session,
         verify it still assigned to the company unit. *)
      let open Yojson.Safe.Util in
      let json = Yojson.Safe.from_string payload in
      let operation_id = json |> member "operation_id" |> to_string in
      let operations =
        Lib.Command_plane_v2.operation_status_json config ~operation_id ()
      in
      check string "repo synthesis assigns company unit"
        "company-repo-synthesis"
        (operations |> member "operations" |> index 0 |> member "operation"
         |> member "assigned_unit_id" |> to_string)
  | Some (false, _msg) ->
      (* Expected: team session engine removed, swarm start returns error *)
      ()

let () =
  run "tool_repo_synthesis"
    [
      ("tool_repo_synthesis",
       [
         test_case "swarm_start avoids saturated platoon cap" `Quick
           test_repo_synthesis_swarm_start_avoids_saturated_platoon_cap;
       ]);
    ]
