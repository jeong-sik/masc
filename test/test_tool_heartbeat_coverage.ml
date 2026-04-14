(** Coverage tests for Tool_heartbeat *)

open Masc_mcp

let () = Random.self_init ()

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

(* Test registry — collected by the [test] helper and dispatched via
   Alcotest.run at the bottom of the file.  We register rather than
   execute so Alcotest controls the run order, reporting, and exit code. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () -> with_isolated_runtime_env f) :: !test_cases

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  needle_len = 0 || loop 0

let with_tool_ctx suffix f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let tmp =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-hb-%s-%d" suffix
         (int_of_float (Unix.gettimeofday () *. 1000000.0)))
  in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  ignore (Room.init config ~agent_name:(Some "test"));
  let ctx =
    {
      Tool_heartbeat.config;
      agent_name = "test";
      sw;
      clock = Eio.Stdenv.clock env;
    }
  in
  Fun.protect
    ~finally:(fun () -> ignore (Heartbeat.stop_by_agent ~agent_name:"test"))
    (fun () -> f ctx)

(* Heartbeat module tests (extracted from mcp_server_eio) *)
let () = test "heartbeat_generate_id" (fun () ->
  let id1 = Heartbeat.generate_id () in
  let id2 = Heartbeat.generate_id () in
  assert (id1 <> id2);
  assert (String.sub id1 0 3 = "hb-")
)

let () = test "heartbeat_start_stop" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let hb_id = Heartbeat.start ~agent_name:"test" ~interval:30 ~message:"ping" in
  assert (String.length hb_id > 0);

  (* Should be in the list *)
  let hbs = Heartbeat.list () in
  assert (List.exists (fun hb -> hb.Heartbeat.id = hb_id) hbs);

  (* Stop it *)
  assert (Heartbeat.stop hb_id = true);

  (* Should not be in the list anymore *)
  let hbs2 = Heartbeat.list () in
  assert (not (List.exists (fun hb -> hb.Heartbeat.id = hb_id) hbs2));

  (* Stopping again should fail *)
  assert (Heartbeat.stop hb_id = false)
)

let () = test "heartbeat_get" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let hb_id = Heartbeat.start ~agent_name:"getter" ~interval:60 ~message:"test" in

  match Heartbeat.get hb_id with
  | Some hb ->
      assert (hb.Heartbeat.agent_name = "getter");
      assert (hb.Heartbeat.interval = 60);
      assert (hb.Heartbeat.message = "test");
      assert hb.Heartbeat.active;
      ignore (Heartbeat.stop hb_id)
  | None -> failwith "heartbeat not found"
)

let () = test "heartbeat_get_missing" (fun () ->
  assert (Heartbeat.get "nonexistent-id" = None)
)

let () = test "heartbeat_list_multiple" (fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let id1 = Heartbeat.start ~agent_name:"a1" ~interval:10 ~message:"m1" in
  let id2 = Heartbeat.start ~agent_name:"a2" ~interval:20 ~message:"m2" in

  let hbs = Heartbeat.list () in
  assert (List.length hbs >= 2);

  ignore (Heartbeat.stop id1);
  ignore (Heartbeat.stop id2)
)

(* Tool_heartbeat tests *)
let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_args.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_string args "key" "default" = "default")
)

let () = test "get_int_present" (fun () ->
  let args = `Assoc [("key", `Int 42)] in
  assert (Tool_args.get_int args "key" 0 = 42)
)

let () = test "get_int_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_int args "key" 99 = 99)
)

let () = test "dispatch_unknown_tool" (fun () ->
  with_tool_ctx "dispatch-unknown" (fun ctx ->
      let args = `Assoc [] in
      assert (Tool_heartbeat.dispatch ctx ~name:"unknown_tool" ~args = None))
)

let () = test "dispatch_heartbeat_list" (fun () ->
  with_tool_ctx "dispatch-list" (fun ctx ->
      let args = `Assoc [] in
      match Tool_heartbeat.dispatch ctx ~name:"masc_heartbeat_list" ~args with
      | Some (success, _result) -> assert success
      | None -> failwith "dispatch returned None")
)

let () = test "handle_heartbeat_start_clamps_interval_and_marks_smart" (fun () ->
  with_tool_ctx "start-smart" (fun ctx ->
      let args =
        `Assoc
          [
            ("interval", `Int 1);
            ("message", `String "ping");
            ("smart", `Bool true);
          ]
      in
      let (success, result) = Tool_heartbeat.handle_heartbeat_start ctx args in
      assert success;
      assert (contains_substring result "interval: 5s");
      assert (contains_substring result "[SMART]");
      let heartbeats = Heartbeat.list () in
      let hb =
        match
          List.find_opt
            (fun hb ->
              hb.Heartbeat.agent_name = "test" && hb.message = "ping")
            heartbeats
        with
        | Some hb -> hb
        | None -> failwith "heartbeat not registered"
      in
      assert (hb.interval = 5))
)

let () = test "handle_heartbeat_stop_missing_id" (fun () ->
  with_tool_ctx "stop-missing" (fun ctx ->
      let args = `Assoc [] in
      let (success, result) = Tool_heartbeat.handle_heartbeat_stop ctx args in
      assert (not success);
      assert (String.length result > 0))
)

let () = test "handle_heartbeat_stop_not_found" (fun () ->
  with_tool_ctx "stop-not-found" (fun ctx ->
      let args = `Assoc [("heartbeat_id", `String "nonexistent")] in
      let (success, result) = Tool_heartbeat.handle_heartbeat_stop ctx args in
      assert (not success);
      assert (String.length result > 0 (* contains emoji *)))
)

let () =
  Alcotest.run "Tool_heartbeat"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
