(** Coverage tests for Tool_control *)

open Masc_mcp

let () = Random.self_init ()

let parse_json s =
  try Yojson.Safe.from_string s
  with Yojson.Json_error err -> failwith ("invalid json: " ^ err)

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
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      with_env "MASC_STORAGE_TYPE" None (fun () ->
        with_env "MASC_POSTGRES_URL" None (fun () ->
          with_env "DATABASE_URL" None (fun () ->
            with_env "SUPABASE_DB_URL" None (fun () ->
              with_env "SB_PG_URL" None f))))))

(* Test registry — each [test] call appends; final [let ()] dispatches
   via Alcotest.run. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () -> with_isolated_runtime_env f) :: !test_cases

let test_counter = ref 0

let with_ctx ?(initialize = true) f =
  Fun.protect
    ~finally:Fs_compat.clear_fs
    (fun () ->
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
      let config = Coord.default_config tmp in
      if initialize then ignore (Coord.init config ~agent_name:(Some "test-agent"));
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
          assert result.success;
          assert (String.length result.legacy_message > 0)
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_paused" (fun () ->
      with_ctx @@ fun ctx ->
      let _ =
        Tool_control.handle_pause ctx
          (`Assoc [ ("reason", `String "For status test") ])
      in
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert result.success;
          let json = parse_json result.legacy_message in
          assert (Yojson.Safe.Util.member "paused" json = `Bool true);
          assert (Yojson.Safe.Util.member "status" json = `String "paused")
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_resume" (fun () ->
      with_ctx @@ fun ctx ->
      let _ =
        Tool_control.handle_pause ctx
          (`Assoc [ ("reason", `String "For resume test") ])
      in
      match Tool_control.dispatch ctx ~name:"masc_resume" ~args:(`Assoc []) with
      | Some result ->
          assert result.success;
          assert (String.length result.legacy_message > 0)
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_running" (fun () ->
      with_ctx @@ fun ctx ->
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert result.success;
          let json = parse_json result.legacy_message in
          assert (Yojson.Safe.Util.member "paused" json = `Bool false);
          assert (Yojson.Safe.Util.member "status" json = `String "running")
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_ignores_legacy_namespace_hint" (fun () ->
      with_ctx @@ fun ctx ->
      match
        Tool_control.dispatch ctx ~name:"masc_pause_status"
          ~args:(`Assoc [ ("namespace_id", `String "focus-room") ])
      with
      | Some result ->
          assert result.success;
          let json = parse_json result.legacy_message in
          assert (Yojson.Safe.Util.member "namespace_id" json = `Null);
          assert (Yojson.Safe.Util.member "namespace" json = `Null);
          assert (Yojson.Safe.Util.member "requested_namespace_id" json = `Null)
      | None -> failwith "dispatch returned None")

let () =
  test "dispatch_pause_status_uninitialized_room_is_safe" (fun () ->
      with_ctx ~initialize:false @@ fun ctx ->
      match Tool_control.dispatch ctx ~name:"masc_pause_status" ~args:(`Assoc []) with
      | Some result ->
          assert result.success;
          let json = parse_json result.legacy_message in
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
