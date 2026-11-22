open Masc

module Env = Server_dashboard_http_v2_envelope
module Precond = Server_workspace_precondition
module Wiki_api = Server_dashboard_http_wiki
module Sandbox_api = Server_dashboard_http_infra_sandboxes
module Memory_api = Server_dashboard_http_memory_v2
module Candle_cfg_api = Server_dashboard_http_candle_config
module Board_http = Server_board_list_http

(* ── Temp workspace helpers ────────────────────────────────────────────── *)

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    (try
       Array.iter
         (fun entry -> rm_rf (Filename.concat path entry))
         (Sys.readdir path)
     with
     | Sys_error _ -> ());
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
;;

let rec mkdir_p path =
  if path = "" || path = "/" || path = "." then ()
  else if Sys.file_exists path then ()
  else (
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let with_temp_workspace (f : Workspace.config -> 'a) : 'a =
  let base = Filename.temp_dir "masc_tui_v2_api_" "" in
  mkdir_p (Filename.concat base ".masc/config/keepers");
  mkdir_p (Filename.concat base ".masc/keepers");
  let config = Workspace.default_config base in
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f config)
;;

let write_file_raw path content =
  mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("write_file_raw failed: " ^ msg)
;;

let read_file_raw path =
  Fs_compat.load_file path
;;

let json_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let json_member_exn key json =
  match json_member key json with
  | Some v -> v
  | None ->
    Alcotest.fail
      (Printf.sprintf "Missing JSON key %S in %s" key (Yojson.Safe.to_string json))
;;

let json_string_exn key json =
  match json_member_exn key json with
  | `String s -> s
  | other ->
    Alcotest.fail
      (Printf.sprintf "Expected string for %S, got %s" key (Yojson.Safe.to_string other))
;;

let json_int_exn key json =
  match json_member_exn key json with
  | `Int n -> n
  | other ->
    Alcotest.fail
      (Printf.sprintf "Expected int for %S, got %s" key (Yojson.Safe.to_string other))
;;

let json_bool_exn key json =
  match json_member_exn key json with
  | `Bool b -> b
  | other ->
    Alcotest.fail
      (Printf.sprintf "Expected bool for %S, got %s" key (Yojson.Safe.to_string other))
;;

let json_list_exn key json =
  match json_member_exn key json with
  | `List xs -> xs
  | other ->
    Alcotest.fail
      (Printf.sprintf "Expected list for %S, got %s" key (Yojson.Safe.to_string other))
;;

let contains_substr ~needle haystack =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen = 0 then true
  else if nlen > hlen then false
  else (
    let rec loop i =
      if i + nlen > hlen then false
      else if String.sub haystack i nlen = needle then true
      else loop (i + 1)
    in
    loop 0)
;;

let ok_or_fail label = function
  | Ok v -> v
  | Error (status, body) ->
    Alcotest.fail
      (Printf.sprintf
         "%s failed with HTTP %d: %s"
         label
         (Httpun.Status.to_code status)
         (Yojson.Safe.to_string body))
;;

(* ── 1. Workspace / Instance Guard Header ──────────────────────────────── *)

let make_request ?(headers = []) target =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    target
;;

let test_workspace_guard_headers () =
  let served_ws =
    Some
      Request_workspace_precondition.
        { base_path = "/tmp/masc-served-root"
        ; masc_root = "/tmp/masc-served-root/.masc"
        }
  in
  let served () = served_ws in
  let instance_id = "inst-0196-test-uuid" in
  let ws_sha = Env.sha256_hex "/tmp/masc-served-root" in
  (* 1. Omitted headers always pass *)
  (match
     Precond.check_v2_guard
       ~instance_id
       ~served
       ~ready:true
       ~path:"/api/v1/wiki"
       (make_request "/api/v1/wiki")
   with
   | Precond.Guard_pass -> ()
   | Precond.Guard_refused _ -> Alcotest.fail "omitted headers must pass");
  (* 2. /health always bypasses mismatch *)
  (match
     Precond.check_v2_guard
       ~instance_id
       ~served
       ~ready:true
       ~path:"/health"
       (make_request
          ~headers:
            [ Precond.expected_instance_header, "wrong-instance"
            ; Precond.expected_workspace_header, "/wrong/path"
            ]
          "/health")
   with
   | Precond.Guard_pass -> ()
   | Precond.Guard_refused _ -> Alcotest.fail "/health must skip guard");
  (* 3. Mismatched X-Masc-Expected-Instance -> 409 workspace_mismatch *)
  (match
     Precond.check_v2_guard
       ~instance_id
       ~served
       ~ready:true
       ~path:"/api/v1/wiki"
       (make_request
          ~headers:[ Precond.expected_instance_header, "stale-instance" ]
          "/api/v1/wiki")
   with
   | Precond.Guard_refused { status; body; _ } ->
     Alcotest.(check int) "409 status" 409 (Httpun.Status.to_code status);
     Alcotest.(check string) "error code" "workspace_mismatch" (json_string_exn "error" body);
     Alcotest.(check string) "reason" "instance_mismatch" (json_string_exn "reason" body);
     Alcotest.(check string) "observed_instance" instance_id (json_string_exn "observed_instance" body)
   | Precond.Guard_pass -> Alcotest.fail "mismatched instance must return 409");
  (* 4. Mismatched X-Masc-Expected-Workspace -> 409 workspace_mismatch *)
  (match
     Precond.check_v2_guard
       ~instance_id
       ~served
       ~ready:true
       ~path:"/api/v1/wiki"
       (make_request
          ~headers:[ Precond.expected_workspace_header, "/other/workspace" ]
          "/api/v1/wiki")
   with
   | Precond.Guard_refused { status; body; _ } ->
     Alcotest.(check int) "409 status" 409 (Httpun.Status.to_code status);
     Alcotest.(check string) "error code" "workspace_mismatch" (json_string_exn "error" body);
     Alcotest.(check string) "reason" "workspace_mismatch" (json_string_exn "reason" body)
   | Precond.Guard_pass -> Alcotest.fail "mismatched workspace must return 409");
  (* 5. Matching instance + raw workspace path passes *)
  (match
     Precond.check_v2_guard
       ~instance_id
       ~served
       ~ready:true
       ~path:"/api/v1/wiki"
       (make_request
          ~headers:
            [ Precond.expected_instance_header, instance_id
            ; Precond.expected_workspace_header, "/tmp/masc-served-root"
            ]
          "/api/v1/wiki")
   with
   | Precond.Guard_pass -> ()
   | Precond.Guard_refused _ -> Alcotest.fail "matching raw workspace must pass");
  (* 6. Matching instance + sha256(base_path) passes *)
  (match
     Precond.check_v2_guard
       ~instance_id
       ~served
       ~ready:true
       ~path:"/api/v1/wiki"
       (make_request
          ~headers:
            [ Precond.expected_instance_header, instance_id
            ; Precond.expected_workspace_header, ws_sha
            ]
          "/api/v1/wiki")
   with
   | Precond.Guard_pass -> ()
   | Precond.Guard_refused _ -> Alcotest.fail "matching workspace sha256 must pass");
  (* 7. Blank header -> 400 *)
  match
    Precond.check_v2_guard
      ~instance_id
      ~served
      ~ready:true
      ~path:"/api/v1/wiki"
      (make_request
         ~headers:[ Precond.expected_instance_header, "   " ]
         "/api/v1/wiki")
  with
  | Precond.Guard_refused { status; _ } ->
    Alcotest.(check int) "400 status" 400 (Httpun.Status.to_code status)
  | Precond.Guard_pass -> Alcotest.fail "blank guard header must return 400"
;;

(* ── 2. Contract 1 — Wiki HTTP API ─────────────────────────────────────── *)

let test_wiki_api_roundtrip_and_lint () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let now = 1_760_000_000.0 in
    (* Create page 1 linking to design-notes and a missing page *)
    let put1_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "title", `String "Architecture Overview"
          ; "source", `String "observation"
          ; "summary", `String "Core architecture notes"
          ; "tags", `List [ `String "architecture"; `String "tui" ]
          ; "body", `String "See [Design Notes](design-notes.md) and [Missing](nonexistent-target.md) for details."
          ])
    in
    let put1_resp =
      Wiki_api.put_page_json
        ~now
        ~config
        ~actor:"tester"
        ~slug:"architecture-overview"
        ~body_str:put1_body
        ()
      |> ok_or_fail "PUT architecture-overview"
    in
    let put1_data = json_member_exn "data" put1_resp in
    let sha1 = json_string_exn "sha256" put1_data in
    Alcotest.(check bool) "sha256 non-empty" true (String.length sha1 = 64);
    (* Create page 2: target of link *)
    let put2_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "title", `String "Design Notes"
          ; "source", `String "research"
          ; "summary", `String "Atomic file write conventions"
          ; "tags", `List [ `String "design" ]
          ; "body", `String "Atomic writes use Fs_compat.save_file_atomic everywhere."
          ])
    in
    ignore
      (Wiki_api.put_page_json
         ~now:(now +. 10.0)
         ~config
         ~actor:"tester"
         ~slug:"design-notes"
         ~body_str:put2_body
         ()
       |> ok_or_fail "PUT design-notes");
    (* Create page 3: orphan page with duplicate title *)
    let put3_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "title", `String "architecture   overview"
          ; "source", `String "observation"
          ; "summary", `String "Duplicate title orphan note"
          ; "tags", `List [ `String "architecture" ]
          ; "body", `String "Duplicate title orphan note."
          ])
    in
    ignore
      (Wiki_api.put_page_json
         ~now:(now +. 20.0)
         ~config
         ~actor:"tester"
         ~slug:"architecture-overview-dup"
         ~body_str:put3_body
         ()
       |> ok_or_fail "PUT architecture-overview-dup");
    (* GET /api/v1/wiki list *)
    let list_data =
      Wiki_api.list_json ~now ~base_path ()
      |> ok_or_fail "GET /api/v1/wiki"
      |> json_member_exn "data"
    in
    let pages = json_list_exn "pages" list_data in
    Alcotest.(check int) "3 wiki pages" 3 (List.length pages);
    (* GET /api/v1/wiki/design-notes -> verify backlinks *)
    let page2_data =
      Wiki_api.get_page_json ~now ~base_path ~slug:"design-notes" ()
      |> ok_or_fail "GET design-notes"
      |> json_member_exn "data"
    in
    let backlinks = json_list_exn "backlinks" page2_data in
    Alcotest.(check int) "1 backlink to design-notes" 1 (List.length backlinks);
    (* GET /api/v1/wiki/search?q=save_file_atomic *)
    let search_data =
      Wiki_api.search_json ~now ~base_path ~query:"save_file_atomic" ()
      |> ok_or_fail "GET search"
      |> json_member_exn "data"
    in
    let results = json_list_exn "results" search_data in
    Alcotest.(check bool) "at least 1 search hit" true (List.length results >= 1);
    Alcotest.(check string)
      "top search hit is design-notes"
      "design-notes"
      (json_string_exn "slug" (List.hd results));
    (* GET /api/v1/wiki/log *)
    let log_data =
      Wiki_api.log_json ~now ~base_path ()
      |> ok_or_fail "GET log"
      |> json_member_exn "data"
    in
    let log_entries = json_list_exn "entries" log_data in
    Alcotest.(check bool) "wiki log has entries" true (List.length log_entries >= 3);
    (* GET /api/v1/wiki/lint -> duplicate title + orphan + broken link *)
    let lint_data =
      Wiki_api.lint_json ~now ~base_path ()
      |> ok_or_fail "GET lint"
      |> json_member_exn "data"
    in
    let dup_candidates = json_list_exn "duplicate_title_candidates" lint_data in
    Alcotest.(check bool)
      "duplicate title detected"
      true
      (List.length dup_candidates >= 1);
    let findings = json_list_exn "findings" lint_data in
    let has_finding kind_name =
      List.exists (fun f -> json_string_exn "kind" f = kind_name) findings
    in
    Alcotest.(check bool) "broken link detected" true (has_finding "broken_link");
    Alcotest.(check bool) "orphan page detected" true (has_finding "orphan");
    (* P1-3(b): PUT without expected_sha256 or expected_revision on existing page -> 409 conflict_cas *)
    let blind_put =
      Yojson.Safe.to_string
        (`Assoc
          [ "title", `String "Blind Overwrite"
          ; "body", `String "must be rejected without CAS"
          ])
    in
    (match
       Wiki_api.put_page_json
         ~now:(now +. 25.0)
         ~config
         ~actor:"tester"
         ~slug:"architecture-overview"
         ~body_str:blind_put
         ()
     with
     | Error (status, err_body) ->
       Alcotest.(check int) "blind overwrite 409" 409 (Httpun.Status.to_code status);
       let err_obj = json_member_exn "error" err_body in
       Alcotest.(check string) "conflict_cas" "conflict_cas" (json_string_exn "code" err_obj);
       Alcotest.(check string) "current_sha256 echoed" sha1 (json_string_exn "current_sha256" err_body);
       Alcotest.(check int) "current_revision echoed" 1 (json_int_exn "current_revision" err_body)
     | Ok _ -> Alcotest.fail "omitting CAS on existing wiki page must reject with 409");
    (* PUT CAS mismatch -> 409 conflict_cas *)
    let stale_put =
      Yojson.Safe.to_string
        (`Assoc
          [ "expected_sha256", `String (String.make 64 '0')
          ; "title", `String "Should Not Overwrite"
          ; "body", `String "stale content"
          ])
    in
    (match
       Wiki_api.put_page_json
         ~now:(now +. 30.0)
         ~config
         ~actor:"tester"
         ~slug:"architecture-overview"
         ~body_str:stale_put
         ()
     with
     | Error (status, err_body) ->
       Alcotest.(check int) "CAS conflict 409" 409 (Httpun.Status.to_code status);
       let err_obj = json_member_exn "error" err_body in
       Alcotest.(check string) "conflict_cas" "conflict_cas" (json_string_exn "code" err_obj)
     | Ok _ -> Alcotest.fail "stale expected_sha256 must reject with 409");
    (* PUT CAS matching sha1 -> 200 OK & updated sha256 *)
    let fresh_put =
      Yojson.Safe.to_string
        (`Assoc
          [ "expected_sha256", `String sha1
          ; "title", `String "Architecture Overview"
          ; "body", `String "Updated safely with CAS and save_file_atomic."
          ])
    in
    let updated_data =
      Wiki_api.put_page_json
        ~now:(now +. 40.0)
        ~config
        ~actor:"tester"
        ~slug:"architecture-overview"
        ~body_str:fresh_put
        ()
      |> ok_or_fail "PUT CAS success"
      |> json_member_exn "data"
    in
    let sha2 = json_string_exn "sha256" updated_data in
    Alcotest.(check bool) "sha256 changed on update" true (sha2 <> sha1);
    let reloaded =
      Wiki_api.get_page_json ~now ~base_path ~slug:"architecture-overview" ()
      |> ok_or_fail "GET reloaded"
      |> json_member_exn "data"
    in
    Alcotest.(check bool)
      "updated body persisted"
      true
      (contains_substr ~needle:"Updated safely with CAS" (json_string_exn "body_markdown" reloaded)))
;;

(* ── 3. Contract 2 — Infra Sandboxes / microVM / SSH Fleet API ─────────── *)

let test_infra_sandboxes_api () =
  Sandbox_api.clear_cache_for_testing ();
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let masc_root = Filename.concat base_path ".masc" in
    (* Write a microvm keeper and a remote_ssh keeper with valid TOML keys *)
    write_file_raw
      (Filename.concat base_path ".masc/config/keepers/vm-alpha.toml")
      {|
[keeper]
name = "vm-alpha"
instructions = "Verify microVM telemetry"
activation_mode = "on_demand"
sandbox_profile = "microvm"
microvm_backend = "apple_container"
|};
    write_file_raw
      (Filename.concat base_path ".masc/config/keepers/ssh-beta.toml")
      {|
[keeper]
name = "ssh-beta"
instructions = "Verify remote SSH telemetry"
activation_mode = "on_demand"
sandbox_profile = "remote_ssh"
|};
    (* Seed tool-metrics.sqlite3 with all 4 failure classes *)
    let now = Unix.gettimeofday () in
    let insert_metric id tool_name failure_class =
      let row =
        Tool_metrics_store.
          { record_id = id
          ; ts = now -. 60.0
          ; tool_name
          ; disposition = "failed"
          ; duration_ms = 12.5
          }
      in
      match
        Tool_metrics_store.insert
          ~masc_root
          ~result_bytes:128
          ~failure_class:(Some failure_class)
          ~caller:"vm-alpha"
          row
      with
      | Ok () -> ()
      | Error msg -> Alcotest.fail ("Tool_metrics_store.insert failed: " ^ msg)
    in
    insert_metric "m1" "keeper_bash" Tool_result.Dependency_unavailable;
    insert_metric "m2" "keeper_bash" Tool_result.Runtime_failure;
    insert_metric "m3" "keeper_bash" Tool_result.Policy_rejection;
    insert_metric "m4" "keeper_bash" Tool_result.Workflow_rejection;
    let tool_series =
      match
        Tool_metrics_series.sliding_window
          ~span_s:86400.0
          ~until:now
          ~width:Tool_metrics_series.Hour
          ~utc_offset_min:0
      with
      | Error msg -> Alcotest.fail ("sliding_window failed: " ^ msg)
      | Ok window -> Some (Tool_metrics_store.read_series ~masc_root ~window ())
    in
    let t0 = Unix.gettimeofday () in
    let snap =
      Sandbox_api.build_snapshot_json
        ~now
        ~probe_state:Sandbox_api.Probe_fresh
        ~tool_series
        ~base_path
        ()
    in
    let elapsed_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
    Alcotest.(check bool) "non-blocking snapshot < 500ms" true (elapsed_ms < 500.0);
    let data = json_member_exn "data" snap in
    let summary = json_member_exn "summary" data in
    Alcotest.(check int)
      "1 microvm_declared"
      1
      (json_int_exn "microvm_declared" summary);
    Alcotest.(check int)
      "1 ssh_unbound_keepers"
      1
      (json_int_exn "ssh_unbound_keepers" summary);
    (* P2-1: ssh_active_sessions must be null (unobserved), never fabricated 0 *)
    (match json_member_exn "ssh_active_sessions" summary with
     | `Null -> ()
     | other ->
       Alcotest.fail
         ("ssh_active_sessions must be null when unobserved, got "
          ^ Yojson.Safe.to_string other));
    let unobserved_reasons = json_list_exn "unobserved_reasons" data in
    let has_ssh_unreported =
      List.exists
        (fun item -> json_string_exn "reason" item = "ssh_active_sessions_unreported")
        unobserved_reasons
    in
    Alcotest.(check bool)
      "unobserved_reasons reports ssh_active_sessions_unreported"
      true
      has_ssh_unreported;
    (* P2-2: unbound SSH keeper must appear in ssh_unbound_keepers and be retrievable by /:keeper *)
    let unbound_list = json_list_exn "ssh_unbound_keepers" data in
    Alcotest.(check int) "1 unbound SSH keeper row" 1 (List.length unbound_list);
    let ssh_beta_ok =
      Sandbox_api.get_keeper_json ~now ~base_path ~keeper:"ssh-beta" ()
      |> ok_or_fail "GET /api/v1/infra/sandboxes/ssh-beta (unbound)"
      |> json_member_exn "data"
    in
    Alcotest.(check string) "unbound keeper name" "ssh-beta" (json_string_exn "keeper" ssh_beta_ok);
    let ssh_beta_sb = json_member_exn "sandbox" ssh_beta_ok in
    Alcotest.(check string)
      "unbound binding_state"
      "unbound"
      (json_string_exn "binding_state" ssh_beta_sb);
    let tool_metrics = json_member_exn "tool_metrics_24h" data in
    let failures = json_member_exn "failure_classes" tool_metrics in
    Alcotest.(check int)
      "dependency_unavailable"
      1
      (json_int_exn "dependency_unavailable" failures);
    Alcotest.(check int)
      "runtime_failure"
      1
      (json_int_exn "runtime_failure" failures);
    Alcotest.(check int)
      "policy_rejection"
      1
      (json_int_exn "policy_rejection" failures);
    Alcotest.(check int)
      "workflow_rejection"
      1
      (json_int_exn "workflow_rejection" failures);
    (* Non-blocking get_fleet_json without sw returns promptly *)
    let t1 = Unix.gettimeofday () in
    let fleet = Sandbox_api.get_fleet_json ~now ~base_path () in
    let elapsed_fleet_ms = (Unix.gettimeofday () -. t1) *. 1000.0 in
    Alcotest.(check bool) "get_fleet_json < 500ms" true (elapsed_fleet_ms < 500.0);
    let fleet_data = json_member_exn "data" fleet in
    ignore (json_member_exn "microvm_guests" fleet_data);
    ignore (json_member_exn "ssh_pools" fleet_data);
    ignore (json_member_exn "shim_parity" fleet_data);
    (* Per-keeper endpoint: found vs 404 *)
    let keeper_ok =
      Sandbox_api.get_keeper_json ~now ~base_path ~keeper:"vm-alpha" ()
      |> ok_or_fail "GET /api/v1/infra/sandboxes/vm-alpha"
    in
    Alcotest.(check string)
      "keeper name"
      "vm-alpha"
      (json_string_exn "keeper" (json_member_exn "data" keeper_ok));
    match Sandbox_api.get_keeper_json ~now ~base_path ~keeper:"does-not-exist" () with
    | Error (status, _) ->
      Alcotest.(check int) "unknown keeper 404" 404 (Httpun.Status.to_code status)
    | Ok _ -> Alcotest.fail "unknown keeper should return 404")
;;

(* ── 4. Contract 3 — World Memory & Temporal Memory Diff API ───────────── *)

let test_memory_v2_world_and_diff () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    mkdir_p keepers_dir;
    let now = 1_760_000_000.0 in
    let origin =
      Keeper_memory_os_types.{ kind = Authored; trace_id = "trace-1" }
    in
    let source =
      Keeper_memory_os_current.{ kind = Explicit_write; trace_id = "trace-1" }
    in
    let f1 =
      Keeper_memory_os_types.observed
        ~claim:"Deploy writes config with atomic rename"
        ~category:Keeper_memory_os_types.Fact
        ~now:(now -. 300.0)
        ~origin
    in
    let f1_id = Keeper_memory_os_types.memory_id f1 in
    let f2 =
      Keeper_memory_os_types.observed
        ~claim:"Temporary scratch note that will be retracted"
        ~category:Keeper_memory_os_types.Lesson
        ~now:(now -. 250.0)
        ~origin
    in
    let f2_id = Keeper_memory_os_types.memory_id f2 in
    let f1_v2 =
      Keeper_memory_os_types.observed
        ~claim:"Deploy writes config with Fs_compat.save_file_atomic"
        ~category:Keeper_memory_os_types.Fact
        ~now:(now -. 200.0)
        ~origin
    in
    let f1_v2_id = Keeper_memory_os_types.memory_id f1_v2 in
    (match
       Keeper_memory_os_current.upsert_fact
         ~pass:Keeper_memory_commit_pass.Keeper_write
         ~keepers_dir
         ~keeper_id:"alpha"
         ~now:(now -. 300.0)
         ~source
         f1
     with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail ("upsert f1 failed: " ^ Keeper_memory_os_current.upsert_error_to_string e));
    (match
       Keeper_memory_os_current.upsert_fact
         ~pass:Keeper_memory_commit_pass.Keeper_write
         ~keepers_dir
         ~keeper_id:"alpha"
         ~now:(now -. 250.0)
         ~source
         f2
     with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail ("upsert f2 failed: " ^ Keeper_memory_os_current.upsert_error_to_string e));
    (match
       Keeper_memory_os_current.supersede_fact
         ~pass:Keeper_memory_commit_pass.Keeper_write
         ~keepers_dir
         ~keeper_id:"alpha"
         ~now:(now -. 200.0)
         ~source
         ~superseded_memory_id:f1_id
         f1_v2
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "supersede f1 failed");
    (match
       Keeper_memory_os_current.retract_fact
         ~pass:Keeper_memory_commit_pass.Keeper_delete
         ~keepers_dir
         ~keeper_id:"alpha"
         ~now:(now -. 100.0)
         ~source:{ kind = Explicit_retract; trace_id = "trace-2" }
         ~memory_id:f2_id
         ~reason:"obsolete scratch note"
         ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "retract f2 failed");
    (* Append retrieval events so f1_v2 becomes "hot" *)
    for i = 1 to 3 do
      match
        Keeper_memory_os_events.append
          ~keepers_dir
          ~keeper_id:"alpha"
          { recorded_at = now -. float_of_int (i * 10)
          ; memory_id = f1_v2_id
          ; trace_id = Printf.sprintf "ret-%d" i
          ; kind = Retrieved { query = "save_file_atomic" }
          }
      with
      | Ok () -> ()
      | Error e ->
        Alcotest.fail
          ("append retrieval event failed: " ^ Keeper_memory_os_events.append_error_to_string e)
    done;
    (* Populate keeper beta with a conflicting claim *)
    let beta_f =
      Keeper_memory_os_types.observed
        ~claim:"Deploy writes config directly without atomic rename"
        ~category:Keeper_memory_os_types.Fact
        ~now:(now -. 150.0)
        ~origin
    in
    let beta_id = Keeper_memory_os_types.memory_id beta_f in
    (match
       Keeper_memory_os_current.upsert_fact
         ~pass:Keeper_memory_commit_pass.Keeper_write
         ~keepers_dir
         ~keeper_id:"beta"
         ~now:(now -. 150.0)
         ~source
         beta_f
     with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail ("upsert beta failed: " ^ Keeper_memory_os_current.upsert_error_to_string e));
    (* Build & save Workspace_memory_ledger with 1 claim + 1 conflict *)
    let strip_sha256_prefix id =
      if String.starts_with ~prefix:"sha256:" id
      then String.sub id 7 (String.length id - 7)
      else id
    in
    let ref_alpha =
      Workspace_memory_ledger.Ordinary
        { keeper_id = "alpha"; claim_sha256 = strip_sha256_prefix f1_v2_id }
    in
    let ref_beta =
      Workspace_memory_ledger.Ordinary
        { keeper_id = "beta"; claim_sha256 = strip_sha256_prefix beta_id }
    in
    let claim_f =
      Keeper_memory_os_types.observed
        ~claim:"OCaml 5.5 Eio powers the MASC server"
        ~category:Keeper_memory_os_types.Fact
        ~now:(now -. 120.0)
        ~origin
    in
    let claim_id = Keeper_memory_os_types.memory_id claim_f in
    ignore
      (Keeper_memory_os_current.upsert_fact
         ~pass:Keeper_memory_commit_pass.Keeper_write
         ~keepers_dir
         ~keeper_id:"alpha"
         ~now:(now -. 120.0)
         ~source
         claim_f);
    let ref_claim =
      Workspace_memory_ledger.Ordinary
        { keeper_id = "alpha"; claim_sha256 = strip_sha256_prefix claim_id }
    in
    let ledger1 =
      match
        Workspace_memory_ledger.apply
          Workspace_memory_ledger.empty
          ~selected:
            [ { fact = ref_claim; claim = claim_f.claim }
            ; { fact = ref_alpha; claim = f1_v2.claim }
            ]
          [ { fact = ref_claim
            ; decision = Create_claim "OCaml 5.5 Eio powers the MASC server"
            }
          ; { fact = ref_alpha
            ; decision = Create_conflict "Atomic vs direct config writes"
            }
          ]
      with
      | Ok l -> l
      | Error e ->
        Alcotest.fail ("ledger apply 1 failed: " ^ Workspace_memory_ledger.apply_error_to_string e)
    in
    let conflict_id =
      match Workspace_memory_ledger.conflicts ledger1 with
      | (cid, _) :: _ -> cid
      | [] -> Alcotest.fail "expected 1 conflict id"
    in
    let ledger2 =
      match
        Workspace_memory_ledger.apply
          ledger1
          ~selected:[ { fact = ref_beta; claim = beta_f.claim } ]
          [ { fact = ref_beta; decision = Join_conflict conflict_id } ]
      with
      | Ok l -> l
      | Error e ->
        Alcotest.fail ("ledger apply 2 failed: " ^ Workspace_memory_ledger.apply_error_to_string e)
    in
    (match Workspace_memory_ledger.save ~base_path ledger2 with
     | Ok () -> ()
     | Error msg -> Alcotest.fail ("Workspace_memory_ledger.save failed: " ^ msg));
    (* Append a committed Workspace_memory_log batch *)
    let log_path = Workspace_memory_log.log_path ~base_path in
    mkdir_p (Filename.dirname log_path);
    let ts_iso = Masc_domain.iso8601_of_unix_seconds (now -. 60.0) in
    (match
       Workspace_memory_log.append_batch
         ~path:log_path
         ~header:
           { batch_id = "batch-1"
           ; author = "curator"
           ; started_at = ts_iso
           ; expected_changes = 1
           }
         ~changes:
           [ { seq = 1
             ; batch_id = "batch-1"
             ; fact_id = claim_id
             ; summary = "Curated OCaml 5.5 Eio fact"
             ; payload = `Assoc [ "action", `String "add" ]
             ; recorded_at = ts_iso
             }
           ]
         ~committed_at:ts_iso
     with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail ("append_batch failed: " ^ Workspace_memory_log.error_to_string e));
    (* 1. GET /api/v1/memory/world *)
    let world_data =
      Memory_api.world_json ~now ~config ()
      |> ok_or_fail "GET /api/v1/memory/world"
      |> json_member_exn "data"
    in
    let inventory = json_member_exn "inventory" world_data in
    Alcotest.(check int) "claims_count" 1 (json_int_exn "claims_count" inventory);
    Alcotest.(check int) "conflicts_count" 1 (json_int_exn "conflicts_count" inventory);
    let conflicts = json_list_exn "active_conflicts" world_data in
    Alcotest.(check int) "1 active conflict" 1 (List.length conflicts);
    let competing_claims = json_list_exn "competing_claims" (List.hd conflicts) in
    Alcotest.(check int) "2 side-by-side members" 2 (List.length competing_claims);
    List.iter
      (fun member ->
         Alcotest.(check bool) "conflict member resolved" true (json_bool_exn "resolved" member);
         Alcotest.(check bool)
           "conflict member claim text non-empty"
           true
           (String.length (json_string_exn "claim" member) > 0))
      competing_claims;
    (* 2. GET /api/v1/memory/diff?scope=alpha&window=24h *)
    let diff_data =
      Memory_api.diff_json
        ~now
        ~config
        ~scope:(Memory_api.Scope_keeper "alpha")
        ~range:(Memory_api.Range_window Memory_api.Window_24h)
        ()
      |> ok_or_fail "GET /api/v1/memory/diff keeper"
      |> json_member_exn "data"
    in
    let updated = json_list_exn "updated" diff_data in
    Alcotest.(check bool) "at least 1 updated (superseded) fact" true (List.length updated >= 1);
    let retracted = json_list_exn "retracted" diff_data in
    Alcotest.(check bool) "at least 1 retracted fact" true (List.length retracted >= 1);
    let heat_summary = json_member_exn "retrieval_heat" diff_data in
    Alcotest.(check int) "retrieval_heat.hot = 1" 1 (json_int_exn "hot" heat_summary);
    Alcotest.(check int)
      "retrieval_heat.total_events = 3"
      3
      (json_int_exn "total_events" heat_summary);
    let after_entry = json_member_exn "after" (List.hd updated) in
    Alcotest.(check string) "updated after heat = hot" "hot" (json_string_exn "heat" after_entry);
    Alcotest.(check int)
      "updated after retrieval_count = 3"
      3
      (json_int_exn "retrieval_count" after_entry);
    (* 3. GET /api/v1/memory/diff?scope=world&window=24h — also verify P2-3 unparseable timestamps excluded *)
    (match
       Workspace_memory_log.append_batch
         ~path:log_path
         ~header:
           { batch_id = "batch-bad-ts"
           ; author = "curator"
           ; started_at = ts_iso
           ; expected_changes = 1
           }
         ~changes:
           [ { seq = 2
             ; batch_id = "batch-bad-ts"
             ; fact_id = claim_id
             ; summary = "Row with corrupt timestamp"
             ; payload = `Assoc [ "action", `String "add" ]
             ; recorded_at = "not-an-rfc3339-timestamp"
             }
           ]
         ~committed_at:ts_iso
     with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail ("append_batch bad ts failed: " ^ Workspace_memory_log.error_to_string e));
    let world_diff_data =
      Memory_api.diff_json
        ~now
        ~config
        ~scope:Memory_api.Scope_world
        ~range:(Memory_api.Range_window Memory_api.Window_24h)
        ()
      |> ok_or_fail "GET /api/v1/memory/diff world"
      |> json_member_exn "data"
    in
    let world_added = json_list_exn "added" world_diff_data in
    Alcotest.(check int)
      "world diff excludes unparseable recorded_at row (keeps only 1 valid)"
      1
      (List.length world_added);
    Alcotest.(check int)
      "unparseable_timestamps = 1"
      1
      (json_int_exn "unparseable_timestamps" world_diff_data);
    (* 4. Strict query parser rejects conflicting window + from_rev *)
    match
      Memory_api.parse_diff_query
        ~scope:(Some "world")
        ~keeper:None
        ~window:(Some "24h")
        ~from_rev:(Some "1")
        ~to_rev:None
    with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "conflicting window + from_rev must fail")
;;

(* ── 5. Contract 4 — Candle Ledger & Config Schema/Patch API ───────────── *)

let candle_time_exn iso =
  match Candle_time.of_rfc3339 iso with
  | Ok t -> t
  | Error msg -> Alcotest.fail ("Candle_time.of_rfc3339 failed: " ^ msg)
;;

let test_candle_ledger_diagnostics () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let t0 = candle_time_exn "2026-11-20T00:00:00Z" in
    let t1 = candle_time_exn "2026-11-20T01:00:00Z" in
    let t2 = candle_time_exn "2026-11-20T02:00:00Z" in
    let t3 = candle_time_exn "2026-11-20T03:00:00Z" in
    let t4 = candle_time_exn "2026-11-20T04:00:00Z" in
    let hl =
      match Candle_decay.half_life_of_hours 168 with
      | Ok h -> h
      | Error msg -> Alcotest.fail msg
    in
    let measure =
      match Goal_measure.make_label "shipped" with
      | Ok lbl -> Goal_measure.done_when ~condition:lbl
      | Error msg -> Alcotest.fail msg
    in
    let events_to_append =
      [ Candle_event.{ at = t0; body = Half_life_set hl }
      ; { at = t1
        ; body = Granted { keeper = "alpha"; amount_milli = 10_000; reason = "launch_bonus" }
        }
      ; { at = t2
        ; body =
            Snapshot
              { goal_id = "goal-empty-tasks"
              ; request_id = "req-1"
              ; verification_run_id = "run-1"
              ; criterion_revision = "rev-1"
              ; passed_at = t2
              ; goal_created_at = t0
              ; due_date = None
              ; title = "Goal completed with zero linked tasks"
              ; measure
              ; procedure = "check"
              ; linked_task_ids = []
              }
        }
      ; { at = t2
        ; body =
            Payout_owed
              { goal_id = "goal-empty-tasks"
              ; request_id = "req-1"
              ; verification_run_id = "run-1"
              ; passed_at = t2
              ; confirmed_at = t2
              }
        }
      ; { at = t3
        ; body =
            Candidates_fenced
              { goal_id = "goal-empty-tasks"
              ; request_id = "req-1"
              ; verification_run_id = "run-1"
              ; tasks = []
              ; candidate_task_ids = []
              ; candidate_keepers = []
              ; candidate_task_keepers = []
              }
        }
      ; { at = t4
        ; body =
            Unattributed
              { goal_id = "goal-empty-tasks"
              ; request_id = "req-1"
              ; verification_run_id = "run-1"
              ; reason = No_candidates
              }
        }
      ]
    in
    (match
       Candle_ledger.update ~base_path (fun _view -> Ok (events_to_append, ()))
     with
     | Ok () -> ()
     | Error err ->
       Alcotest.fail
         ("Candle_ledger.update failed: "
          ^ Candle_ledger.update_error_to_string Fun.id err));
    let now = Ptime.to_float_s (Candle_time.to_ptime t4) +. 3600.0 in
    let ledger_data =
      Candle_cfg_api.candle_ledger_json ~now ~base_path ()
      |> ok_or_fail "GET /api/v1/candle/ledger"
      |> json_member_exn "data"
    in
    let balances = json_list_exn "balances" ledger_data in
    Alcotest.(check int) "1 wallet balance (alpha)" 1 (List.length balances);
    Alcotest.(check string) "wallet keeper" "alpha" (json_string_exn "keeper" (List.hd balances));
    Alcotest.(check bool)
      "decayed balance < 10000 and > 0"
      true
      (let b = json_int_exn "balance_milli" (List.hd balances) in b > 0 && b < 10_000);
    let diagnostics = json_member_exn "diagnostics" ledger_data in
    Alcotest.(check int)
      "1 unattributed goal"
      1
      (json_int_exn "unattributed_count" diagnostics);
    Alcotest.(check int)
      "1 backlog_fenced_count"
      1
      (json_int_exn "backlog_fenced_count" diagnostics);
    Alcotest.(check int)
      "1 zero_linked_tasks_goals"
      1
      (json_int_exn "zero_linked_tasks_goals" diagnostics);
    let diag_items = json_list_exn "items" diagnostics in
    let g = List.hd diag_items in
    Alcotest.(check string) "goal_id" "goal-empty-tasks" (json_string_exn "goal_id" g);
    Alcotest.(check string) "observation" "backlog_fenced" (json_string_exn "observation" g);
    Alcotest.(check int) "linked_task_count = 0" 0 (json_int_exn "linked_task_count" g);
    let hint = json_string_exn "diagnostic_hint" g in
    Alcotest.(check bool)
      "root-cause hint mentions 0 tasks linked"
      true
      (contains_substr ~needle:"0 tasks linked" hint))
;;

let test_config_schema_redaction_and_patch_roundtrip () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let secret_val = "sk-" ^ "ant-api03-SUPERSECRETKEY9876543210ABCDEF" in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    write_file_raw
      runtime_toml_path
      (Printf.sprintf
         "# Workspace runtime config\n\
          [keeper]\n\
          provider_api_key = \"%s\"\n"
         secret_val);
    let keeper_toml_path = Filename.concat base_path ".masc/config/keepers/alpha.toml" in
    write_file_raw
      keeper_toml_path
      "# Important header comment that must survive patch\n\
       [keeper]\n\
       name = \"alpha\"\n\
       instructions = \"Initial instructions\"\n\
       activation_mode = \"on_demand\" # inline comment\n\
       sandbox_profile = \"microvm\"\n\
       microvm_backend = \"apple_container\"\n";
    (* 1. GET /api/v1/config/schema?target=runtime — 7 categories + secret redaction *)
    let runtime_schema =
      Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
      |> ok_or_fail "GET schema runtime"
    in
    let runtime_schema_str = Yojson.Safe.to_string runtime_schema in
    Alcotest.(check bool)
      "runtime schema never leaks raw secret"
      false
      (contains_substr ~needle:secret_val runtime_schema_str);
    let categories = json_list_exn "categories" (json_member_exn "data" runtime_schema) in
    Alcotest.(check int) "7 server config categories" 7 (List.length categories);
    (* R2-P1-1: secret schema rows MUST emit default_value = null (never plaintext String) *)
    let all_runtime_fields =
      List.concat_map (fun c -> json_list_exn "fields" c) categories
    in
    let secret_fields =
      List.filter (fun f -> json_bool_exn "secret" f) all_runtime_fields
    in
    Alcotest.(check bool) "runtime schema contains secret fields" true
      (List.length secret_fields > 0);
    List.iter
      (fun f ->
         let key = json_string_exn "full_key" f in
         let def_v = json_member_exn "default_value" f in
         let is_null = match def_v with `Null -> true | _ -> false in
         Alcotest.(check bool)
           ("secret field " ^ key ^ " has default_value = null")
           true is_null)
      secret_fields;
    (* 2. Verify P1-1: structural redaction for single-line, multiline arrays, triple-quoted strings,
       inline tables, quoted dotted keys, and untouched 3-line context lines *)
    let unprefixed_s1 = "unprefixed-multiline-secret-alpha-991" in
    let unprefixed_s2 = "unprefixed-multiline-secret-beta-992" in
    let unprefixed_tq = "triple-quoted-unprefixed-secret-993" in
    let unprefixed_inline = "custom-inline-bearer-token-994" in
    let unprefixed_pat = "quoted-dotted-pat-secret-995" in
    let diff_before =
      Printf.sprintf
        "[providers.custom]\n\
         provider_api_key = \"%s\"\n\
         api_tokens = [\n\
           \"%s\",\n\
           \"%s\"\n\
         ]\n\
         client_secret = \"\"\"\n\
         %s\n\
         \"\"\"\n\
         headers = { Authorization = \"Bearer %s\", Accept = \"application/json\" }\n\
         providers.\"pat\" = \"%s\"\n\
         timeout_sec = 30\n"
        secret_val
        unprefixed_s1
        unprefixed_s2
        unprefixed_tq
        unprefixed_inline
        unprefixed_pat
    in
    let new_secret_val = "sk-" ^ "ant-api03-NEWSECRETVALUE1234567890" in
    let diff_after =
      Printf.sprintf
        "[providers.custom]\n\
         provider_api_key = \"%s\"\n\
         api_tokens = [\n\
           \"%s\",\n\
           \"new-unprefixed-secret-996\"\n\
         ]\n\
         client_secret = \"\"\"\n\
         %s\n\
         \"\"\"\n\
         headers = { Authorization = \"Bearer new-inline-secret-997\", Accept = \"application/json\" }\n\
         providers.\"pat\" = \"new-quoted-pat-998\"\n\
         timeout_sec = 60\n"
        new_secret_val
        unprefixed_s1
        unprefixed_tq
    in
    let diff_text, hunks =
      Candle_cfg_api.compute_unified_diff
        ~before_label:"a/runtime.toml"
        ~after_label:"b/runtime.toml"
        ~before:diff_before
        ~after:diff_after
    in
    let hunks_serialized = Yojson.Safe.to_string (`List hunks) in
    let forbidden_secrets =
      [ secret_val
      ; "NEWSECRETVALUE1234567890"
      ; unprefixed_s1
      ; unprefixed_s2
      ; unprefixed_tq
      ; unprefixed_inline
      ; unprefixed_pat
      ; "new-unprefixed-secret-996"
      ; "new-inline-secret-997"
      ; "new-quoted-pat-998"
      ]
    in
    List.iter
      (fun sec ->
         Alcotest.(check bool)
           ("unified_diff never leaks " ^ sec)
           false
           (contains_substr ~needle:sec diff_text);
         Alcotest.(check bool)
           ("diff_hunks never leaks " ^ sec)
           false
           (contains_substr ~needle:sec hunks_serialized))
      forbidden_secrets;
    Alcotest.(check bool) "is_secret_key strips quotes on dotted pat" true (Candle_cfg_api.is_secret_key "providers.\"pat\"");
    (* 3. GET /api/v1/config/schema?target=keeper:alpha & keeper_create *)
    let keeper_schema =
      Candle_cfg_api.config_schema_json ~base_path ~target:(Target_keeper "alpha") ()
      |> ok_or_fail "GET schema keeper:alpha"
      |> json_member_exn "data"
    in
    let initial_sha = json_string_exn "file_sha256" keeper_schema in
    (* P1-4(b): keeper.name must be writable=false for existing keeper *)
    let keeper_cats = json_list_exn "categories" keeper_schema in
    let all_keeper_fields =
      List.concat_map (fun c -> json_list_exn "fields" c) keeper_cats
    in
    let name_field =
      List.find
        (fun f -> json_string_exn "full_key" f = "keeper.name")
        all_keeper_fields
    in
    Alcotest.(check bool) "existing keeper.name is read-only" false (json_bool_exn "writable" name_field);
    let create_schema =
      Candle_cfg_api.config_schema_json ~base_path ~target:Target_keeper_create ()
      |> ok_or_fail "GET schema keeper_create"
      |> json_member_exn "data"
    in
    let create_sha = json_string_exn "file_sha256" create_schema in
    (* P1-3(a): Target_keeper_create accepts file_sha256 returned by keeper_create schema *)
    let create_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper_create"
          ; "keeper_name", `String "gamma"
          ; "expected_sha256", `String create_sha
          ; "dry_run", `Bool false
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "keeper.activation_mode"
                    ; "value", `String "on_demand"
                    ]
                ] )
          ])
    in
    let create_resp =
      Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:create_body ()
      |> ok_or_fail "POST patch keeper_create with schema sha256"
      |> json_member_exn "data"
    in
    let create_snap_path = json_string_exn "snapshot_path" create_resp in
    Alcotest.(check string)
      "keeper_create backup snapshots empty pre-image"
      ""
      (read_file_raw create_snap_path);
    (* Second create of gamma must fail 409 *)
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:create_body () with
     | Error (status, _) ->
       Alcotest.(check int) "duplicate keeper_create 409" 409 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "duplicate keeper_create must fail with 409");
    (* P1-3(b): Omitting expected_sha256 on dry_run:false against existing keeper -> 409 *)
    let no_cas_commit =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "dry_run", `Bool false
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "keeper.activation_mode"
                    ; "value", `String "autonomous"
                    ]
                ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:no_cas_commit () with
     | Error (status, _) ->
       Alcotest.(check int) "missing expected_sha256 on commit 409" 409 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "omitting expected_sha256 on commit to existing file must fail 409");
    (* P1-4(a): Table/newline injection -> 422 *)
    let injection_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String initial_sha
          ; "dry_run", `Bool true
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "table", `String "keeper]\n[injected"
                    ; "key", `String "evil"
                    ; "value", `String "1"
                    ]
                ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:injection_body () with
     | Error (status, _) ->
       Alcotest.(check int) "TOML table injection 422" 422 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "table newline injection must be rejected with 422");
    (* P1-4(b): Mutating keeper.name or unknown keeper.tools.deny -> 422 *)
    let rename_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String initial_sha
          ; "dry_run", `Bool true
          ; ( "changes"
            , `List
                [ `Assoc [ "key", `String "keeper.name"; "value", `String "beta" ] ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:rename_body () with
     | Error (status, _) ->
       Alcotest.(check int) "rename keeper.name 422" 422 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "mutating keeper.name must be rejected with 422");
    let bad_deny_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String initial_sha
          ; "dry_run", `Bool true
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "table", `String "keeper.tools"
                    ; "key", `String "deny"
                    ; "value", `List [ `String "nonexistent_tool_xyz" ]
                    ]
                ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:bad_deny_body () with
     | Error (status, _) ->
       Alcotest.(check int) "unknown keeper.tools.deny 422" 422 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "unknown keeper.tools.deny must be rejected with 422");
    (* P1-5(a): env override shows effective env value instead of stale runtime.toml value *)
    write_file_raw
      runtime_toml_path
      "[heartbeat]\ninterval_sec = 45\n";
    let prev_env = Sys.getenv_opt "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" in
    Unix.putenv "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" "123";
    Fun.protect
      ~finally:(fun () ->
        match prev_env with
        | Some v -> Unix.putenv "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" v
        | None -> Unix.putenv "MASC_KEEPER_HEARTBEAT_INTERVAL_SEC" "")
      (fun () ->
         let env_schema =
           Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
           |> ok_or_fail "GET schema runtime with env override"
           |> json_member_exn "data"
         in
         let fields =
           json_list_exn "categories" env_schema
           |> List.concat_map (fun c -> json_list_exn "fields" c)
         in
         let hb =
           List.find
             (fun f -> json_string_exn "full_key" f = "heartbeat.interval_sec")
             fields
         in
         Alcotest.(check string) "env_override provenance" "env_override" (json_string_exn "provenance" hb);
         Alcotest.(check int) "env_override effective value" 123 (json_int_exn "current_value" hb));
    (* P1-5(b): corrupt runtime.toml and corrupt keeper toml must surface 422, not fabricated defaults *)
    write_file_raw runtime_toml_path "[broken_unclosed_table\n";
    (match Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime () with
     | Error (status, _) ->
       Alcotest.(check int) "corrupt runtime.toml 422" 422 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "corrupt runtime.toml must fail with 422");
    write_file_raw (Filename.concat base_path ".masc/config/keepers/broken.toml") "[broken\n";
    (match Candle_cfg_api.config_schema_json ~base_path ~target:(Target_keeper "broken") () with
     | Error (status, _) ->
       Alcotest.(check int) "corrupt keeper toml 422" 422 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "corrupt keeper toml must fail with 422");
    (* P1-2: Target_runtime commit routes through Runtime.with_config_lock + commit_config_text_locked
       and updates live Runtime state + config_text_revision *)
    let rt_snap = Runtime.For_testing.snapshot () in
    let prev_catalog = Llm_provider.Catalog_snapshot.current () in
    let catalog_path = Filename.concat base_path "model-catalog.toml" in
    write_file_raw
      catalog_path
      "[[models]]\n\
       model_id = \"sample\"\n\
       provider_name = \"local\"\n\
       base = \"openai_chat\"\n\
       max_context_tokens = 1024\n\
       [[models]]\n\
       model_id = \"sample2\"\n\
       provider_name = \"local\"\n\
       base = \"openai_chat\"\n\
       max_context_tokens = 2048\n";
    let models =
      match Llm_provider.Model_catalog.load_file catalog_path with
      | Ok m -> m
      | Error msg -> Alcotest.fail ("fixture catalog failed: " ^ msg)
    in
    let test_catalog =
      match Llm_provider.Catalog_snapshot.of_catalogs ~models:(Some models) ~providers:None with
      | Ok snap -> snap
      | Error err ->
        Alcotest.fail ("of_catalogs failed: " ^ Llm_provider.Catalog_snapshot.error_to_string err)
    in
    Fun.protect
      ~finally:(fun () ->
        Llm_provider.Catalog_snapshot.publish prev_catalog;
        Runtime.For_testing.restore rt_snap)
      (fun () ->
         Llm_provider.Catalog_snapshot.publish test_catalog;
         let valid_rt_toml =
           "[providers.local]\n\
            protocol = \"openai-compatible-http\"\n\
            endpoint = \"http://127.0.0.1:1/v1\"\n\
            [models.sample]\n\
            api-name = \"sample\"\n\
            max-context = 1024\n\
            [models.sample2]\n\
            api-name = \"sample2\"\n\
            max-context = 2048\n\
            [local.sample]\n\
            [local.sample2]\n\
            [runtime]\n\
            default = \"local.sample\"\n"
         in
         write_file_raw runtime_toml_path valid_rt_toml;
         let rt_sha = Env.sha256_hex valid_rt_toml in
         let rev_before = Runtime.config_text_revision () in
         let rt_patch_body =
           Yojson.Safe.to_string
             (`Assoc
               [ "target", `String "runtime"
               ; "expected_sha256", `String rt_sha
               ; "dry_run", `Bool false
               ; ( "changes"
                 , `List
                     [ `Assoc
                         [ "key", `String "runtime.default"
                         ; "value", `String "local.sample2"
                         ]
                     ] )
               ])
         in
         let _rt_resp =
           Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:rt_patch_body ()
           |> ok_or_fail "POST patch runtime live commit"
         in
         let rev_after = Runtime.config_text_revision () in
         Alcotest.(check bool)
           "Runtime.config_text_revision advanced on runtime patch"
           true
           (rev_after > rev_before);
         Alcotest.(check string)
           "live Runtime default route hot-reloaded"
           "local.sample2"
           (Runtime.get_default_route ()));
    (* 4. POST /api/v1/config/patch dry_run:true -> unified diff, no mutation *)
    let dry_run_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String initial_sha
          ; "dry_run", `Bool true
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "keeper.activation_mode"
                    ; "value", `String "autonomous"
                    ]
                ] )
          ])
    in
    let dry_resp =
      Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:dry_run_body ()
      |> ok_or_fail "POST patch dry_run"
      |> json_member_exn "data"
    in
    Alcotest.(check bool) "dry_run true" true (json_bool_exn "dry_run" dry_resp);
    Alcotest.(check bool) "applied false" false (json_bool_exn "applied" dry_resp);
    let diff = json_string_exn "unified_diff" dry_resp in
    Alcotest.(check bool)
      "diff contains autonomous"
      true
      (contains_substr ~needle:"autonomous" diff);
    let disk_after_dry = read_file_raw keeper_toml_path in
    Alcotest.(check bool)
      "dry_run did not mutate disk"
      true
      (contains_substr ~needle:"on_demand" disk_after_dry);
    (* 5. Wrong expected_sha256 -> 409 conflict_cas *)
    let bad_cas_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String (String.make 64 'f')
          ; "dry_run", `Bool false
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "keeper.activation_mode"
                    ; "value", `String "autonomous"
                    ]
                ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:bad_cas_body () with
     | Error (status, _) ->
       Alcotest.(check int) "bad CAS 409" 409 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "wrong expected_sha256 must fail with 409");
    (* 6. Invalid enum value -> 422 validation_failed *)
    let invalid_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String initial_sha
          ; "dry_run", `Bool false
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "keeper.activation_mode"
                    ; "value", `String "not_a_real_mode"
                    ]
                ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:invalid_body () with
     | Error (status, _) ->
       Alcotest.(check int) "invalid value 422" 422 (Httpun.Status.to_code status)
     | Ok _ -> Alcotest.fail "invalid activation_mode must fail with 422");
    (* 7. dry_run:false -> atomic write via save_file_atomic + comment preservation + snapshot_id *)
    let apply_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String initial_sha
          ; "dry_run", `Bool false
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "keeper.activation_mode"
                    ; "value", `String "autonomous"
                    ]
                ] )
          ])
    in
    let apply_resp =
      Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:apply_body ()
      |> ok_or_fail "POST patch apply"
      |> json_member_exn "data"
    in
    Alcotest.(check bool) "applied true" true (json_bool_exn "applied" apply_resp);
    let snap_id = json_string_exn "snapshot_id" apply_resp in
    let snap_path = json_string_exn "snapshot_path" apply_resp in
    Alcotest.(check bool) "snapshot_id non-empty" true (String.length snap_id > 0);
    Alcotest.(check bool) "snapshot backup file exists on disk" true (Sys.file_exists snap_path);
    let disk_after_apply = read_file_raw keeper_toml_path in
    Alcotest.(check bool)
      "comment preserved after patch"
      true
      (contains_substr
         ~needle:"# Important header comment that must survive patch"
         disk_after_apply);
    Alcotest.(check bool)
      "updated activation_mode written to disk"
      true
      (contains_substr ~needle:"\"autonomous\"" disk_after_apply))
;;

let test_config_schema_registry_and_routing_failover () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    let secret_val = "sk-" ^ "ant-api03-ROUNDTRIPSECRET9876543210" in
    write_file_raw
      runtime_toml_path
      (Printf.sprintf
         "[runtime]\n\
          default = \"lane.primary\"\n\
          media_failover = [\"vision.a\", \"vision.b\"]\n\
          [runtime.assignments]\n\
          code_reviewer = \"lane.review\"\n\
          [runtime.lanes.primary]\n\
          members = [\"local.sample\"]\n\
          [routing]\n\
          strategy = \"priority\"\n\
          [assignment]\n\
          fallback_lane = \"lane.primary\"\n\
          [cascade]\n\
          max_hops = 3\n\
          [failover]\n\
          cooldown_sec = 30\n\
          [providers.openrouter]\n\
          endpoint = \"https://openrouter.ai/api/v1\"\n\
          api_key = \"%s\"\n\
          [models.sample]\n\
          max_context = 128000\n\
          [exec.ssh.endpoints.box1]\n\
          host = \"127.0.0.1\"\n\
          [voice]\n\
          enabled = true\n"
         secret_val);
    let keeper_toml_path = Filename.concat base_path ".masc/config/keepers/alpha.toml" in
    write_file_raw
      keeper_toml_path
      "[keeper]\n\
       name = \"alpha\"\n\
       instructions = \"Round-trip test keeper\"\n\
       activation_mode = \"on_demand\"\n\
       sandbox_profile = \"microvm\"\n\
       microvm_backend = \"apple_container\"\n";
    let env_vars =
      [ "MASC_KEEPER_ENABLE_THINKING"
      ; "MASC_KEEPER_BODY_TIMEOUT_SEC"
      ]
    in
    let saved_env = List.map (fun k -> k, Sys.getenv_opt k) env_vars in
    List.iter Unix.unsetenv env_vars;
    Fun.protect
      ~finally:(fun () ->
        List.iter
          (fun (k, prev) ->
             match prev with
             | Some v -> Unix.putenv k v
             | None -> Unix.unsetenv k)
          saved_env)
      (fun () ->
         (* 1. Live server runtime_schema_json with full Keeper_runtime_setting_registry.all *)
         let raw_runtime_json =
           Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
           |> ok_or_fail "GET /api/v1/config/schema?target=runtime"
         in
         Alcotest.(check bool)
           "raw server payload never leaks secret"
           false
           (contains_substr ~needle:secret_val (Yojson.Safe.to_string raw_runtime_json));
         let categories =
           json_list_exn "categories" (json_member_exn "data" raw_runtime_json)
         in
         Alcotest.(check int) "all 7 categories emitted" 7 (List.length categories);
         let raw_fields = List.concat_map (fun c -> json_list_exn "fields" c) categories in
         Alcotest.(check bool)
           "schema contains all Registry.all rows"
           true
           (List.length raw_fields >= List.length Keeper_runtime_setting_registry.all);
         let find_raw_field key =
           match
             List.find_opt (fun f -> String.equal (json_string_exn "full_key" f) key) raw_fields
           with
           | Some f -> f
           | None -> Alcotest.fail ("missing server schema field " ^ key)
         in
         (match json_member_exn "current_value" (find_raw_field "turn.enable_thinking") with
          | `Null -> ()
          | other ->
            Alcotest.fail
              ("turn.enable_thinking unset current_value must be JSON null, got "
               ^ Yojson.Safe.to_string other));
         (match json_member_exn "current_value" (find_raw_field "MASC_KEEPER_BODY_TIMEOUT_SEC") with
          | `Null -> ()
          | other ->
            Alcotest.fail
              ("MASC_KEEPER_BODY_TIMEOUT_SEC unset current_value must be JSON null, got "
               ^ Yojson.Safe.to_string other));
         (* Verify routing_failover category (Settings Tab 3) is richly populated *)
         let routing_cat =
           match
             List.find_opt
               (fun c -> String.equal (json_string_exn "id" c) "routing_failover")
               categories
           with
           | Some c -> c
           | None -> Alcotest.fail "expected routing_failover category"
         in
         let routing_keys =
           List.map (fun f -> json_string_exn "full_key" f) (json_list_exn "fields" routing_cat)
         in
         List.iter
           (fun expected_key ->
              Alcotest.(check bool)
                ("routing_failover contains " ^ expected_key)
                true
                (List.mem expected_key routing_keys))
           [ "runtime.default"
           ; "runtime.media_failover"
           ; "runtime.assignments.code_reviewer"
           ; "runtime.lanes.primary.members"
           ; "routing.strategy"
           ; "assignment.fallback_lane"
           ; "cascade.max_hops"
           ; "failover.cooldown_sec"
           ];
         (* 2. Keeper existing & keeper_create schemas emit valid targets *)
         let raw_keeper =
           Candle_cfg_api.config_schema_json ~base_path ~target:(Target_keeper "alpha") ()
           |> ok_or_fail "GET /api/v1/config/schema?target=keeper:alpha"
         in
         Alcotest.(check string)
           "keeper target emitted"
           "keeper:alpha"
           (json_string_exn "target" (json_member_exn "data" raw_keeper));
         let raw_create =
           Candle_cfg_api.config_schema_json ~base_path ~target:Target_keeper_create ()
           |> ok_or_fail "GET /api/v1/config/schema?target=keeper_create"
         in
         Alcotest.(check string)
           "keeper_create target emitted"
           "keeper_create"
           (json_string_exn "target" (json_member_exn "data" raw_create))))
;;

(* ── 6. Board signal_only, Succession Chains & 24h Dashboard Rollup ────── *)

let make_board_post ~id ~title ~post_kind ?meta_json ?successor_id () : Board.post =
  let post_id =
    match Board.Post_id.of_string id with
    | Ok pid -> pid
    | Error err -> Alcotest.fail ("bad post_id: " ^ Board.show_board_error err)
  in
  let author =
    match Board.Agent_id.of_string "tester" with
    | Ok aid -> aid
    | Error err -> Alcotest.fail ("bad author: " ^ Board.show_board_error err)
  in
  let closed =
    match successor_id with
    | None -> None
    | Some sid_str ->
      let sid =
        match Board.Post_id.of_string sid_str with
        | Ok pid -> pid
        | Error err -> Alcotest.fail ("bad successor_id: " ^ Board.show_board_error err)
      in
      Some
        Board.
          { closed_by = author
          ; closed_at = 1_760_000_000.0
          ; successor_id = Some sid
          ; summary = Some "continued"
          }
  in
  Board.
    { id = post_id
    ; author
    ; title
    ; body = "body"
    ; post_kind
    ; meta_json
    ; visibility = Board.Internal
    ; audience = None
    ; created_at = 1_760_000_000.0
    ; content_updated_at = 1_760_000_000.0
    ; updated_at = 1_760_000_000.0
    ; expires_at = 0.0
    ; votes_up = 0
    ; votes_down = 0
    ; reply_count = 0
    ; pinned = false
    ; hearth = None
    ; thread_id = None
    ; origin = None
    ; closed
    }
;;

let test_board_signal_and_succession_chains () =
  let p_human = make_board_post ~id:"p-001" ~title:"Real engineering design" ~post_kind:Board.Human_post () in
  let p_sys = make_board_post ~id:"p-002" ~title:"Heartbeat status" ~post_kind:Board.System_post () in
  let p_verify =
    make_board_post ~id:"p-003" ~title:"Verify: goal-123 run" ~post_kind:Board.Automation_post ()
  in
  let p_meta_verify =
    make_board_post
      ~id:"p-004"
      ~title:"Automated check"
      ~post_kind:Board.Automation_post
      ~meta_json:(`Assoc [ "verification_id", `String "v-1" ])
      ()
  in
  Alcotest.(check bool) "human post is signal" true (Board_http.is_signal_post p_human);
  Alcotest.(check bool) "system post filtered" false (Board_http.is_signal_post p_sys);
  Alcotest.(check bool) "Verify: title filtered" false (Board_http.is_signal_post p_verify);
  Alcotest.(check bool) "verification meta filtered" false (Board_http.is_signal_post p_meta_verify);
  (* 3-post chain + standalone + 2-node cycle *)
  let c1 = make_board_post ~id:"p-101" ~title:"Part 1" ~post_kind:Board.Human_post ~successor_id:"p-102" () in
  let c2 = make_board_post ~id:"p-102" ~title:"Part 2" ~post_kind:Board.Human_post ~successor_id:"p-103" () in
  let c3 = make_board_post ~id:"p-103" ~title:"Part 3" ~post_kind:Board.Human_post () in
  let solo = make_board_post ~id:"p-200" ~title:"Standalone" ~post_kind:Board.Human_post () in
  let cyc1 = make_board_post ~id:"p-301" ~title:"Cycle A" ~post_kind:Board.Human_post ~successor_id:"p-302" () in
  let cyc2 = make_board_post ~id:"p-302" ~title:"Cycle B" ~post_kind:Board.Human_post ~successor_id:"p-301" () in
  let chains = Board_http.compute_succession_chains [ c1; c2; c3; solo; cyc1; cyc2 ] in
  Alcotest.(check (option (pair string int)))
    "root depth 0"
    (Some ("p-101", 0))
    (Hashtbl.find_opt chains "p-101");
  Alcotest.(check (option (pair string int)))
    "hop 1 depth 1"
    (Some ("p-101", 1))
    (Hashtbl.find_opt chains "p-102");
  Alcotest.(check (option (pair string int)))
    "hop 2 depth 2"
    (Some ("p-101", 2))
    (Hashtbl.find_opt chains "p-103");
  Alcotest.(check (option (pair string int)))
    "standalone absent"
    None
    (Hashtbl.find_opt chains "p-200");
  Alcotest.(check bool) "cycle resolves safely" true (Hashtbl.mem chains "p-301")
;;

let test_board_signal_pagination_and_full_succession_chains () =
  (* 1. Pure expanding scan window + explicit cap truncation *)
  let noise_posts =
    List.init 15 (fun i ->
      make_board_post
        ~id:(Printf.sprintf "noise-%02d" i)
        ~title:(Printf.sprintf "Verify: automated check %d" i)
        ~post_kind:Board.Automation_post
        ())
  in
  let signal_posts =
    List.init 3 (fun i ->
      make_board_post
        ~id:(Printf.sprintf "sig-%02d" i)
        ~title:(Printf.sprintf "Design RFC %d" i)
        ~post_kind:Board.Human_post
        ())
  in
  let all_synthetic = noise_posts @ signal_posts in
  let fetch_slice n =
    let rec take k acc = function
      | _ when k <= 0 -> List.rev acc
      | [] -> List.rev acc
      | x :: xs -> take (k - 1) (x :: acc) xs
    in
    take n [] all_synthetic
  in
  let scan_calls = ref [] in
  let truncated_page =
    Board_http.scan_signal_page
      ~scan_cap:10
      ~exclude_automation:false
      ~offset:0
      ~limit:2
      (fun n ->
        scan_calls := n :: !scan_calls;
        fetch_slice n)
  in
  Alcotest.(check int) "cap-truncated page returns 0 signal posts" 0 (List.length truncated_page.paged);
  Alcotest.(check int) "cap-truncated filtered_out_count = 10" 10 truncated_page.filtered_out_count;
  Alcotest.(check bool) "cap-truncated has_more = false" false truncated_page.has_more;
  Alcotest.(check bool) "signal_scan_truncated = true" true truncated_page.signal_scan_truncated;
  Alcotest.(check bool) "scan window expanded before hitting cap" true (List.length !scan_calls >= 2);
  let expanded_page =
    Board_http.scan_signal_page
      ~scan_cap:50
      ~exclude_automation:false
      ~offset:0
      ~limit:2
      fetch_slice
  in
  Alcotest.(check int) "expanded scan collects full limit=2" 2 (List.length expanded_page.paged);
  Alcotest.(check int) "expanded scan counts all 15 noise posts" 15 expanded_page.filtered_out_count;
  Alcotest.(check bool) "expanded scan sees 3rd signal post -> has_more=true" true expanded_page.has_more;
  Alcotest.(check bool) "expanded scan not truncated" false expanded_page.signal_scan_truncated;
  (* 2. End-to-end payload: interleaved noise pagination + full-board succession chains *)
  with_temp_workspace (fun config ->
    Eio_main.run (fun _env ->
      Fun.protect
        ~finally:Board_dispatch.reset_for_test
        (fun () ->
           Board_dispatch.reset_for_test ();
           (match
              Board_dispatch.init_jsonl
                ~base_path:config.Workspace.base_path
                ~recipient_lookup:Recipient_lookup.none_declared
                ()
            with
            | Ok () -> ()
            | Error _ -> Alcotest.fail "Board_dispatch.init_jsonl failed");
           let create ~title ~post_kind ?meta_json () =
             Unix.sleepf 0.005;
             match
               Board_dispatch.create_post
                 ~author:"operator"
                 ~title
                 ~content:title
                 ~post_kind
                 ?meta_json
                 ()
             with
             | Ok p -> Board.Post_id.to_string p.id
             | Error _ -> Alcotest.fail ("Board_dispatch.create_post failed for " ^ title)
           in
           (* Interleave 8 noise posts with 4 real signal posts (oldest -> newest) *)
           let s1 = create ~title:"Signal 1" ~post_kind:Board.Human_post () in
           ignore (create ~title:"System tick 1" ~post_kind:Board.System_post ());
           ignore (create ~title:"Verify: run 1" ~post_kind:Board.Automation_post ());
           let s2 = create ~title:"Signal 2" ~post_kind:Board.Human_post () in
           ignore
             (create
                ~title:"Meta check 1"
                ~post_kind:Board.Automation_post
                ~meta_json:(`Assoc [ "verification_id", `String "v-101" ])
                ());
           ignore (create ~title:"System tick 2" ~post_kind:Board.System_post ());
           let s3 = create ~title:"Signal 3" ~post_kind:Board.Human_post () in
           ignore (create ~title:"Verify: run 2" ~post_kind:Board.Automation_post ());
           ignore (create ~title:"[system] notice" ~post_kind:Board.Automation_post ());
           let s4 = create ~title:"Signal 4" ~post_kind:Board.Human_post () in
           ignore (create ~title:"System tick 3" ~post_kind:Board.System_post ());
           ignore (create ~title:"Verify: run 3" ~post_kind:Board.Automation_post ());
           Dashboard_cache.invalidate_all ();
           let chain_key =
             Board_http.succession_chains_cache_key
               ~reader:Masc_board_handlers.Board_access.Operator
               ~base_path:(Some config.Workspace.base_path)
           in
           Alcotest.(check bool)
             "chain cache starts empty"
             true
             (Option.is_none (Dashboard_cache.peek chain_key));
           (* Page 1: signal_only=true&offset=0&limit=2 must return full 2 signal posts [s4; s3] *)
           let p1 =
             (Board_http.payload
                ~config
                ~reader:Masc_board_handlers.Board_access.Operator
                ~reaction_actor:None
                (make_request "/api/v1/board?signal_only=true&sort_by=recent&offset=0&limit=2"))
               .json
           in
           let cached_chain_v1 =
             match Dashboard_cache.peek chain_key with
             | Some v -> v
             | None -> Alcotest.fail "expected shared board:chains cache entry after page 1"
           in
           let p1_ids = json_list_exn "posts" p1 |> List.map (json_string_exn "id") in
           Alcotest.(check (list string)) "signal page 1 returns [s4; s3]" [ s4; s3 ] p1_ids;
           Alcotest.(check int) "signal page 1 count = 2" 2 (json_int_exn "count" p1);
           Alcotest.(check bool) "signal page 1 has_more = true" true (json_bool_exn "has_more" p1);
           Alcotest.(check bool)
             "signal page 1 not truncated"
             false
             (json_bool_exn "signal_scan_truncated" p1);
           Alcotest.(check bool)
             "signal page 1 filtered_out_count > 0"
             true
             (json_int_exn "filtered_out_count" p1 > 0);
           (* Page 2: signal_only=true&offset=2&limit=2 must return [s2; s1] with has_more=false
              and reuse the shared board:chains entry without rescanning *)
           let p2 =
             (Board_http.payload
                ~config
                ~reader:Masc_board_handlers.Board_access.Operator
                ~reaction_actor:None
                (make_request "/api/v1/board?signal_only=true&sort_by=recent&offset=2&limit=2"))
               .json
           in
           let p2_ids = json_list_exn "posts" p2 |> List.map (json_string_exn "id") in
           Alcotest.(check (list string)) "signal page 2 returns [s2; s1]" [ s2; s1 ] p2_ids;
           Alcotest.(check int) "signal page 2 filtered_out_count = 8" 8 (json_int_exn "filtered_out_count" p2);
           Alcotest.(check bool) "signal page 2 has_more = false" false (json_bool_exn "has_more" p2);
           Alcotest.(check bool)
             "signal page 2 not truncated"
             false
             (json_bool_exn "signal_scan_truncated" p2);
           Alcotest.(check bool)
             "page 2 reuses shared chain cache entry"
             true
             (match Dashboard_cache.peek chain_key with
              | Some v -> v == cached_chain_v1
              | None -> false);
           (* Non-signal pagination with different sort_by also shares the chain entry *)
           let raw_p1 =
             (Board_http.payload
                ~config
                ~reader:Masc_board_handlers.Board_access.Operator
                ~reaction_actor:None
                (make_request "/api/v1/board?signal_only=false&sort_by=hot&offset=0&limit=2"))
               .json
           in
           Alcotest.(check int) "raw page count = 2" 2 (json_int_exn "count" raw_p1);
           Alcotest.(check bool) "raw page has_more = true" true (json_bool_exn "has_more" raw_p1);
           Alcotest.(check bool)
             "different sort_by/signal_only reuses shared chain cache entry"
             true
             (match Dashboard_cache.peek chain_key with
              | Some v -> v == cached_chain_v1
              | None -> false);
           (* 3. Full-board succession chain A -> B -> C queried with limit=1 (root A outside page) *)
           let id_a = create ~title:"Chain A (root)" ~post_kind:Board.Human_post () in
           let id_b = create ~title:"Chain B (hop 1)" ~post_kind:Board.Human_post () in
           let id_c = create ~title:"Chain C (latest)" ~post_kind:Board.Human_post () in
           (match
              Board_dispatch.set_closed
                ~post_id:id_a
                ~closed_by:"operator"
                ~successor:(Board.Successor id_b)
                ~summary:"continued in B"
                ()
            with
            | Ok () -> ()
            | Error _ -> Alcotest.fail "set_closed A -> B failed");
           (match
              Board_dispatch.set_closed
                ~post_id:id_b
                ~closed_by:"operator"
                ~successor:(Board.Successor id_c)
                ~summary:"continued in C"
                ()
            with
            | Ok () -> ()
            | Error _ -> Alcotest.fail "set_closed B -> C failed");
           (* Board write invalidation must drop the shared board:chains: entry *)
           Server_dashboard_http_core_cache.invalidate_board_projections ();
           Alcotest.(check bool)
             "invalidate_board_projections drops board:chains entry"
             true
             (Option.is_none (Dashboard_cache.peek chain_key));
           let chain_page =
             (Board_http.payload
                ~config
                ~reader:Masc_board_handlers.Board_access.Operator
                ~reaction_actor:None
                (make_request "/api/v1/board?sort_by=recent&offset=0&limit=1"))
               .json
           in
           Alcotest.(check string)
             "succession_chain_scope = full"
             "full"
             (json_string_exn "succession_chain_scope" chain_page);
           Alcotest.(check bool) "limit=1 has_more = true" true (json_bool_exn "has_more" chain_page);
           let latest_posts = json_list_exn "posts" chain_page in
           Alcotest.(check int) "only latest post C in page window" 1 (List.length latest_posts);
           let post_c = List.hd latest_posts in
           Alcotest.(check string) "page contains C" id_c (json_string_exn "id" post_c);
           Alcotest.(check string)
             "C resolves root A outside limit=1 window"
             id_a
             (json_string_exn "succession_chain_root_id" post_c);
           Alcotest.(check int)
             "C resolves true chain_depth = 2"
             2
             (json_int_exn "chain_depth" post_c))))
;;

let test_board_succession_chains_shared_cache_and_bounded_scope () =
  Alcotest.(check int)
    "chain_scan_cap matches signal_scan_cap (2000)"
    Board_http.signal_scan_cap
    Board_http.chain_scan_cap;
  Alcotest.(check int) "chain_scan_cap = 2000" 2000 Board_http.chain_scan_cap;
  Dashboard_cache.invalidate_all ();
  let reader = Masc_board_handlers.Board_access.Operator in
  let base_path = Some "/tmp/board-chains-unit" in
  let c1 = make_board_post ~id:"b-1" ~title:"Root" ~post_kind:Board.Human_post ~successor_id:"b-2" () in
  let c2 = make_board_post ~id:"b-2" ~title:"Hop 1" ~post_kind:Board.Human_post ~successor_id:"b-3" () in
  let c3 = make_board_post ~id:"b-3" ~title:"Hop 2" ~post_kind:Board.Human_post () in
  let fetch_calls = ref 0 in
  let fetch_bounded limit =
    incr fetch_calls;
    let all = [ c3; c2; c1 ] in
    let rec take_n k acc = function
      | _ when k <= 0 -> List.rev acc
      | [] -> List.rev acc
      | x :: xs -> take_n (k - 1) (x :: acc) xs
    in
    take_n limit [] all
  in
  (* 3 posts > scan_cap=2 -> Chain_scope_bounded, truncated to 2 posts, cached *)
  let scope1, chains1 =
    Board_http.cached_succession_chains
      ~scan_cap:2
      ~fetch:fetch_bounded
      ~reader
      ~base_path
      ()
  in
  Alcotest.(check string)
    "exceeding cap yields bounded scope"
    "bounded"
    (Board_http.succession_chain_scope_to_string scope1);
  Alcotest.(check int) "first call invokes fetch once" 1 !fetch_calls;
  Alcotest.(check (option (pair string int)))
    "bounded window still links c2 -> c3"
    (Some ("b-2", 1))
    (Hashtbl.find_opt chains1 "b-3");
  (* Second call for same reader/base_path reuses cached entry without calling fetch *)
  let scope2, chains2 =
    Board_http.cached_succession_chains
      ~scan_cap:2
      ~fetch:fetch_bounded
      ~reader
      ~base_path
      ()
  in
  Alcotest.(check string)
    "cached second call preserves bounded scope"
    "bounded"
    (Board_http.succession_chain_scope_to_string scope2);
  Alcotest.(check int) "second call does not rescan" 1 !fetch_calls;
  Alcotest.(check (option (pair string int)))
    "cached second call returns same chain depth"
    (Some ("b-2", 1))
    (Hashtbl.find_opt chains2 "b-3");
  (* Board write invalidation forces a fresh scan on next read *)
  Server_dashboard_http_core_cache.invalidate_board_projections ();
  let scope3, chains3 =
    Board_http.cached_succession_chains
      ~scan_cap:3
      ~fetch:fetch_bounded
      ~reader
      ~base_path
      ()
  in
  Alcotest.(check string)
    "after invalidation with cap=3 yields full scope"
    "full"
    (Board_http.succession_chain_scope_to_string scope3);
  Alcotest.(check int) "invalidated call rescans once" 2 !fetch_calls;
  Alcotest.(check (option (pair string int)))
    "full scope resolves c3 back to root b-1 depth 2"
    (Some ("b-1", 2))
    (Hashtbl.find_opt chains3 "b-3");
  Dashboard_cache.invalidate_all ()
;;

let test_dashboard_24h_rollup_and_groups () =
  let now = 1_760_000_000.0 in
  let recent_iso = Masc_domain.iso8601_of_unix_seconds (now -. 3600.0) in
  let old_iso = Masc_domain.iso8601_of_unix_seconds (now -. 172_800.0) in
  let make_task id status : Masc_domain.task =
    { id
    ; title = id
    ; description = ""
    ; task_status = status
    ; priority = 3
    ; files = []
    ; created_at = old_iso
    ; created_by = None
    ; predecessor_task_id = None
    ; contract = None
    ; execution_links = Masc_domain.no_execution_links
    ; handoff_context = None
    ; cycle_count = 0
    ; skills = []
    }
  in
  let tasks =
    [ make_task "t1" (Masc_domain.Done { assignee = "a"; completed_at = recent_iso; notes = None })
    ; make_task "t2" (Masc_domain.Done { assignee = "a"; completed_at = old_iso; notes = None })
    ; make_task "t3" (Masc_domain.InProgress { assignee = "a"; started_at = recent_iso })
    ; make_task "t4" Masc_domain.Todo
    ]
  in
  let rollup = Server_dashboard_http_core.tasks_24h_rollup_json ~now tasks in
  Alcotest.(check int) "tasks_done_24h" 1 (json_int_exn "tasks_done_24h" rollup);
  Alcotest.(check int) "tasks_done_total" 2 (json_int_exn "tasks_done_total" rollup);
  Alcotest.(check int) "tasks_in_progress" 1 (json_int_exn "tasks_in_progress" rollup);
  Alcotest.(check int) "tasks_todo" 1 (json_int_exn "tasks_todo" rollup);
  let groups =
    Server_dashboard_http_core.keeper_groups_json
      [ "infra-ssh", Some "infra"
      ; "infra-vm", Some "  infra  "
      ; "solo", None
      ; "wiki-curator", Some "knowledge"
      ]
  in
  match groups with
  | `List rows ->
    let pairs =
      List.map (fun r -> json_string_exn "group" r, json_int_exn "keeper_count" r) rows
    in
    Alcotest.(check (list (pair string int)))
      "3 distinct groups sorted alphabetically with ungrouped last"
      [ "infra", 2; "knowledge", 1; "ungrouped", 1 ]
      pairs
  | _ -> Alcotest.fail "expected list of groups"
;;

let test_v25_neutral_keeper_groups_and_config_entity_metadata () =
  (* 1. Deployment-neutral keeper grouping uses explicit [keeper.group] (trimmed),
     falls back to "ungrouped", sorts named groups alphabetically with "ungrouped"
     last, and never relies on hardcoded deployment names. *)
  let sample_entries =
    [ "keeper-z", Some "  zeta  "
    ; "keeper-a2", Some "alpha"
    ; "keeper-a1", Some "alpha"
    ; "keeper-blank", Some "   "
    ; "keeper-empty", Some ""
    ; "keeper-none", None
    ; "keeper-b", Some "beta"
    ]
  in
  (match Server_dashboard_http_core.keeper_groups_json sample_entries with
   | `List rows ->
     let summary =
       List.map
         (fun r ->
            ( json_string_exn "group" r
            , json_int_exn "keeper_count" r
            , List.map
                (function `String s -> s | _ -> Alcotest.fail "expected keeper string")
                (json_list_exn "keepers" r) ))
         rows
     in
     Alcotest.(check (list (triple string int (list string))))
       "named groups alphabetical, ungrouped last, members sorted"
       [ "alpha", 2, [ "keeper-a1"; "keeper-a2" ]
       ; "beta", 1, [ "keeper-b" ]
       ; "zeta", 1, [ "keeper-z" ]
       ; "ungrouped", 3, [ "keeper-blank"; "keeper-empty"; "keeper-none" ]
       ]
       summary
   | _ -> Alcotest.fail "expected JSON list of groups");
  (* 1b. TOML [keeper.group] flows through Keeper_types_profile snapshot cleanly. *)
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let keepers_dir = Filename.concat base_path ".masc/config/keepers" in
    write_file_raw
      (Filename.concat keepers_dir "k-plat.toml")
      "[keeper]\nname = \"k-plat\"\ngroup = \"platform\"\ninstructions = \"p\"\n";
    write_file_raw
      (Filename.concat keepers_dir "k-ana.toml")
      "[keeper]\nname = \"k-ana\"\ngroup = \"  analytics  \"\ninstructions = \"a\"\n";
    write_file_raw
      (Filename.concat keepers_dir "k-blank.toml")
      "[keeper]\nname = \"k-blank\"\ngroup = \"   \"\ninstructions = \"b\"\n";
    write_file_raw
      (Filename.concat keepers_dir "k-plain.toml")
      "[keeper]\nname = \"k-plain\"\ninstructions = \"c\"\n";
    let snap = Keeper_types_profile.read_keeper_profile_snapshot ~base_path in
    let names = Keeper_types_profile.snapshot_configured_keeper_names snap in
    let entries =
      List.map
        (fun name ->
           let group =
             match Keeper_types_profile.snapshot_profile_defaults snap name with
             | Ok d -> d.group
             | Error err ->
               Alcotest.fail
                 ("unexpected keeper TOML load error: "
                  ^ Keeper_types_profile.keeper_toml_load_error_to_string err)
           in
           name, group)
        names
    in
    match Server_dashboard_http_core.keeper_groups_json entries with
    | `List rows ->
      let pairs =
        List.map (fun r -> json_string_exn "group" r, json_int_exn "keeper_count" r) rows
      in
      Alcotest.(check (list (pair string int)))
        "TOML keeper.group snapshot grouping"
        [ "analytics", 1; "platform", 1; "ungrouped", 2 ]
        pairs
    | _ -> Alcotest.fail "expected JSON list of groups from TOML snapshot");
  (* 2. Server runtime schema recategorization (no catch-all leaks) +
     provider entity metadata merging [providers.<id>] with [<id>.*]. *)
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    write_file_raw
      runtime_toml_path
      "[providers.openrouter]\n\
       display-name = \"OpenRouter\"\n\
       base-url = \"https://openrouter.ai/api/v1\"\n\
       [openrouter.sonnet]\n\
       model = \"anthropic/claude-sonnet-4.6\"\n\
       [models.sample]\n\
       max_context = 128000\n\
       [models.\"gpt-5.6\"]\n\
       max_context = 256000\n\
       [models.\"gemini-2.5-pro\"]\n\
       max_context = 1000000\n\
       [providers.openrouter.headers]\n\
       \"x-api.version\" = \"2026-01\"\n\
       [fusion]\n\
       enabled = true\n\
       [slack]\n\
       enabled = false\n\
       [discord]\n\
       enabled = false\n\
       [browser]\n\
       headless = true\n\
       [typesafeai]\n\
       strict = true\n\
       [web_search]\n\
       enabled = true\n\
       [skills]\n\
       auto_load = true\n\
       [repositories]\n\
       max_depth = 3\n\
       [turn]\n\
       max_retries = 2\n\
       [wire_capture]\n\
       enabled = false\n\
       [tui]\n\
       theme = \"midnight\"\n";
    let schema =
      Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
      |> ok_or_fail "GET v25 runtime schema"
    in
    let categories = json_list_exn "categories" (json_member_exn "data" schema) in
    let find_cat_of full_key =
      List.find_map
        (fun cat ->
           let cid = json_string_exn "id" cat in
           let fields = json_list_exn "fields" cat in
           List.find_map
             (fun f ->
                if String.equal (json_string_exn "full_key" f) full_key
                then Some (cid, f)
                else None)
             fields)
        categories
    in
    let assert_cat key expected_cat =
      match find_cat_of key with
      | Some (cid, _) ->
        Alcotest.(check string) ("category of " ^ key) expected_cat cid
      | None -> Alcotest.fail ("missing field in runtime schema: " ^ key)
    in
    assert_cat "fusion.enabled" "routing_failover";
    assert_cat "slack.enabled" "economy_connectors";
    assert_cat "discord.enabled" "economy_connectors";
    assert_cat "browser.headless" "economy_connectors";
    assert_cat "typesafeai.strict" "memory_knowledge";
    assert_cat "web_search.enabled" "memory_knowledge";
    assert_cat "skills.auto_load" "memory_knowledge";
    assert_cat "repositories.max_depth" "memory_knowledge";
    assert_cat "turn.max_retries" "keepers_autonomy";
    assert_cat "wire_capture.enabled" "observability_ops";
    assert_cat "tui.theme" "observability_ops";
    let _, prov_field = Option.get (find_cat_of "providers.openrouter.base-url") in
    let _, bind_field = Option.get (find_cat_of "openrouter.sonnet.model") in
    Alcotest.(check string)
      "provider entity_group"
      "provider:openrouter"
      (json_string_exn "entity_group" prov_field);
    Alcotest.(check string)
      "binding merged into provider entity_group"
      "provider:openrouter"
      (json_string_exn "entity_group" bind_field);
    Alcotest.(check string)
      "provider display-name propagated to binding entity_title"
      "OpenRouter"
      (json_string_exn "entity_title" bind_field);
    Alcotest.(check string)
      "human leaf label on base-url"
      "Base URL"
      (json_string_exn "label" prov_field);
    (* #143 P1-3: quoted dotted TOML tables & keys survive split_table_key intact *)
    let _, gpt56_field =
      Option.get (find_cat_of "models.\"gpt-5.6\".max_context")
    in
    Alcotest.(check string)
      "quoted model table preserved"
      "models.\"gpt-5.6\""
      (json_string_exn "table" gpt56_field);
    Alcotest.(check string)
      "quoted model entity_group"
      "model:gpt-5.6"
      (json_string_exn "entity_group" gpt56_field);
    let _, hdr_field =
      Option.get (find_cat_of "providers.openrouter.headers.\"x-api.version\"")
    in
    Alcotest.(check string)
      "quoted dotted header key preserved intact"
      "\"x-api.version\""
      (json_string_exn "key" hdr_field))
;;

let () =
  Alcotest.run
    "server_tui_v2_api"
    [ ( "guard_headers"
      , [ Alcotest.test_case "X-Masc-Expected-Instance/Workspace" `Quick test_workspace_guard_headers ] )
    ; ( "wiki_api"
      , [ Alcotest.test_case "CRUD, CAS, search, log, lint" `Quick test_wiki_api_roundtrip_and_lint ] )
    ; ( "infra_sandboxes"
      , [ Alcotest.test_case "non-blocking fleet + 24h failures" `Quick test_infra_sandboxes_api ] )
    ; ( "memory_v2"
      , [ Alcotest.test_case "world conflicts + keeper diff + heat" `Quick test_memory_v2_world_and_diff ] )
    ; ( "candle_and_config"
      , [ Alcotest.test_case "candle ledger root-cause diagnostics" `Quick test_candle_ledger_diagnostics
        ; Alcotest.test_case "config schema redaction + atomic patch" `Quick test_config_schema_redaction_and_patch_roundtrip
        ; Alcotest.test_case "config schema registry + routing_failover categories" `Quick test_config_schema_registry_and_routing_failover
        ] )
    ; ( "signal_and_scorecard"
      , [ Alcotest.test_case "board signal_only + succession chains" `Quick test_board_signal_and_succession_chains
        ; Alcotest.test_case "board signal_only expanding pagination + full-board succession chains" `Quick test_board_signal_pagination_and_full_succession_chains
        ; Alcotest.test_case "board succession chains shared cache + bounded scope" `Quick test_board_succession_chains_shared_cache_and_bounded_scope
        ; Alcotest.test_case "dashboard 24h rollup + groups" `Quick test_dashboard_24h_rollup_and_groups
        ; Alcotest.test_case "v2.5 neutral keeper.group grouping + config entity metadata" `Quick test_v25_neutral_keeper_groups_and_config_entity_metadata
        ] )
    ]
;;
