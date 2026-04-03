(** Tool_suspend Module Coverage Tests

    Tests for MASC Suspension & Circuit Breaker tools:
    - get_string / get_string_opt / get_float: argument parsing helpers
    - Blacklist CRUD: add / check (with auto-expiry) / remove
    - dispatch: routing "masc_suspend"
    - handle_suspend: validation, blacklist, circuit breaker, audit
    - handle_circuit_status: status query, blacklist info
    - check_can_join: combined blacklist + circuit breaker gate

    @since 2.76.0
*)
module Tool_args = Masc_mcp.Tool_args

open Alcotest

module Tool_suspend = Masc_mcp.Tool_suspend
module Room = Masc_mcp.Room

(* ============================================================
   Test Helpers
   ============================================================ *)

(** Create a temporary Room.config for isolated tests.
    Must create directory + .masc/ subdirectory for Room operations. *)
let make_config () =
  let tmp = Printf.sprintf "/tmp/test-suspend-%d" (Random.bits ()) in
  (try Unix.mkdir tmp 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir (Filename.concat tmp ".masc") 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Room.default_config tmp

(** Create a Tool_suspend.context with optional caller *)
let make_ctx ?caller () : Tool_suspend.context =
  let config = make_config () in
  { config; caller_agent = caller }

(** Clean up blacklist state between tests.
    Since blacklist is a global Hashtbl, we must remove test entries
    to prevent cross-test contamination. *)
let cleanup_blacklist agent_id =
  Tool_suspend.remove_from_blacklist ~agent_id

(* ============================================================
   get_string Tests
   ============================================================ *)

let test_get_string_exists () =
  let args = `Assoc [("target_agent", `String "agent-1")] in
  check string "extracts string" "agent-1"
    (Tool_args.get_string args "target_agent" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  check string "uses default" "default"
    (Tool_args.get_string args "target_agent" "default")

let test_get_string_wrong_type () =
  let args = `Assoc [("target_agent", `Int 42)] in
  check string "uses default on type mismatch" "default"
    (Tool_args.get_string args "target_agent" "default")

let test_get_string_non_assoc () =
  let args = `List [`String "a"] in
  check string "uses default on non-assoc" "default"
    (Tool_args.get_string args "target_agent" "default")

(* ============================================================
   get_string_opt Tests
   ============================================================ *)

let test_get_string_opt_exists () =
  let args = `Assoc [("agent_id", `String "agent-1")] in
  check (option string) "returns Some" (Some "agent-1")
    (Tool_args.get_string_opt args "agent_id")

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  check (option string) "returns None" None
    (Tool_args.get_string_opt args "agent_id")

let test_get_string_opt_empty_string () =
  let args = `Assoc [("agent_id", `String "")] in
  check (option string) "empty string returns None" None
    (Tool_args.get_string_opt args "agent_id")

let test_get_string_opt_wrong_type () =
  let args = `Assoc [("agent_id", `Int 42)] in
  check (option string) "wrong type returns None" None
    (Tool_args.get_string_opt args "agent_id")

let test_get_string_opt_non_assoc () =
  let args = `Null in
  check (option string) "non-assoc returns None" None
    (Tool_args.get_string_opt args "agent_id")

(* ============================================================
   get_float Tests
   ============================================================ *)

let test_get_float_from_float () =
  let args = `Assoc [("duration", `Float 2.5)] in
  check (float 0.001) "extracts float" 2.5
    (Tool_args.get_float args "duration" 1.0)

let test_get_float_from_int () =
  let args = `Assoc [("duration", `Int 3)] in
  check (float 0.001) "converts int to float" 3.0
    (Tool_args.get_float args "duration" 1.0)

let test_get_float_missing () =
  let args = `Assoc [] in
  check (float 0.001) "uses default" 1.0
    (Tool_args.get_float args "duration" 1.0)

let test_get_float_wrong_type () =
  let args = `Assoc [("duration", `String "2.5")] in
  check (float 0.001) "uses default on string" 1.0
    (Tool_args.get_float args "duration" 1.0)

let test_get_float_non_assoc () =
  let args = `Bool true in
  check (float 0.001) "uses default on non-assoc" 1.0
    (Tool_args.get_float args "duration" 1.0)

(* ============================================================
   Blacklist Management Tests
   ============================================================ *)

let test_blacklist_add_and_check () =
  let agent_id = "bl-test-add-check" in
  let until = Time_compat.now () +. 3600.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until ~reason:"test";
  (match Tool_suspend.check_blacklist ~agent_id with
   | Some (_until, reason) ->
       check string "reason matches" "test" reason
   | None ->
       fail "expected blacklist entry");
  cleanup_blacklist agent_id

let test_blacklist_auto_expiry () =
  let agent_id = "bl-test-expiry" in
  (* Set expiry in the past *)
  let until = Time_compat.now () -. 1.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until ~reason:"expired";
  (match Tool_suspend.check_blacklist ~agent_id with
   | None -> ()  (* auto-removed *)
   | Some _ -> fail "expected expired entry to be auto-removed");
  cleanup_blacklist agent_id

let test_blacklist_remove () =
  let agent_id = "bl-test-remove" in
  let until = Time_compat.now () +. 3600.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until ~reason:"test";
  Tool_suspend.remove_from_blacklist ~agent_id;
  check (option (pair (float 0.1) string)) "removed" None
    (Tool_suspend.check_blacklist ~agent_id)

let test_blacklist_check_nonexistent () =
  check (option (pair (float 0.1) string)) "nonexistent returns None" None
    (Tool_suspend.check_blacklist ~agent_id:"bl-nonexistent-agent")

let test_blacklist_replace () =
  let agent_id = "bl-test-replace" in
  let until1 = Time_compat.now () +. 3600.0 in
  let until2 = Time_compat.now () +. 7200.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until:until1 ~reason:"first";
  Tool_suspend.add_to_blacklist ~agent_id ~until:until2 ~reason:"second";
  (match Tool_suspend.check_blacklist ~agent_id with
   | Some (_until, reason) ->
       check string "replaced with second" "second" reason
   | None ->
       fail "expected blacklist entry");
  cleanup_blacklist agent_id

(* ============================================================
   Dispatch Tests
   ============================================================ *)

let test_dispatch_suspend () =
  let ctx = make_ctx ~caller:"admin" () in
  let args = `Assoc [
    ("target_agent", `String "bad-agent");
    ("reason", `String "testing");
    ("duration_hours", `Float 0.001);
  ] in
  match Tool_suspend.dispatch ctx ~name:"masc_suspend" ~args with
  | Some (_success, msg) ->
      check bool "returns response" true (String.length msg > 0)
  | None ->
      fail "expected Some for masc_suspend"

let test_dispatch_unknown () =
  let ctx = make_ctx () in
  let args = `Assoc [] in
  check (option (pair bool string)) "unknown tool returns None" None
    (Tool_suspend.dispatch ctx ~name:"masc_unknown" ~args)

(* ============================================================
   handle_suspend Tests
   ============================================================ *)

let test_handle_suspend_empty_target () =
  let ctx = make_ctx ~caller:"admin" () in
  let args = `Assoc [("target_agent", `String "")] in
  let (success, msg) = Tool_suspend.handle_suspend ctx args in
  check bool "fails" false success;
  check bool "error message" true (String.length msg > 0)

let test_handle_suspend_missing_target () =
  let ctx = make_ctx ~caller:"admin" () in
  let args = `Assoc [] in
  let (success, msg) = Tool_suspend.handle_suspend ctx args in
  check bool "fails" false success;
  check string "requires target" "target_agent is required" msg

let test_handle_suspend_valid () =
  let agent_id = "suspend-test-valid" in
  let ctx = make_ctx ~caller:"admin" () in
  let args = `Assoc [
    ("target_agent", `String agent_id);
    ("reason", `String "test suspension");
    ("duration_hours", `Float 0.001);
  ] in
  let (success, msg) = Tool_suspend.handle_suspend ctx args in
  check bool "succeeds" true success;
  (* Verify JSON response *)
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       check bool "has success" true
         (List.assoc_opt "success" fields = Some (`Bool true));
       check bool "has target_agent" true
         (List.assoc_opt "target_agent" fields = Some (`String agent_id));
       check bool "has reason" true
         (List.assoc_opt "reason" fields = Some (`String "test suspension"))
   | _ -> fail "expected JSON assoc");
  cleanup_blacklist agent_id;
  (* Also clean up circuit breaker *)
  Circuit_breaker.force_close_global ~agent_id

let test_handle_suspend_self () =
  let agent_id = "suspend-self-test" in
  let ctx = make_ctx ~caller:agent_id () in
  let args = `Assoc [
    ("target_agent", `String agent_id);
    ("reason", `String "self test");
    ("duration_hours", `Float 0.001);
  ] in
  let (success, msg) = Tool_suspend.handle_suspend ctx args in
  check bool "self-suspend allowed" true success;
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       check bool "is_self_suspend true" true
         (List.assoc_opt "is_self_suspend" fields = Some (`Bool true))
   | _ -> fail "expected JSON assoc");
  cleanup_blacklist agent_id;
  Circuit_breaker.force_close_global ~agent_id

let test_handle_suspend_default_reason () =
  let agent_id = "suspend-default-reason" in
  let ctx = make_ctx ~caller:"admin" () in
  let args = `Assoc [
    ("target_agent", `String agent_id);
  ] in
  let (success, msg) = Tool_suspend.handle_suspend ctx args in
  check bool "succeeds" true success;
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       check bool "default reason" true
         (List.assoc_opt "reason" fields = Some (`String "No reason provided"))
   | _ -> fail "expected JSON assoc");
  cleanup_blacklist agent_id;
  Circuit_breaker.force_close_global ~agent_id

(* ============================================================
   handle_circuit_status Tests
   ============================================================ *)

let test_circuit_status_with_agent_id () =
  let ctx = make_ctx ~caller:"viewer" () in
  let args = `Assoc [("agent_id", `String "check-agent")] in
  let (success, msg) = Tool_suspend.handle_circuit_status ctx args in
  check bool "succeeds" true success;
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       check bool "has agent_id" true
         (List.assoc_opt "agent_id" fields = Some (`String "check-agent"));
       check bool "has circuit_breaker" true
         (List.assoc_opt "circuit_breaker" fields <> None);
       check bool "has blacklist" true
         (List.assoc_opt "blacklist" fields <> None)
   | _ -> fail "expected JSON assoc")

let test_circuit_status_default_agent () =
  let ctx = make_ctx ~caller:"my-agent" () in
  let args = `Assoc [] in
  let (success, msg) = Tool_suspend.handle_circuit_status ctx args in
  check bool "succeeds" true success;
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       (* Should default to caller_agent *)
       check bool "defaults to caller" true
         (List.assoc_opt "agent_id" fields = Some (`String "my-agent"))
   | _ -> fail "expected JSON assoc")

let test_circuit_status_no_caller () =
  let ctx = make_ctx () in
  let args = `Assoc [] in
  let (success, msg) = Tool_suspend.handle_circuit_status ctx args in
  check bool "succeeds" true success;
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       check bool "defaults to unknown" true
         (List.assoc_opt "agent_id" fields = Some (`String "unknown"))
   | _ -> fail "expected JSON assoc")

let test_circuit_status_blacklisted_agent () =
  let agent_id = "blacklisted-for-status" in
  let until = Time_compat.now () +. 3600.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until ~reason:"status test";
  let ctx = make_ctx ~caller:"viewer" () in
  let args = `Assoc [("agent_id", `String agent_id)] in
  let (success, msg) = Tool_suspend.handle_circuit_status ctx args in
  check bool "succeeds" true success;
  let json = Yojson.Safe.from_string msg in
  (match json with
   | `Assoc fields ->
       (match List.assoc_opt "blacklist" fields with
        | Some (`Assoc bl_fields) ->
            check bool "blacklisted true" true
              (List.assoc_opt "blacklisted" bl_fields = Some (`Bool true));
            check bool "has remaining_seconds" true
              (List.assoc_opt "remaining_seconds" bl_fields <> None)
        | _ -> fail "expected blacklist assoc")
   | _ -> fail "expected JSON assoc");
  cleanup_blacklist agent_id

(* ============================================================
   check_can_join Tests
   ============================================================ *)

let test_check_can_join_clean () =
  match Tool_suspend.check_can_join ~agent_id:"clean-agent" with
  | Ok () -> ()
  | Error msg -> fail (Printf.sprintf "expected Ok, got Error: %s" msg)

let test_check_can_join_blacklisted () =
  let agent_id = "join-blacklisted" in
  let until = Time_compat.now () +. 3600.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until ~reason:"blocked";
  (match Tool_suspend.check_can_join ~agent_id with
   | Error msg ->
       check bool "mentions suspended" true
         (String.length msg > 0)
   | Ok () ->
       fail "expected Error for blacklisted agent");
  cleanup_blacklist agent_id

let test_check_can_join_expired_blacklist () =
  let agent_id = "join-expired" in
  let until = Time_compat.now () -. 1.0 in
  Tool_suspend.add_to_blacklist ~agent_id ~until ~reason:"old";
  (* Expired entry should auto-clean and allow join *)
  (match Tool_suspend.check_can_join ~agent_id with
   | Ok () -> ()
   | Error msg ->
       fail (Printf.sprintf "expected Ok for expired, got: %s" msg));
  cleanup_blacklist agent_id

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Random.self_init ();
  run "Tool_suspend Coverage" [
    "get_string", [
      test_case "exists" `Quick test_get_string_exists;
      test_case "missing" `Quick test_get_string_missing;
      test_case "wrong type" `Quick test_get_string_wrong_type;
      test_case "non-assoc" `Quick test_get_string_non_assoc;
    ];
    "get_string_opt", [
      test_case "exists" `Quick test_get_string_opt_exists;
      test_case "missing" `Quick test_get_string_opt_missing;
      test_case "empty string" `Quick test_get_string_opt_empty_string;
      test_case "wrong type" `Quick test_get_string_opt_wrong_type;
      test_case "non-assoc" `Quick test_get_string_opt_non_assoc;
    ];
    "get_float", [
      test_case "from float" `Quick test_get_float_from_float;
      test_case "from int" `Quick test_get_float_from_int;
      test_case "missing" `Quick test_get_float_missing;
      test_case "wrong type" `Quick test_get_float_wrong_type;
      test_case "non-assoc" `Quick test_get_float_non_assoc;
    ];
    "blacklist", [
      test_case "add and check" `Quick test_blacklist_add_and_check;
      test_case "auto expiry" `Quick test_blacklist_auto_expiry;
      test_case "remove" `Quick test_blacklist_remove;
      test_case "check nonexistent" `Quick test_blacklist_check_nonexistent;
      test_case "replace" `Quick test_blacklist_replace;
    ];
    "dispatch", [
      test_case "masc_suspend" `Quick test_dispatch_suspend;
      test_case "unknown" `Quick test_dispatch_unknown;
    ];
    "handle_suspend", [
      test_case "empty target" `Quick test_handle_suspend_empty_target;
      test_case "missing target" `Quick test_handle_suspend_missing_target;
      test_case "valid" `Quick test_handle_suspend_valid;
      test_case "self suspend" `Quick test_handle_suspend_self;
      test_case "default reason" `Quick test_handle_suspend_default_reason;
    ];
    "handle_circuit_status", [
      test_case "with agent_id" `Quick test_circuit_status_with_agent_id;
      test_case "default agent" `Quick test_circuit_status_default_agent;
      test_case "no caller" `Quick test_circuit_status_no_caller;
      test_case "blacklisted agent" `Quick test_circuit_status_blacklisted_agent;
    ];
    "check_can_join", [
      test_case "clean agent" `Quick test_check_can_join_clean;
      test_case "blacklisted" `Quick test_check_can_join_blacklisted;
      test_case "expired blacklist" `Quick test_check_can_join_expired_blacklist;
    ];
  ]
