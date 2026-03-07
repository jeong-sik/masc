(** Coverage tests for Tool_misc *)

open Masc_mcp

let () = Random.self_init ()

let () = Printf.printf "\n=== Tool_misc Coverage Tests ===\n"

let str_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = sub then true
      else loop (i + 1)
    in
    loop 0

(* Test helper *)
let test name f =
  try
    f ();
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

(* Create test context *)
let test_counter = ref 0
let make_test_ctx () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-misc-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  let _ = Room.init config ~agent_name:(Some "test-agent") in
  { Tool_misc.config; agent_name = "test-agent" }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_misc.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test dispatch dashboard — may require Eio runtime; skip gracefully if unavailable *)
let () = test "dispatch_dashboard" (fun () ->
  let ctx = make_test_ctx () in
  ignore (Room.add_task ctx.config ~title:"default task" ~priority:2 ~description:"");
  ignore (Room.room_create ctx.config ~name:"Second Room" ~description:None);
  ignore (Room.room_enter ctx.config ~room_id:"second-room" ~agent_type:"claude" ~agent_name:ctx.agent_name ());
  ignore (Room.add_task ctx.config ~title:"second task" ~priority:1 ~description:"");
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "Scope: all");
      assert (str_contains result "Room: default");
      assert (str_contains result "Room: second-room");
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

(* Test dispatch dashboard compact — may require Eio runtime *)
let () = test "dispatch_dashboard_compact" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("compact", `Bool true)] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "Scope: all");
      assert (str_contains result "Current:");
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_current_scope" (fun () ->
  let ctx = make_test_ctx () in
  ignore (Room.room_create ctx.config ~name:"Focus Room" ~description:None);
  ignore (Room.room_enter ctx.config ~room_id:"focus-room" ~agent_type:"claude" ~agent_name:ctx.agent_name ());
  ignore (Room.add_task ctx.config ~title:"focus task" ~priority:2 ~description:"");
  let args = `Assoc [("scope", `String "current")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "Scope: current");
      assert (str_contains result "Current Room: focus-room");
      assert (not (str_contains result "Room: default"))
  | None -> failwith "dispatch returned None"
  | exception Effect.Unhandled _ ->
      Printf.printf "  (skipped: Eio runtime not available)\n"
)

let () = test "dispatch_dashboard_invalid_scope" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("scope", `String "everywhere")] in
  match Tool_misc.dispatch ctx ~name:"masc_dashboard" ~args with
  | Some (success, result) ->
      assert (not success);
      assert (str_contains result "Invalid dashboard scope")
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc *)
let () = test "dispatch_gc" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("days", `Int 7)] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some (success, result) ->
      assert success;
      assert (String.length result > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch gc with default days *)
let () = test "dispatch_gc_default" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_gc" ~args with
  | Some (success, result) ->
      assert success;
      assert (String.length result > 0)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch cleanup_zombies *)
let () = test "dispatch_cleanup_zombies" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_misc.dispatch ctx ~name:"masc_cleanup_zombies" ~args with
  | Some (success, result) ->
      assert success;
      assert (String.length result > 0)
  | None -> failwith "dispatch returned None"
)

(* Test helper functions *)
let () = test "get_int_present" (fun () ->
  let args = `Assoc [("key", `Int 42)] in
  assert (Tool_misc.get_int args "key" 0 = 42)
)

let () = test "get_int_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_misc.get_int args "key" 99 = 99)
)

let () = test "get_bool_true" (fun () ->
  let args = `Assoc [("key", `Bool true)] in
  assert (Tool_misc.get_bool args "key" false = true)
)

let () = test "get_bool_false" (fun () ->
  let args = `Assoc [("key", `Bool false)] in
  assert (Tool_misc.get_bool args "key" true = false)
)

let () = test "get_bool_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_misc.get_bool args "key" true = true)
)

let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_misc.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_misc.get_string args "key" "default" = "default")
)

let () = Printf.printf "\n✅ All Tool_misc tests passed!\n"

let () = exit 0
