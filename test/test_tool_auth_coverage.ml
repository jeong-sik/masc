(** Coverage tests for Tool_auth *)

open Masc_mcp

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()

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

let extract_first_backtick_value text =
  match String.index_opt text '`' with
  | None -> failwith ("no backtick-delimited value found in: " ^ text)
  | Some start ->
      (match String.index_from_opt text (start + 1) '`' with
       | None -> failwith ("unterminated backtick-delimited value in: " ^ text)
       | Some stop -> String.sub text (start + 1) (stop - start - 1))

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

(* Test registry — collected at top-level and dispatched via Alcotest.run
   at the bottom of the file.  Eio scope is set up per-test because the
   dispatch paths use Eio.Mutex / structured concurrency. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    with_isolated_runtime_env f) :: !test_cases

(* Create test context — called inside Eio scope from test helper *)
let test_counter = ref 0
let make_test_ctx () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-auth-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  { Tool_auth.config; agent_name = "test-agent" }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_auth.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test auth_status dispatch *)
let () = test "dispatch_auth_status" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_auth.dispatch ctx ~name:"masc_auth_status" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test handle_auth_status *)
let () = test "handle_auth_status" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  let (success, result) = Tool_auth.handle_auth_status ctx args in
  assert success;
  assert (String.length result > 0);
  assert (contains_substring result "Authentication Status");
  assert (contains_substring result "HTTP Auth Strict:");
  assert (contains_substring result "Bind Host:")
)

(* Test auth_enable dispatch *)
let () = test "dispatch_auth_enable" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_auth.dispatch ctx ~name:"masc_auth_enable" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test handle_auth_enable *)
let () = test "handle_auth_enable" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("require_token", `Bool true)] in
  let (success, result) = Tool_auth.handle_auth_enable ctx args in
  assert success;
  assert (String.length result > 0 (* contains emoji *))
)

(* Test auth_disable dispatch *)
let () = test "dispatch_auth_disable" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Tool_auth.handle_auth_enable ctx (`Assoc []) in (* Enable first *)
  let args = `Assoc [] in
  match Tool_auth.dispatch ctx ~name:"masc_auth_disable" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test handle_auth_disable *)
let () = test "handle_auth_disable" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  let (success, result) = Tool_auth.handle_auth_disable ctx args in
  assert success;
  assert (String.length result > 0 (* contains emoji *))
)

(* Test auth_list dispatch *)
let () = test "dispatch_auth_list" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  match Tool_auth.dispatch ctx ~name:"masc_auth_list" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test handle_auth_list empty *)
let () = test "handle_auth_list_empty" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  let (success, result) = Tool_auth.handle_auth_list ctx args in
  assert success;
  assert (String.length result > 0)
)

(* Test auth_revoke dispatch *)
let () = test "dispatch_auth_revoke" (fun () ->
  let ctx = make_test_ctx () in
  ignore (Auth.create_token ctx.config.base_path ~agent_name:ctx.agent_name ~role:Types.Worker);
  let args = `Assoc [] in
  match Tool_auth.dispatch ctx ~name:"masc_auth_revoke" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* #6623 iter 8 — cross-agent create_token must be gated on
   initial_admin. This case pins the admin path: set [ctx.agent_name]
   as the initial admin of the test config, then create a token for
   a different target. Expected: success (admin can provision tokens
   for any agent). *)
let () = test "handle_auth_create_token_admin_can_target_others" (fun () ->
  let ctx = make_test_ctx () in
  Auth.write_initial_admin ctx.config.base_path ctx.agent_name;
  let target = "dashboard-eager-manta" in
  let args =
    `Assoc [
      ("agent_name", `String target);
      ("role", `String "worker");
    ]
  in
  let (success, result) = Tool_auth.handle_auth_create_token ctx args in
  assert success;
  assert (contains_substring result target);
  let raw_token = extract_first_backtick_value result in
  match Auth.verify_token ctx.config.base_path ~agent_name:target ~token:raw_token with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e)
)

(* #6623 iter 8 — negative case: non-admin caller cannot forge a
   token for another agent. Rejection must be surfaced as
   (false, msg) with a Cross-agent-blocked message. *)
let () = test "handle_auth_create_token_non_admin_cross_agent_blocked" (fun () ->
  let ctx = make_test_ctx () in
  (* Do NOT write an initial_admin entry — ctx.agent_name is a plain
     caller, not the bootstrap admin. *)
  let target = "other-agent" in
  let args =
    `Assoc [
      ("agent_name", `String target);
      ("role", `String "worker");
    ]
  in
  let (success, result) = Tool_auth.handle_auth_create_token ctx args in
  assert (not success);
  assert (contains_substring result "Cross-agent");
  assert (contains_substring result "masc_auth_create_token");
  assert (contains_substring result target);
  (* The leaked credential should not have been persisted. *)
  match Auth.load_credential ctx.config.base_path target with
  | Some _ -> failwith "credential was persisted despite rejection"
  | None -> ()
)

(* #6623 iter 8 — self path: caller == target must still work for
   any agent, admin or not. This is the non-privileged happy path. *)
let () = test "handle_auth_create_token_self_always_allowed" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc [
      ("agent_name", `String ctx.agent_name);
      ("role", `String "worker");
    ]
  in
  let (success, result) = Tool_auth.handle_auth_create_token ctx args in
  assert success;
  assert (contains_substring result ctx.agent_name)
)

(* #6623 iter 8 — same rejection gate for revoke. *)
let () = test "handle_auth_revoke_non_admin_cross_agent_blocked" (fun () ->
  let ctx = make_test_ctx () in
  (* Seed a credential for a foreign agent. The revoke attempt must
     be rejected before reaching delete_credential. *)
  let target = "victim-agent" in
  (match Auth.create_token ctx.config.base_path ~agent_name:target ~role:Types.Worker with
   | Ok _ -> ()
   | Error e -> failwith (Types.masc_error_to_string e));
  let args = `Assoc [ ("agent_name", `String target) ] in
  let (success, result) = Tool_auth.handle_auth_revoke ctx args in
  assert (not success);
  assert (contains_substring result "Cross-agent");
  assert (contains_substring result "masc_auth_revoke");
  (* Credential must still exist. *)
  match Auth.load_credential ctx.config.base_path target with
  | Some _ -> ()
  | None -> failwith "credential was deleted despite rejection"
)

let () = test "handle_auth_refresh_respects_agent_name" (fun () ->
  let ctx = make_test_ctx () in
  let old_token =
    match Auth.create_token ctx.config.base_path ~agent_name:ctx.agent_name ~role:Types.Worker with
    | Ok (raw_token, _cred) -> raw_token
    | Error e -> failwith (Types.masc_error_to_string e)
  in
  let args =
    `Assoc [
      ("agent_name", `String ctx.agent_name);
      ("token", `String old_token);
    ]
  in
  let (success, result) = Tool_auth.handle_auth_refresh ctx args in
  assert success;
  let new_token = extract_first_backtick_value result in
  assert (new_token <> old_token);
  match Auth.verify_token ctx.config.base_path ~agent_name:ctx.agent_name ~token:new_token with
  | Ok _ -> ()
  | Error e -> failwith (Types.masc_error_to_string e)
)

let () = test "handle_auth_refresh_rejects_other_agent" (fun () ->
  let ctx = make_test_ctx () in
  let args =
    `Assoc [
      ("agent_name", `String "dashboard-eager-manta");
      ("token", `String "dummy-token");
    ]
  in
  let (success, result) = Tool_auth.handle_auth_refresh ctx args in
  assert (not success);
  assert (contains_substring result "authenticated agent")
)

(* #6623 iter 8 — admin can revoke cross-agent credentials for
   legitimate rotation. Mirrors the create_token admin path. *)
let () = test "handle_auth_revoke_admin_can_target_others" (fun () ->
  let ctx = make_test_ctx () in
  Auth.write_initial_admin ctx.config.base_path ctx.agent_name;
  let target = "dashboard-eager-manta" in
  ignore (Auth.create_token ctx.config.base_path ~agent_name:target ~role:Types.Worker);
  let args = `Assoc [("agent_name", `String target)] in
  let (success, result) = Tool_auth.handle_auth_revoke ctx args in
  assert success;
  assert (contains_substring result target);
  let remaining =
    Auth.list_credentials ctx.config.base_path
    |> List.filter (fun (cred : Types.agent_credential) -> cred.agent_name = target)
  in
  assert (remaining = [])
)

let () = test "handle_auth_revoke_missing_agent_fails" (fun () ->
  let ctx = make_test_ctx () in
  let target = "missing-agent" in
  let args = `Assoc [("agent_name", `String target)] in
  let (success, result) = Tool_auth.handle_auth_revoke ctx args in
  assert (not success);
  assert (contains_substring result target)
)

(* Test get_string helper *)
let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_args.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_string args "key" "default" = "default")
)

(* Test get_bool helper *)
let () = test "get_bool_true" (fun () ->
  let args = `Assoc [("key", `Bool true)] in
  assert (Tool_args.get_bool args "key" false = true)
)

let () = test "get_bool_false" (fun () ->
  let args = `Assoc [("key", `Bool false)] in
  assert (Tool_args.get_bool args "key" true = false)
)

let () = test "get_bool_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_bool args "key" true = true)
)

let () =
  Alcotest.run "Tool_auth"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
