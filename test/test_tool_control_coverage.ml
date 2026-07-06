(** Coverage tests for Tool_control *)

open Masc

let () = Random.self_init ()

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error err ->
    failwith ("invalid json: " ^ err ^ "; raw=" ^ s)

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let replace_path_with_file path content =
  if Sys.file_exists path
  then (
    if Sys.is_directory path then Unix.rmdir path else Sys.remove path);
  write_file path content

let seed_keeper_meta (ctx : Tool_control.context) name ~paused =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String name);
            ("agent_name", `String (Keeper_identity.keeper_agent_name name));
            ("trace_id", `String ("trace-" ^ name));
            ("goal", `String "pause status fixture");
          ])
    with
    | Ok meta -> { meta with paused }
    | Error err -> failwith ("meta fixture failed: " ^ err)
  in
  match Keeper_meta_store.write_meta ctx.config meta with
  | Ok () -> ()
  | Error err -> failwith ("meta write failed: " ^ err)

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.putenv name "");
      f ())

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None f)

(* Test registry — each [test] call appends; final [let ()] dispatches
   via Alcotest.run. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () -> with_isolated_runtime_env f) :: !test_cases

let test_counter = ref 0

let with_ctx ?(initialize = true) f =
  Fun.protect
    ~finally:(fun () ->
      Workspace.invalidate_initialized_cache ();
      Fs_compat.clear_fs ())
    (fun () ->
      Workspace.invalidate_initialized_cache ();
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      incr test_counter;
      let tmp =
        Filename.concat (Filename.get_temp_dir_name ())
          (Printf.sprintf "masc-control-test-%d-%d"
             (int_of_float (Unix.gettimeofday () *. 1000.0))
             !test_counter)
      in
      Unix.mkdir tmp 0o755;
      let config = Workspace.default_config tmp in
      if initialize then ignore (Workspace.init config ~agent_name:(Some "test-agent"));
      f { Tool_control.config; agent_name = "test-agent" })

let () =
  test "dispatch_unknown_tool" (fun () ->
      with_ctx @@ fun ctx ->
      assert (Tool_control.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) = None))

let () =
  test "dispatch_pause" (fun () ->
      with_ctx @@ fun ctx ->
      match
        Tool_control.dispatch ctx ~name:"masc_pause"
          ~args:(`Assoc [ ("reason", `String "Test pause") ])
      with
      | Some result ->
          assert (Tool_result.is_success result);
          assert (String.length (Tool_result.message result) > 0)
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_paused" (fun () ->
      with_ctx @@ fun ctx ->
      let _ =
        Tool_control.handle_pause ~tool_name:"test" ~start_time:0.0 ctx
          (`Assoc [ ("reason", `String "For status test") ])
      in
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          assert (Yojson.Safe.Util.member "paused" json = `Bool true);
          assert (Yojson.Safe.Util.member "status" json = `String "paused")
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_resume" (fun () ->
      with_ctx @@ fun ctx ->
      let _ =
        Tool_control.handle_pause ~tool_name:"test" ~start_time:0.0 ctx
          (`Assoc [ ("reason", `String "For resume test") ])
      in
      match Tool_control.dispatch ctx ~name:"masc_resume" ~args:(`Assoc []) with
      | Some result ->
          assert (Tool_result.is_success result);
          assert (String.length (Tool_result.message result) > 0)
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_running" (fun () ->
      with_ctx @@ fun ctx ->
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          assert (Yojson.Safe.Util.member "paused" json = `Bool false);
          assert (Yojson.Safe.Util.member "status" json = `String "running")
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_reports_state_read_failure" (fun () ->
      with_ctx @@ fun ctx ->
      let state_path = Workspace.state_path ctx.config in
      Unix.unlink state_path;
      Unix.mkdir state_path 0o755;
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert (not (Tool_result.is_success result));
          assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
          assert
            (String.starts_with
               ~prefix:"Pause status failed: workspace_state read failed:"
               (Tool_result.message result))
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_surfaces_keeper_pause_when_workspace_running" (fun () ->
      with_ctx @@ fun ctx ->
      seed_keeper_meta ctx "paused-keeper" ~paused:true;
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          let open Yojson.Safe.Util in
          let keeper_pause = json |> member "keeper_pause" in
          assert (json |> member "status" = `String "running");
          assert (json |> member "paused" = `Bool false);
          assert (json |> member "any_pause_active" = `Bool true);
          assert (keeper_pause |> member "paused" = `Bool true);
          assert (keeper_pause |> member "paused_count" = `Int 1);
          assert
            (keeper_pause |> member "paused_names" |> to_list
             |> List.map to_string
            = [ "paused-keeper" ])
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_surfaces_keeper_name_discovery_failure" (fun () ->
      with_ctx @@ fun ctx ->
      replace_path_with_file
        (Keeper_types_profile.keeper_dir ctx.config)
        "not a keeper directory";
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          let open Yojson.Safe.Util in
          let keeper_pause = json |> member "keeper_pause" in
          assert (keeper_pause |> member "paused" = `Bool false);
          assert (keeper_pause |> member "keeper_names_known" = `Bool false);
          assert
            (keeper_pause |> member "keeper_name_discovery_read_error_count"
             = `Int 1);
          let read_errors = keeper_pause |> member "read_errors" |> to_list in
          assert (List.length read_errors = 1);
          (match read_errors with
           | [ error ] ->
               assert
                 (error |> member "source" |> to_string
                  = "keeper_names_result");
               assert
                 (contains_substring
                    (error |> member "error" |> to_string)
                    "keepers")
           | _ -> failwith "expected one keeper discovery read error")
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_ignores_legacy_namespace_hint" (fun () ->
      with_ctx @@ fun ctx ->
      match
        Tool_control.dispatch ctx ~name:"masc_pause_status"
          ~args:(`Assoc [ ("namespace_id", `String "focus-workspace") ])
      with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          assert (Yojson.Safe.Util.member "namespace_id" json = `Null);
          assert (Yojson.Safe.Util.member "namespace" json = `Null);
          assert (Yojson.Safe.Util.member "requested_namespace_id" json = `Null)
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_uninitialized_workspace_is_safe" (fun () ->
      with_ctx ~initialize:false @@ fun ctx ->
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert (Tool_result.is_success result);
          let json = parse_json (Tool_result.message result) in
          assert (Yojson.Safe.Util.member "status" json = `String "initializing");
          assert (Yojson.Safe.Util.member "initializing" json = `Bool true);
          assert (Yojson.Safe.Util.member "paused" json = `Null)
      | None -> failwith "dispatch returned None")

let () =
  test "removed_mode_tools_do_not_dispatch" (fun () ->
      with_ctx @@ fun ctx ->
      let args = `Assoc [] in
      assert (Tool_control.dispatch ctx ~name:"masc_switch_mode" ~args = None);
      assert (Tool_control.dispatch ctx ~name:"masc_get_config" ~args = None);
      assert (Tool_control.dispatch ctx ~name:"masc_tool_enable" ~args = None);
      assert (Tool_control.dispatch ctx ~name:"masc_tool_disable" ~args = None))

let () =
  test "get_string_present" (fun () ->
      let args = `Assoc [ ("key", `String "value") ] in
      assert (Tool_args.get_string args "key" "default" = "value"))

let () =
  test "get_string_missing" (fun () ->
      let args = `Assoc [] in
      assert (Tool_args.get_string args "key" "default" = "default"))

let () =
  Alcotest.run "Tool_control"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
