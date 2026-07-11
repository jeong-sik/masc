(** Coverage tests for Tool_control *)

open Masc

let () = Random.self_init ()

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error err ->
    failwith ("invalid json: " ^ err ^ "; raw=" ^ s)

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
  test "control_schema_projection_registers_without_front_door_exposure" (fun () ->
      let raw_names =
        List.map
          (fun (schema : Masc_domain.tool_schema) -> schema.name)
          Config.raw_all_tool_schemas
      in
      let public_names = Config.all_tool_names () in
      List.iter
        (fun operation ->
           let schema = Tool_schemas_misc.control_schema operation in
           (match Tool_dispatch.lookup_tag schema.name with
            | Some Tool_dispatch.Mod_control -> ()
            | Some _ ->
              Alcotest.failf "%s registered with the wrong module tag" schema.name
            | None -> Alcotest.failf "%s is not registered" schema.name);
           (match Tool_dispatch.lookup_schema schema.name with
            | Some registered ->
              Alcotest.(check bool)
                (schema.name ^ " registration keeps canonical input schema")
                true
                (Yojson.Safe.equal schema.input_schema registered)
            | None -> Alcotest.failf "%s has no registered input schema" schema.name);
           Alcotest.(check bool)
             (schema.name ^ " stays out of Config.raw_all_tool_schemas")
             false
             (List.mem schema.name raw_names);
           Alcotest.(check bool)
             (schema.name ^ " stays out of Config.all_tool_names")
             false
             (List.mem schema.name public_names))
        Tool_schemas_misc.control_operations)

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
