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
    let dummy_log_id = Keeper_turn_log.Log_id.fresh () in
    let dummy_mark : Keeper_turn_log.mark =
      { trace = ""
      ; closed_messages = 0
      ; session = ""
      ; history_bytes = 0
      ; internal_bytes = 0
      ; chat_bytes = 0
      ; external_rows = 0
      }
    in
    let commit_and_write ~keeper_id ~at ~revision ~source ~cause ~added ~removed ~facts =
      let snap : Keeper_memory_os_current.t =
        { revision
        ; updated_at = at
        ; source
        ; facts
        ; change =
            { added
            ; removed = List.map fst removed
            ; retained = max 0 (List.length facts - List.length added)
            ; invalidated = []
            }
        }
      in
      let snap_bytes =
        Yojson.Safe.pretty_to_string (Keeper_memory_os_current.to_json snap) ^ "\n"
      in
      write_file_raw
        (Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id)
        snap_bytes;
      let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
      let at_end =
        match Librarian_log_store.read_tail log_path with
        | Ok Librarian_log_store.Nothing_written -> 0
        | Ok (Librarian_log_store.Written { rows_end; _ }) -> rows_end
        | Error _ -> 0
      in
      let digest = Agent_core.Checkpoint_objects.digest_of_bytes snap_bytes in
      let commit : Librarian_log.commit =
        { seq = revision
        ; at
        ; basis = digest
        ; after = digest
        ; revision
        ; cause
        ; effects = { Librarian_effects.empty with added; removed }
        ; turn_log = dummy_log_id
        ; turn_log_offset = 0
        ; covers_through = Librarian_log.Before_first
        ; covered = dummy_mark
        ; working_state = None
        }
      in
      match Librarian_log_store.append ~path:log_path ~at_end (Librarian_log.Committed commit) with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail ("commit log append failed for " ^ keeper_id)
    in
    let direct_remember (f : Keeper_memory_os_types.fact) =
      Librarian_log.Direct
        { by = Librarian_effects.Keeper
        ; trace = "trace-1"
        ; write =
            Librarian_direct.Remember
              { claim = f.claim; category = f.category; basis = f.basis }
        }
    in
    commit_and_write
      ~keeper_id:"alpha"
      ~at:(now -. 300.0)
      ~revision:1
      ~source
      ~cause:(direct_remember f1)
      ~added:[ f1 ]
      ~removed:[]
      ~facts:[ f1 ];
    commit_and_write
      ~keeper_id:"alpha"
      ~at:(now -. 250.0)
      ~revision:2
      ~source
      ~cause:(direct_remember f2)
      ~added:[ f2 ]
      ~removed:[]
      ~facts:[ f1; f2 ];
    commit_and_write
      ~keeper_id:"alpha"
      ~at:(now -. 200.0)
      ~revision:3
      ~source
      ~cause:
        (Librarian_log.Direct
           { by = Librarian_effects.Keeper
           ; trace = "trace-1"
           ; write =
               Librarian_direct.Supersede
                 { old = f1_id
                 ; claim = f1_v2.claim
                 ; category = f1_v2.category
                 ; basis = f1_v2.basis
                 }
           })
      ~added:[ f1_v2 ]
      ~removed:[ f1, Librarian_effects.Superseded_by f1_v2_id ]
      ~facts:[ f2; f1_v2 ];
    commit_and_write
      ~keeper_id:"alpha"
      ~at:(now -. 100.0)
      ~revision:4
      ~source:{ kind = Explicit_retract; trace_id = "trace-2" }
      ~cause:
        (Librarian_log.Direct
           { by = Librarian_effects.Keeper
           ; trace = "trace-2"
           ; write =
               Librarian_direct.Retract
                 { id = f2_id; reason = "obsolete scratch note" }
           })
      ~added:[]
      ~removed:
        [ f2
        , Librarian_effects.Retracted
            { by = Librarian_effects.Keeper; reason = "obsolete scratch note" }
        ]
      ~facts:[ f1_v2 ];
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
    commit_and_write
      ~keeper_id:"beta"
      ~at:(now -. 150.0)
      ~revision:1
      ~source
      ~cause:(direct_remember beta_f)
      ~added:[ beta_f ]
      ~removed:[]
      ~facts:[ beta_f ];
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
    commit_and_write
      ~keeper_id:"alpha"
      ~at:(now -. 120.0)
      ~revision:5
      ~source
      ~cause:(direct_remember claim_f)
      ~added:[ claim_f ]
      ~removed:[]
      ~facts:[ f1_v2; claim_f ];
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
    let module Wire = Masc_tui_protocol.Wire_config in
    let activation_patch ~dry_run =
      Wire.encode_patch_request
        { target = Target_keeper "alpha"; keeper_name = Some "alpha";
          expected_sha256 = Some initial_sha; dry_run;
          ops = [Set_scalar { table = "keeper"; key = "activation_mode"; value = "autonomous" }] }
      |> Yojson.Safe.to_string
    in
    let dry_run_body = activation_patch ~dry_run:true in
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
    let apply_body = activation_patch ~dry_run:false in
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
    let saved =
      Candle_cfg_api.config_schema_json ~base_path ~target:(Target_keeper "alpha") ()
      |> ok_or_fail "read saved Keeper configuration"
      |> Wire.decode_config_schema
      |> Result.fold ~ok:Fun.id ~error:(fun detail -> Alcotest.fail detail)
    in
    Alcotest.(check string) "the read-back revision matches the commit"
      (json_string_exn "new_sha256" apply_resp) saved.file_sha256;
    let saved_field =
      List.concat_map (fun (section : Wire.schema_section) -> section.fields) saved.sections
      |> List.find_opt (fun (field : Wire.schema_field) -> field.full_key = "keeper.activation_mode")
    in
    Alcotest.(check bool) "the saved Keeper now uses autonomous activation" true
      (Option.map (fun (field : Wire.schema_field) -> field.value) saved_field = Some (Wire.Val_string "autonomous")))
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
      let reset_board () =
        Board_dispatch.reset_for_test ();
        Board.reset_global_for_test ()
      in
      Fun.protect
        ~finally:reset_board
        (fun () ->
           reset_board ();
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

(* ── 7. Track A Red-Team Audit Fixes (A3, A4, A5, A6, A7) ─────────────── *)

let test_track_a_scorecard_and_capabilities () =
  let now = 1_760_000_000.0 in
  (* Empty registry returns None (never fabricates 0/0) *)
  Alcotest.(check (option (pair int int)))
    "empty verification runs -> None"
    None
    (Server_dashboard_http_core.verifications_24h_of_runs ~now []);
  let make_run ~id ~started_at status : Masc.Verification_run_registry.run =
    { verification_id = id
    ; task_id = "task-" ^ id
    ; producer = "alpha"
    ; authority_kind = "system_verifier"
    ; authority_actor = "verifier"
    ; started_at
    ; status
    }
  in
  let runs =
    [ make_run ~id:"v1" ~started_at:(now -. 3600.0)
        (Masc.Verification_run_registry.Completed
           { outcome = Approved { reason = "ok" }
           ; evaluator_runtime = None
           ; elapsed_s = 10.0
           ; tools = []
           })
    ; make_run ~id:"v2" ~started_at:(now -. 1800.0)
        (Masc.Verification_run_registry.Completed
           { outcome = Rejected { reason = "missing proof" }
           ; evaluator_runtime = None
           ; elapsed_s = 5.0
           ; tools = []
           })
    ; make_run ~id:"v3" ~started_at:(now -. 172_800.0)
        (Masc.Verification_run_registry.Completed
           { outcome = Approved { reason = "stale" }
           ; evaluator_runtime = None
           ; elapsed_s = 1.0
           ; tools = []
           })
    ; make_run ~id:"v4" ~started_at:(now -. 100.0) Masc.Verification_run_registry.Running
    ]
  in
  Alcotest.(check (option (pair int int)))
    "trailing 24h passed/rejected counts"
    (Some (1, 1))
    (Server_dashboard_http_core.verifications_24h_of_runs ~now runs);
  (* Capabilities advertised on shell payload and bootstrap, NOT on unauthenticated public health *)
  let expected_caps =
    [ "memory_v2"; "infra_sandboxes"; "candle_ledger"; "config_schema"; "task_goal_link" ]
  in
  Alcotest.(check (list string))
    "Server_health_public.capabilities list"
    expected_caps
    Server_health_public.capabilities;
  let pub_health =
    Server_health_public.health_json
      ~dev_token:true
      ~ready:true
      ~phase:Masc.Server_startup_state.Ready
  in
  Alcotest.(check bool)
    "unauthenticated public health_json stays strictly 6 keys and omits account_mode"
    true
    (match pub_health with
     | `Assoc fs ->
       List.length fs = 6
       && (not (List.mem_assoc "account_mode" fs))
       && (match List.assoc_opt "auth_methods" fs with
           | Some (`Assoc [ ("google", `Bool false); ("github", `Bool false); ("dev_token", `Bool true) ])
             -> true
           | _ -> false)
     | _ -> false);
  let pub_health_strict =
    Server_health_public.health_json
      ~dev_token:false
      ~ready:true
      ~phase:Masc.Server_startup_state.Ready
  in
  Alcotest.(check bool)
    "strict single-user public health_json advertises dev_token=false and omits account_mode"
    true
    (match pub_health_strict with
     | `Assoc fs ->
       (not (List.mem_assoc "account_mode" fs))
       && (match List.assoc_opt "auth_methods" fs with
           | Some (`Assoc [ ("google", `Bool false); ("github", `Bool false); ("dev_token", `Bool false) ])
             -> true
           | _ -> false)
     | _ -> false);
  with_temp_workspace (fun config ->
    let boot =
      Server_dashboard_http_core_shell_bootstrap.dashboard_shell_bootstrap_json config
    in
    let boot_caps =
      json_list_exn "capabilities" boot
      |> List.map (function `String s -> s | _ -> "")
    in
    Alcotest.(check (list string)) "bootstrap shell capabilities" expected_caps boot_caps;
    let shell = Server_dashboard_http_core.dashboard_shell_payload_json ~light:true config in
    let shell_caps =
      json_list_exn "capabilities" shell
      |> List.map (function `String s -> s | _ -> "")
    in
    Alcotest.(check (list string)) "shell payload capabilities" expected_caps shell_caps;
    let sc = json_member_exn "scorecard_24h" shell in
    (* All four additive keys present; null when unobserved in fresh workspace *)
    List.iter
      (fun k ->
         Alcotest.(check bool)
           ("scorecard_24h has key " ^ k)
           true
           (match sc with `Assoc fs -> List.mem_assoc k fs | _ -> false))
      [ "verifications_passed_24h"
      ; "verifications_rejected_24h"
      ; "board_posts_24h"
      ; "cost_24h_usd"
      ];
    (* Non-light mode observes recent unvoted board posts via Board_dispatch.Recent *)
    Eio_main.run (fun _env ->
      let reset_board () =
        Board_dispatch.reset_for_test ();
        Board.reset_global_for_test ()
      in
      Fun.protect
        ~finally:reset_board
        (fun () ->
           reset_board ();
           (match
              Board_dispatch.init_jsonl
                ~base_path:config.Workspace.base_path
                ~recipient_lookup:Recipient_lookup.none_declared
                ()
            with
            | Ok () -> ()
            | Error _ -> Alcotest.fail "Board_dispatch.init_jsonl failed");
           (match
              Board_dispatch.create_post
                ~author:"operator"
                ~title:"Recent unvoted post"
                ~content:"fresh signal"
                ~post_kind:Board.Human_post
                ()
            with
            | Ok _ -> ()
            | Error _ -> Alcotest.fail "Board_dispatch.create_post failed");
           let full_shell =
             Server_dashboard_http_core.dashboard_shell_payload_json ~light:false config
           in
           let full_sc = json_member_exn "scorecard_24h" full_shell in
           Alcotest.(check int)
             "board_posts_24h counts recent unvoted post in non-light mode"
             1
             (json_int_exn "board_posts_24h" full_sc);
           let light_shell =
             Server_dashboard_http_core.dashboard_shell_payload_json ~light:true config
           in
           let light_sc = json_member_exn "scorecard_24h" light_shell in
           Alcotest.(check bool)
             "board_posts_24h stays null in light mode"
             true
             (json_member_exn "board_posts_24h" light_sc = `Null))))
;;

let test_track_a_memory_diff_human_claim_text () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let now = 1_760_100_000.0 in
    let ts_iso = Masc_domain.iso8601_of_unix_seconds (now -. 300.0) in
    let fact_claim = "OCaml 5.5 Eio server uses single-domain cooperative scheduling" in
    let sha = Env.sha256_hex fact_claim in
    let fact_ref = Workspace_memory_ledger.Ordinary { keeper_id = "alpha"; claim_sha256 = sha } in
    let ledger =
      match
        Workspace_memory_ledger.apply
          Workspace_memory_ledger.empty
          ~selected:[ { Workspace_memory_ledger.fact = fact_ref; claim = fact_claim } ]
          [ { Workspace_memory_ledger.fact = fact_ref
            ; decision = Workspace_memory_ledger.Create_claim fact_claim
            }
          ]
      with
      | Ok l -> l
      | Error err -> Alcotest.fail (Workspace_memory_ledger.apply_error_to_string err)
    in
    (match Workspace_memory_ledger.save ~base_path ledger with
     | Ok () -> ()
     | Error err -> Alcotest.fail err);
    let claim_id = fst (List.hd (Workspace_memory_ledger.claims ledger)) in
    let retracted_id = "claim-retracted-deadbeef" in
    let retracted_text = "Stale hypothesis removed after verification" in
    let log_path = Workspace_memory_log.log_path ~base_path in
    (match
       Workspace_memory_log.append_batch
         ~path:log_path
         ~header:
           { batch_id = "batch-human-1"
           ; author = "workspace-memory-curator"
           ; started_at = ts_iso
           ; expected_changes = 4
           }
         ~changes:
           [ { seq = 1
             ; batch_id = "batch-human-1"
             ; fact_id = "claim:" ^ claim_id
             ; summary = Printf.sprintf "Joined claim %s" claim_id
             ; payload =
                 `Assoc
                   [ "kind", `String "claim_joined"
                   ; "claim_id", `String claim_id
                   ; "fact", Workspace_memory_ledger.fact_ref_to_json fact_ref
                   ]
             ; recorded_at = ts_iso
             }
           ; { seq = 2
             ; batch_id = "batch-human-1"
             ; fact_id = "claim:" ^ retracted_id
             ; summary = Printf.sprintf "Created claim %s" retracted_id
             ; payload =
                 `Assoc
                   [ "kind", `String "claim_created"
                   ; "claim_id", `String retracted_id
                   ; "claim", `String retracted_text
                   ]
             ; recorded_at = ts_iso
             }
           ; { seq = 3
             ; batch_id = "batch-human-1"
             ; fact_id = "claim:" ^ retracted_id
             ; summary =
                 Printf.sprintf
                   "Claim %s retracted after losing all supporting Keepers"
                   retracted_id
             ; payload =
                 `Assoc
                   [ "kind", `String "claim_retracted"
                   ; "claim_id", `String retracted_id
                   ]
             ; recorded_at = ts_iso
             }
           ; { seq = 4
             ; batch_id = "batch-human-1"
             ; fact_id = "claim:" ^ claim_id
             ; summary = Printf.sprintf "Claim %s support shrank (2 -> 1)" claim_id
             ; payload =
                 `Assoc
                   [ "kind", `String "claim_shrank"
                   ; "claim_id", `String claim_id
                   ; "before", `String "Earlier phrasing before update"
                   ; "vanished_keepers", `List [ `String "beta" ]
                   ]
             ; recorded_at = ts_iso
             }
           ]
         ~committed_at:ts_iso
     with
     | Ok _ -> ()
     | Error err -> Alcotest.fail (Workspace_memory_log.error_to_string err));
    let diff =
      Memory_api.diff_json
        ~now
        ~config
        ~scope:Memory_api.Scope_world
        ~range:(Memory_api.Range_window Memory_api.Window_24h)
        ()
      |> ok_or_fail "GET /api/v1/memory/diff world human text"
      |> json_member_exn "data"
    in
    let added = json_list_exn "added" diff in
    let updated = json_list_exn "updated" diff in
    let retracted = json_list_exn "retracted" diff in
    Alcotest.(check int) "2 added entries" 2 (List.length added);
    Alcotest.(check int) "1 updated (shrank) entry" 1 (List.length updated);
    Alcotest.(check int) "1 retracted entry" 1 (List.length retracted);
    let joined_entry =
      List.find (fun e -> json_int_exn "seq" e = 1) added
    in
    Alcotest.(check string)
      "joined claim resolves human claim_text from ledger"
      fact_claim
      (json_string_exn "claim_text" joined_entry);
    Alcotest.(check string)
      "joined claim resolves author_keeper"
      "alpha"
      (json_string_exn "author_keeper" joined_entry);
    Alcotest.(check bool)
      "joined summary contains human text, not raw UUID only"
      true
      (contains_substr ~needle:fact_claim (json_string_exn "summary" joined_entry));
    let retracted_entry = List.hd retracted in
    Alcotest.(check string)
      "retracted claim recovers historical claim_text from prior create"
      retracted_text
      (json_string_exn "claim_text" retracted_entry);
    let updated_entry = List.hd updated in
    Alcotest.(check string)
      "updated claim resolves claim_text"
      fact_claim
      (json_string_exn "claim_text" updated_entry);
    Alcotest.(check string)
      "updated claim resolves before_text"
      "Earlier phrasing before update"
      (json_string_exn "before_text" updated_entry);
    Alcotest.(check string)
      "updated claim resolves author_keeper from vanished_keepers"
      "beta"
      (json_string_exn "author_keeper" updated_entry))
;;

let test_track_a_hot_reload_and_hardened_secrets () =
  (* 1. Hot-reload classification *)
  let known_providers = Hashtbl.create 4 in
  Hashtbl.replace known_providers "openrouter" ();
  let check_scope label expected key =
    let got =
      Candle_cfg_api.classify_runtime_key_reload_scope
        ~known_provider_ids:known_providers
        key
      |> Candle_cfg_api.reload_scope_to_string
    in
    Alcotest.(check string) label expected got
  in
  check_scope "provider base-url is hot_reload" "hot_reload" "providers.openrouter.base-url";
  check_scope "provider timeout inside providers is hot_reload" "hot_reload" "providers.openrouter.timeout_s";
  check_scope "provider binding is hot_reload" "hot_reload" "openrouter.sonnet.model";
  check_scope "mixed-case provider binding is hot_reload" "hot_reload" "OpenRouter.sonnet.model";
  check_scope "model max_context is hot_reload" "hot_reload" "models.sample.max_context";
  check_scope "runtime lane is hot_reload" "hot_reload" "runtime.lanes.default.candidates";
  check_scope "media_readers is hot_reload" "hot_reload" "media_readers.doc.command";
  check_scope "browser is hot_reload" "hot_reload" "browser.enabled";
  check_scope "machines is hot_reload" "hot_reload" "machines.msx.enabled";
  check_scope "typesafeai is hot_reload" "hot_reload" "typesafeai.board_attention";
  check_scope "lsp.servers is hot_reload" "hot_reload" "lsp.servers.ocaml";
  check_scope "lsp non-servers key stays restart_required" "restart_required" "lsp.timeout_ms";
  check_scope "non-materialized fusion stays restart_required" "restart_required" "fusion.enabled";
  check_scope "turn timeout stays restart_required" "restart_required" "turn.request_timeout_s";
  check_scope "sandbox timeout stays restart_required" "restart_required" "sandbox.connect_timeout_sec";
  check_scope "exec.ssh timeout stays restart_required" "restart_required" "exec.ssh.endpoints.box.connect_timeout_sec";
  check_scope "slack retry stays restart_required" "restart_required" "slack.retry_limit";
  check_scope "voice timeout stays restart_required" "restart_required" "voice.timeout_s";
  check_scope "board retry stays restart_required" "restart_required" "board.retry_count";
  check_scope "memory timeout stays restart_required" "restart_required" "memory.timeout_ms";
  check_scope "otel timeout stays restart_required" "restart_required" "otel.export_timeout_s";
  check_scope "server.port stays restart_required" "restart_required" "server.port";
  check_scope "http.bind_host stays restart_required" "restart_required" "http.bind_host";
  check_scope "storage.data_dir stays restart_required" "restart_required" "storage.data_dir";
  check_scope "domain_pool.pool_size stays restart_required" "restart_required" "domain_pool.pool_size";
  check_scope "kebab domain-pool.request_timeout_s stays restart_required" "restart_required" "domain-pool.request_timeout_s";
  check_scope "kebab executor-pool.retry_limit stays restart_required" "restart_required" "executor-pool.retry_limit";
  check_scope "nested runtime.tls.cert_file stays restart_required" "restart_required" "runtime.tls.cert_file";
  check_scope "nested runtime.ssl.ca_bundle stays restart_required" "restart_required" "runtime.ssl.ca_bundle";
  check_scope "nested runtime.storage.backend stays restart_required" "restart_required" "runtime.storage.backend";
  check_scope "nested runtime.pool.max_workers stays restart_required" "restart_required" "runtime.pool.max_workers";
  check_scope "runtime.socket_path stays restart_required" "restart_required" "runtime.socket_path";
  check_scope "runtime.listen_address stays restart_required" "restart_required" "runtime.listen_address";
  check_scope "runtime.storage_path stays restart_required" "restart_required" "runtime.storage_path";
  check_scope "runtime.tls_cert stays restart_required" "restart_required" "runtime.tls_cert";
  check_scope "runtime.ssl_verify stays restart_required" "restart_required" "runtime.ssl_verify";
  (* 2. Hardened is_secret_key *)
  List.iter
    (fun k ->
       Alcotest.(check bool) ("secret key caught: " ^ k) true (Candle_cfg_api.is_secret_key k))
    [ "providers.foo.headers.\"x-custom-auth\""
    ; "providers.foo.headers.\"x-goog-key\""
    ; "providers.foo.headers.\"x-access-key\""
    ; "providers.foo.headers.cookie"
    ; "providers.foo.headers.\"set-cookie\""
    ; "providers.foo.headers.\"x-session\""
    ; "providers.foo.headers.\"x-session-id\""
    ; "webhooks.github.hmac"
    ; "webhooks.github.x-hmac-sha256"
    ; "webhooks.github.webhook_sig"
    ];
  List.iter
    (fun k ->
       Alcotest.(check bool) ("non-secret key preserved: " ^ k) false (Candle_cfg_api.is_secret_key k))
    [ "db.primary_key"
    ; "db.sort_key"
    ; "crypto.public_key"
    ; "meta.author"
    ; "meta.authority"
    ; "exec.ssh.max_sessions"
    ; "providers.openrouter.headers.\"x-api.version\""
    ; "providers.openrouter.credentials.api_key_env"
    ; "providers.openrouter.credentials.token-path"
    ];
  (* 3. URL userinfo & query-string secret redaction *)
  let leaky_url =
    "https://alice:hunter2pass@proxy.example.com/v1/chat?key=goog-secret-1&token=tok-2&api_key=ak-3&mode=fast"
  in
  let redacted = Candle_cfg_api.redact_value_secrets leaky_url in
  Alcotest.(check bool) "userinfo password redacted" false (contains_substr ~needle:"hunter2pass" redacted);
  Alcotest.(check bool) "query ?key= redacted" false (contains_substr ~needle:"goog-secret-1" redacted);
  Alcotest.(check bool) "query &token= redacted" false (contains_substr ~needle:"tok-2" redacted);
  Alcotest.(check bool) "query &api_key= redacted" false (contains_substr ~needle:"ak-3" redacted);
  Alcotest.(check bool) "benign query param preserved" true (contains_substr ~needle:"mode=fast" redacted);
  (* 4. Runtime schema reflects hot_reload and redacted webhook URL *)
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    write_file_raw
      runtime_toml_path
      "[providers.openrouter]\n\
       display-name = \"OpenRouter\"\n\
       endpoint = \"https://bot:topsecretpw@openrouter.ai/api?api_key=secret-qs-999&v=1\"\n\
       [providers.openrouter.headers]\n\
       \"x-custom-auth\" = \"Bearer raw-custom-auth-123\"\n\
       [openrouter.sonnet]\n\
       model = \"anthropic/claude-sonnet-4.6\"\n\
       [server]\n\
       port = 8935\n";
    let schema =
      Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
      |> ok_or_fail "GET schema hardened"
    in
    let serialized = Yojson.Safe.to_string schema in
    Alcotest.(check bool) "schema never leaks userinfo pw" false (contains_substr ~needle:"topsecretpw" serialized);
    Alcotest.(check bool) "schema never leaks query api_key" false (contains_substr ~needle:"secret-qs-999" serialized);
    Alcotest.(check bool) "schema never leaks x-custom-auth" false (contains_substr ~needle:"raw-custom-auth-123" serialized);
    let categories = json_list_exn "categories" (json_member_exn "data" schema) in
    let find_field fk =
      List.find_map
        (fun cat ->
           List.find_opt
             (fun f -> String.equal (json_string_exn "full_key" f) fk)
             (json_list_exn "fields" cat))
        categories
      |> Option.get
    in
    Alcotest.(check string)
      "provider binding reload_scope = hot_reload"
      "hot_reload"
      (json_string_exn "reload_scope" (find_field "openrouter.sonnet.model"));
    Alcotest.(check string)
      "server.port reload_scope = restart_required"
      "restart_required"
      (json_string_exn "reload_scope" (find_field "server.port"));
    (* 5. Op_remove of a provider section + its binding still classifies as hot_reload
          because config_patch_json unions known_provider_ids across disk_preimage and after_text;
          and Op_set on a non-reloaded section timeout key classifies as restart_required. *)
    let rt_snap = Runtime.For_testing.snapshot () in
    let prev_catalog = Llm_provider.Catalog_snapshot.current () in
    let catalog_path = Filename.concat base_path "model-catalog-p24.toml" in
    write_file_raw
      catalog_path
      "[[models]]\n\
       model_id = \"sample\"\n\
       provider_name = \"local\"\n\
       base = \"openai_chat\"\n\
       max_context_tokens = 1024\n";
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
         let removable_toml =
           "[providers]\n\
            local = { protocol = \"openai-compatible-http\", endpoint = \"http://127.0.0.1:1/v1\" }\n\
            ExtraProv = { protocol = \"openai-compatible-http\", endpoint = \"http://127.0.0.1:2/v1\" }\n\
            [models.sample]\n\
            api-name = \"sample\"\n\
            max-context = 1024\n\
            [local.sample]\n\
            [ExtraProv.sample]\n\
            effort = \"low\"\n\
            [runtime]\n\
            default = \"local.sample\"\n\
            [exec.ssh.endpoints.box]\n\
            host = \"127.0.0.1\"\n\
            user = \"masc\"\n\
            remote_root = \"/srv/masc\"\n\
            connect_timeout_sec = 10\n"
         in
         write_file_raw runtime_toml_path removable_toml;
         let rm_sha = Env.sha256_hex removable_toml in
         let rm_body =
           Yojson.Safe.to_string
             (`Assoc
               [ "target", `String "runtime"
               ; "expected_sha256", `String rm_sha
               ; "dry_run", `Bool true
               ; ( "changes"
                 , `List
                     [ `Assoc
                         [ "key", `String "providers.ExtraProv"
                         ; "op", `String "remove"
                         ]
                     ; `Assoc
                         [ "key", `String "ExtraProv.sample.effort"
                         ; "op", `String "remove"
                         ]
                     ] )
               ])
         in
         let rm_data =
           Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:rm_body ()
           |> ok_or_fail "POST patch Op_remove provider dry_run"
           |> json_member_exn "data"
         in
         Alcotest.(check string)
           "Op_remove removing provider from after_text still classifies binding as hot_reload"
           "hot_reload"
           (json_string_exn "reload_scope" rm_data);
         let non_reloaded_timeout_body =
           Yojson.Safe.to_string
             (`Assoc
               [ "target", `String "runtime"
               ; "expected_sha256", `String rm_sha
               ; "dry_run", `Bool true
               ; ( "changes"
                 , `List
                     [ `Assoc
                         [ "key", `String "exec.ssh.endpoints.box.connect_timeout_sec"
                         ; "value", `Int 30
                         ]
                     ] )
               ])
         in
         let timeout_data =
           Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:non_reloaded_timeout_body ()
           |> ok_or_fail "POST patch exec.ssh timeout dry_run"
           |> json_member_exn "data"
         in
         Alcotest.(check string)
           "non-reloaded exec.ssh timeout patch reports restart_required"
           "restart_required"
           (json_string_exn "reload_scope" timeout_data)))
;;

let test_track_a_task_goal_link_and_strict_claim () =
  (* 1. Path parser *)
  Alcotest.(check (option string))
    "valid task link-goal path"
    (Some "task-123")
    (Server_routes_http_routes_verification.parse_link_task_goal_path
       "/api/v1/tasks/task-123/link-goal");
  Alcotest.(check (option string))
    "URL-encoded task id decoded"
    (Some "task 42")
    (Server_routes_http_routes_verification.parse_link_task_goal_path
       "/api/v1/tasks/task%2042/link-goal");
  Alcotest.(check (option string))
    "wrong suffix rejected"
    None
    (Server_routes_http_routes_verification.parse_link_task_goal_path
       "/api/v1/tasks/task-123/other");
  Alcotest.(check (option string))
    "nested slash rejected"
    None
    (Server_routes_http_routes_verification.parse_link_task_goal_path
       "/api/v1/tasks/a/b/link-goal");
  with_temp_workspace (fun config ->
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    (* Create two open goals and two todo tasks *)
    let condition =
      match Goal_measure.make_label "verified" with
      | Ok l -> l
      | Error e -> Alcotest.fail e
    in
    let mk_goal title =
      match
        Goal_store.upsert_goal_with_events
          config
          ~actor:"operator"
          ~title
          ~priority:1
          ~measure:(Goal_measure.done_when ~condition)
          ~procedure:"check"
          ()
      with
      | Ok (goal, _, _) -> goal.Goal_store.id
      | Error _ -> Alcotest.fail ("upsert_goal_with_events failed for " ^ title)
    in
    let goal1 = mk_goal "Goal One" in
    let goal2 = mk_goal "Goal Two" in
    let mk_task title priority =
      match Workspace.add_task_with_result config ~title ~priority ~description:"desc" with
      | Ok res -> res.task_id
      | Error err -> Alcotest.fail (Workspace.add_task_error_to_string err)
    in
    let t_high = mk_task "High priority task" 1 in
    let t_low = mk_task "Low priority task" 3 in
    (* 2. Valid POST /api/v1/tasks/:id/link-goal with workspace precondition *)
    let good_ws =
      `Assoc
        [ "base_path", `String (Unix.realpath config.Workspace.base_path)
        ; "masc_root", `String (Unix.realpath (Workspace.masc_dir config))
        ]
    in
    let st_ok, body_ok =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:t_low
        (`Assoc [ "goal_id", `String goal1; "expected_workspace", good_ws ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int) "link-goal 200 OK" 200 (Httpun.Status.to_code st_ok);
    Alcotest.(check string) "linked task_id" t_low (json_string_exn "task_id" body_ok);
    Alcotest.(check string) "linked goal_id" goal1 (json_string_exn "goal_id" body_ok);
    (* Missing expected_workspace precondition -> 400 Bad Request *)
    let st_missing_ws, body_missing_ws =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:t_low
        (`Assoc [ "goal_id", `String goal1 ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int)
      "missing expected_workspace -> 400"
      400
      (Httpun.Status.to_code st_missing_ws);
    Alcotest.(check bool)
      "missing precondition error mentions expected_workspace"
      true
      (contains_substr ~needle:"expected_workspace" (json_string_exn "error" body_missing_ws));
    (* Idempotent retry returns 200 *)
    let st_idem, _ =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:t_low
        (`Assoc [ "goal_id", `String goal1; "expected_workspace", good_ws ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int) "idempotent retry 200 OK" 200 (Httpun.Status.to_code st_idem);
    (* Reassignment to different goal -> 409 Conflict *)
    let st_conflict, _ =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:t_low
        (`Assoc [ "goal_id", `String goal2; "expected_workspace", good_ws ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int) "already assigned -> 409" 409 (Httpun.Status.to_code st_conflict);
    (* Missing task -> 404 *)
    let st_no_task, _ =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:"task-does-not-exist"
        (`Assoc [ "goal_id", `String goal1; "expected_workspace", good_ws ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int) "unknown task -> 404" 404 (Httpun.Status.to_code st_no_task);
    (* Missing goal -> 404 *)
    let st_no_goal, _ =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:t_high
        (`Assoc [ "goal_id", `String "goal-missing"; "expected_workspace", good_ws ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int) "unknown goal -> 404" 404 (Httpun.Status.to_code st_no_goal);
    (* Workspace mismatch -> 409 *)
    let bad_ws =
      `Assoc [ "base_path", `String "/wrong/ws"; "masc_root", `String "/wrong/ws/.masc" ]
    in
    let st_ws, _ =
      Server_routes_http_routes_verification.commit_link_task_goal_json
        ~config
        ~operator_id:"operator"
        ~task_id:t_high
        (`Assoc [ "goal_id", `String goal1; "expected_workspace", bad_ws ])
      |> Server_routes_http_routes_verification.link_task_goal_response
    in
    Alcotest.(check int) "workspace mismatch -> 409" 409 (Httpun.Status.to_code st_ws);
    (* 3. keeper_task_claim with explicit missing task_id fails WITHOUT claiming t_high *)
    let ctx : Masc.Task.Tool.context =
      { config; agent_name = "alpha"; sw = None }
    in
    (match
       Masc.Task.Tool.dispatch
         ctx
         ~name:"keeper_task_claim"
         ~args:(`Assoc [ "task_id", `String "task-nonexistent-999" ])
     with
     | Some res ->
       Alcotest.(check bool)
         "explicit missing task_id rejected"
         true
         (Option.is_some (Tool_result.failure_class res))
     | None -> Alcotest.fail "keeper_task_claim must dispatch");
    (* Verify t_high is STILL Todo and untouched *)
    let tasks_after = Workspace.get_tasks_raw config in
    let high_after =
      List.find (fun (t : Masc_domain.task) -> String.equal t.id t_high) tasks_after
    in
    Alcotest.(check bool)
      "higher-priority task stays Todo after failed explicit claim"
      true
      (high_after.task_status = Masc_domain.Todo))
;;

let test_memory_os_world_mvcc_and_keeper_internals () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    mkdir_p keepers_dir;
    let now = 1_760_000_000.0 in
    (* 1. Real World_memory_store (world_memory.db) with 1 public + 1 private fact *)
    let public_claim = "Shared workspace architecture uses OCaml 5.5 Eio" in
    let private_claim = "PRIVATE_SECRET_DO_NOT_LEAK_ALPHA_NOTE" in
    let pub_id = World_memory_types.fact_id_of_claim ~scope:"workspace" ~claim:public_claim in
    let priv_id = World_memory_types.fact_id_of_claim ~scope:"keeper:alpha" ~claim:private_claim in
    (match
       World_memory_store.upsert_fact ~base_path ~now:(now -. 60.0) ~actor:"alpha"
         ~fact_id:pub_id ~claim:public_claim ~category:Keeper_memory_os_types.Fact
         ~facets:[ "architecture" ] ~scope:"workspace"
         ~provenance:(Proposed_by { keeper_id = "alpha"; source_fact_ids = [ "sha256:aaa" ] })
         ~lifecycle:Canonical
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("upsert public world fact: " ^ World_memory_store.error_to_string e));
    (match
       World_memory_store.upsert_fact ~base_path ~now:(now -. 30.0) ~actor:"alpha"
         ~fact_id:priv_id ~claim:private_claim ~category:Keeper_memory_os_types.Fact
         ~facets:[ "private" ] ~scope:"keeper:alpha"
         ~provenance:(Proposed_by { keeper_id = "alpha"; source_fact_ids = [ "sha256:bbb" ] })
         ~lifecycle:Working
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("upsert private world fact: " ^ World_memory_store.error_to_string e));
    (* Add a public->private edge and transition the private fact to terminal Molted;
       neither the inactive private fact nor the edge's reason/target may leak! *)
    let private_edge_secret = "PRIVATE_EDGE_SECRET_DO_NOT_LEAK" in
    (match
       World_memory_store.add_edge ~base_path ~now:(now -. 25.0) ~actor:"alpha"
         ~from_fact_id:pub_id ~to_fact_id:priv_id
         ~kind:World_memory_types.Refines ~reason:private_edge_secret
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("add_edge public->private: " ^ World_memory_store.error_to_string e));
    let private_molt_reason = "PRIVATE_MOLT_REASON_SECRET" in
    (match
       World_memory_store.transition_fact_lifecycle ~base_path ~now:(now -. 20.0)
         ~actor:"alpha" ~fact_id:priv_id ~to_lifecycle:World_memory_types.Molted
         ~reason:private_molt_reason
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("transition private fact to Molted: " ^ World_memory_store.error_to_string e));
    let world_resp =
      Memory_api.world_json ~now ~config () |> ok_or_fail "GET /api/v1/memory/world (MVCC)"
    in
    let world_str = Yojson.Safe.to_string world_resp in
    Alcotest.(check bool) "world_json includes public world_memory.db fact" true
      (contains_substr ~needle:public_claim world_str);
    Alcotest.(check bool) "world_json NEVER leaks private fact, ID, edge reason, or molt reason" false
      (contains_substr ~needle:private_claim world_str
       || contains_substr ~needle:priv_id world_str
       || contains_substr ~needle:private_edge_secret world_str
       || contains_substr ~needle:private_molt_reason world_str);
    let world_data = json_member_exn "data" world_resp in
    Alcotest.(check string) "world_json source = world_memory_db" "world_memory_db"
      (json_string_exn "source" world_data);
    ignore (json_member_exn "world_mvcc" world_data);
    Alcotest.(check int) "world_json claims has only 1 public fact" 1
      (List.length (json_list_exn "claims" world_data));
    let world_diff =
      Memory_api.diff_json ~now ~config ~scope:Scope_world
        ~range:(Range_window Window_24h) ()
      |> ok_or_fail "GET /api/v1/memory/diff?scope=world (MVCC)"
    in
    let world_diff_str = Yojson.Safe.to_string world_diff in
    Alcotest.(check bool) "world diff includes public fact_id" true
      (contains_substr ~needle:pub_id world_diff_str);
    Alcotest.(check bool) "world diff NEVER leaks private fact, ID, edge reason, or molt reason" false
      (contains_substr ~needle:private_claim world_diff_str
       || contains_substr ~needle:priv_id world_diff_str
       || contains_substr ~needle:private_edge_secret world_diff_str
       || contains_substr ~needle:private_molt_reason world_diff_str);
    (* 1b. >205 change-log rows: world_json returns newest tail (not frozen at seq 1..200)
       and Range_revs with high from_rev returns recent rows instead of empty *)
    for i = 1 to 210 do
      let claim = Printf.sprintf "Bulk public architecture fact #%03d" i in
      let fid = World_memory_types.fact_id_of_claim ~scope:"workspace" ~claim in
      match
        World_memory_store.upsert_fact ~base_path ~now:(now -. 10.0 +. (float_of_int i *. 0.01))
          ~actor:"alpha" ~fact_id:fid ~claim ~category:Keeper_memory_os_types.Fact
          ~facets:[ "bulk" ] ~scope:"workspace"
          ~provenance:(Proposed_by { keeper_id = "alpha"; source_fact_ids = [] })
          ~lifecycle:Canonical
      with
      | Ok _ -> ()
      | Error e -> Alcotest.fail ("bulk upsert world fact: " ^ World_memory_store.error_to_string e)
    done;
    let world_tail_resp =
      Memory_api.world_json ~now ~config () |> ok_or_fail "GET /api/v1/memory/world (tail > 200)"
    in
    let world_tail_str = Yojson.Safe.to_string world_tail_resp in
    Alcotest.(check bool) "world_json >200 events still never leaks private data" false
      (contains_substr ~needle:priv_id world_tail_str
       || contains_substr ~needle:private_edge_secret world_tail_str);
    let world_tail_data = json_member_exn "data" world_tail_resp in
    let log_report = json_member_exn "recent_batches" world_tail_data in
    let last_committed_seq = json_int_exn "last_committed_seq" log_report in
    Alcotest.(check bool) "world_json recent_batches.last_committed_seq > 210" true
      (last_committed_seq > 210);
    let recent_changes = json_list_exn "recent_changes" log_report in
    Alcotest.(check bool) "world_json recent_changes surfaces newest last_committed_seq tail" true
      (List.exists (fun ev -> json_int_exn "seq" ev = last_committed_seq) recent_changes);
    let high_rev_diff =
      Memory_api.diff_json ~now ~config ~scope:Scope_world
        ~range:(Range_revs { from_rev = 205; to_rev = None }) ()
      |> ok_or_fail "GET /api/v1/memory/diff?scope=world&from_rev=205"
    in
    let high_rev_added =
      high_rev_diff |> json_member_exn "data" |> json_list_exn "added"
    in
    Alcotest.(check bool) "world diff Range_revs from_rev=205 returns recent rows" true
      (List.length high_rev_added >= 5);
    Alcotest.(check bool) "world diff Range_revs never leaks private data" false
      (let s = Yojson.Safe.to_string high_rev_diff in
       contains_substr ~needle:priv_id s || contains_substr ~needle:private_edge_secret s);
    (* 2. Per-keeper Memory OS Internals (compaction + canonical turns + digest + librarian molt) *)
    let turn_id = Ids.Turn_id.of_string "turn-001" in
    let anchor : Keeper_compaction.compaction_anchor =
      { epoch_id = 1
      ; covers_through_turn = turn_id
      ; archived_epochs_through = None
      ; active_intent = "Verify Memory OS internals"
      ; observations = [ Assistant_said "Read-only stats available", turn_id ]
      }
    in
    let evicted_turn : Keeper_compaction.canonical_turn =
      { turn_id; messages = [] }
    in
    (match
       Keeper_compaction.commit_epoch ~keepers_dir ~keeper_id:"alpha"
         ~trigger:(Explicit_hard_limit { capacity_bytes = 64000; observed_bytes = 70000 })
         ~anchor ~evicted_turns:[ evicted_turn ]
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("commit_epoch: " ^ Keeper_compaction.store_error_to_string e));
    (match
       Keeper_canonical_turn_store.commit_turn ~keepers_dir ~keeper_id:"alpha"
         ~turn_id ~runtime_kind:Acp_cli ~runtime_id:"vibe_acp.devstral-2"
         ~user_input:"Run compaction check" ~tool_calls_json:(`List [])
         ~assistant_output:"Compacted cleanly" ~usage_json:(`Assoc [])
         ~compaction_epoch_id:1 ~created_at:(now -. 20.0) ()
     with
     | Ok _ -> ()
     | Error e -> Alcotest.fail ("commit_turn: " ^ Keeper_canonical_turn_store.store_error_to_string e));
    let origin = Keeper_memory_os_types.{ kind = Authored; trace_id = "trace-int" } in
    let df1 = Keeper_memory_os_types.observed ~claim:"Digest fact 1" ~category:Fact ~now ~origin in
    let df2 = Keeper_memory_os_types.observed ~claim:"Digest fact 2" ~category:Constraint ~now ~origin in
    ignore (Keeper_memory_digest.load_or_compile ~keepers_dir ~keeper_id:"alpha" ~revision:3 ~facts:[ df1; df2 ]);
    let internals =
      Server_dashboard_http_keeper_memory_reads.memory_os_internals_json ~config ~keeper_id:"alpha"
    in
    let comp = json_member_exn "compaction" internals in
    Alcotest.(check bool) "compaction present" true (json_bool_exn "present" comp);
    Alcotest.(check int) "compaction epoch_count" 1 (json_int_exn "epoch_count" comp);
    Alcotest.(check int) "compaction archived_turns_count" 1 (json_int_exn "archived_turns_count" comp);
    Alcotest.(check bool) "compaction anchor_bytes > 0" true (json_int_exn "anchor_bytes" comp > 0);
    Alcotest.(check int) "compaction counts attributed observations" 1 (json_int_exn "observations_count" comp);
    let turns = json_member_exn "canonical_turns" internals in
    Alcotest.(check bool) "canonical_turns present" true (json_bool_exn "present" turns);
    Alcotest.(check int) "canonical_turns turn_count" 1 (json_int_exn "turn_count" turns);
    Alcotest.(check string) "canonical_turns latest_runtime_kind" "acp_cli"
      (json_string_exn "latest_runtime_kind" turns);
    Alcotest.(check string) "canonical_turns latest_runtime_id" "vibe_acp.devstral-2"
      (json_string_exn "latest_runtime_id" turns);
    let dig = json_member_exn "memory_digest" internals in
    Alcotest.(check bool) "memory_digest present" true (json_bool_exn "present" dig);
    Alcotest.(check int) "memory_digest revision" 3 (json_int_exn "revision" dig);
    Alcotest.(check int) "memory_digest fact_count" 2 (json_int_exn "fact_count" dig);
    Alcotest.(check bool) "memory_digest bytes > 0" true (json_int_exn "bytes" dig > 0);
    let molt = json_member_exn "librarian_molt" internals in
    Alcotest.(check string) "librarian_molt writer_kind" "none_in_process"
      (json_string_exn "writer_kind" molt);
    (* 3. Program absorption relation fires in keeper diff via Keeper_memory_activity *)
    let old_a = Keeper_memory_os_types.observed ~claim:"Old partial fact A" ~category:Fact ~now:(now -. 40.0) ~origin in
    let succ_a = Keeper_memory_os_types.observed ~claim:"Synthesized combined fact" ~category:Fact ~now:(now -. 10.0) ~origin in
    let journal_snap : Keeper_memory_os_current.t =
      { revision = 1
      ; updated_at = now -. 10.0
      ; source = { kind = Librarian; trace_id = "trace-absorb" }
      ; facts = [ succ_a ]
      ; change = { added = [ succ_a ]; removed = [ old_a ]; retained = 0; invalidated = [] }
      }
    in
    let snap_bytes =
      Yojson.Safe.pretty_to_string (Keeper_memory_os_current.to_json journal_snap) ^ "\n"
    in
    write_file_raw (Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha")
      snap_bytes;
    let qid =
      match
        Librarian_question_id.of_halves
          ~front:(String.make Librarian_question_id.half_length 'a')
          ~back:(String.make Librarian_question_id.half_length 'b')
      with
      | Some id -> id
      | None -> Alcotest.fail "question id"
    in
    let digest = Agent_core.Checkpoint_objects.digest_of_bytes snap_bytes in
    let absorb_commit : Librarian_log.commit =
      { seq = 1
      ; at = now -. 10.0
      ; basis = digest
      ; after = digest
      ; revision = 1
      ; cause =
          Librarian_log.Read
            { question = qid
            ; shown = Librarian_log.With_memory
            ; slot = "tui-test"
            ; trace = "trace-absorb"
            ; missing = []
            }
      ; effects =
          { Librarian_effects.empty with
            added = [ succ_a ]
          ; removed =
              [ old_a, Librarian_effects.Merged_into (Keeper_memory_os_types.memory_id succ_a) ]
          }
      ; turn_log = Keeper_turn_log.Log_id.fresh ()
      ; turn_log_offset = 0
      ; covers_through = Librarian_log.Before_first
      ; covered =
          { Keeper_turn_log.trace = ""
          ; closed_messages = 0
          ; session = ""
          ; history_bytes = 0
          ; internal_bytes = 0
          ; chat_bytes = 0
          ; external_rows = 0
          }
      ; working_state = None
      }
    in
    let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha" in
    let next_end =
      match Librarian_log_store.append ~path:log_path ~at_end:0 (Librarian_log.Committed absorb_commit) with
      | Ok { Librarian_log_store.new_end; _ } -> ref new_end
      | Error _ -> Alcotest.fail "append absorb commit log failed"
    in
    (* Append 205 newer commits after the absorption so [absorb_commit] sits >200
       commits back from the tail (still well inside the 2000-commit diff window). *)
    for i = 2 to 206 do
      let filler_fact =
        Keeper_memory_os_types.observed
          ~claim:(Printf.sprintf "Filler fact %d after absorption" i)
          ~category:Keeper_memory_os_types.Fact
          ~now:(now -. 5.0)
          ~origin:{ kind = Keeper_memory_os_types.Authored; trace_id = Printf.sprintf "filler-%d" i }
      in
      let filler_commit : Librarian_log.commit =
        { absorb_commit with
          seq = i
        ; at = now -. 5.0
        ; revision = i
        ; cause =
            Librarian_log.Direct
              { by = Librarian_effects.Keeper
              ; trace = Printf.sprintf "filler-%d" i
              ; write =
                  Librarian_direct.Remember
                    { claim = filler_fact.claim
                    ; category = filler_fact.category
                    ; basis = filler_fact.basis
                    }
              }
        ; effects = { Librarian_effects.empty with added = [ filler_fact ] }
        }
      in
      match Librarian_log_store.append ~path:log_path ~at_end:!next_end (Librarian_log.Committed filler_commit) with
      | Ok { Librarian_log_store.new_end; _ } -> next_end := new_end
      | Error _ -> Alcotest.fail "append filler commit log failed"
    done;
    let kdiff =
      Memory_api.diff_json ~now ~config ~scope:(Scope_keeper "alpha")
        ~range:(Range_window Window_24h) ()
      |> ok_or_fail "GET /api/v1/memory/diff?scope=keeper:alpha (absorption >200 commits back)"
      |> json_member_exn "data"
    in
    let updated = json_list_exn "updated" kdiff in
    Alcotest.(check bool) "keeper diff emits program_absorption relation even >200 commits back" true
      (List.exists (fun u -> json_string_exn "relation" u = "program_absorption") updated))
;;

let test_candle_config_optional_descriptors_and_keeper_runtime_assignment () =
  with_temp_workspace (fun config ->
    let base_path = config.Workspace.base_path in
    let runtime_toml_path = Filename.concat base_path ".masc/config/runtime.toml" in
    write_file_raw runtime_toml_path
      {|[runtime]
default = "primary"

[runtime.lanes.primary]
candidates = ["claude.claude-sonnet-5"]

[providers.claude]
display-name = "Anthropic"
protocol = "messages-http"
endpoint = "https://api.anthropic.com"

[models."claude-sonnet-5"]
api-name = "claude-sonnet-5"
max-context = 200000
tools-support = true
streaming = true

[claude."claude-sonnet-5"]

[models."claude-sonnet-4.5"]
api-name = "claude-sonnet-4-5"
max-context = 200000
tools-support = true
streaming = true

[claude."claude-sonnet-4.5"]
|};
    let keeper_toml_path = Filename.concat base_path ".masc/config/keepers/alpha.toml" in
    let keeper_orig =
      "[keeper]\nname = \"alpha\"\ninstructions = \"Be concise\"\nactivation_mode = \"on_demand\"\n"
    in
    write_file_raw keeper_toml_path keeper_orig;
    let rt_data =
      Candle_cfg_api.config_schema_json ~base_path ~target:Target_runtime ()
      |> ok_or_fail "GET runtime schema optional descriptors"
      |> json_member_exn "data"
    in
    let rt_sha = json_string_exn "file_sha256" rt_data in
    let rt_fields =
      json_list_exn "categories" rt_data
      |> List.concat_map (fun c -> json_list_exn "fields" c)
    in
    let has_field key =
      List.exists (fun f -> json_string_exn "full_key" f = key) rt_fields
    in
    List.iter
      (fun k ->
         Alcotest.(check bool) ("optional descriptor exposed: " ^ k) true (has_field k))
      [ "providers.claude.store"
      ; "providers.claude.explicit-context-cache-ttl-s"
      ; "models.claude-sonnet-5.explicit-context-cache-ttl-s"
      ; "models.claude-sonnet-5.efforts"
      ; "claude.claude-sonnet-5.cache-retention"
      ; "claude.claude-sonnet-5.efforts"
      ; "models.\"claude-sonnet-4.5\".efforts"
      ; "claude.\"claude-sonnet-4.5\".cache-retention"
      ];
    let cache_ret_field =
      List.find
        (fun f -> json_string_exn "full_key" f = "claude.claude-sonnet-5.cache-retention")
        rt_fields
    in
    Alcotest.(check string) "cache-retention is enum" "enum" (json_string_exn "type" cache_ret_field);
    (* Patch dotted/quoted model & binding tables directly through /api/v1/config/patch *)
    let dotted_patch_body ~dry_run =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "runtime"
          ; "expected_sha256", `String rt_sha
          ; "dry_run", `Bool dry_run
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "table", `String "models.\"claude-sonnet-4.5\""
                    ; "key", `String "efforts"
                    ; "value", `List [ `String "low"; `String "high" ]
                    ]
                ; `Assoc
                    [ "table", `String "claude.\"claude-sonnet-4.5\""
                    ; "key", `String "efforts"
                    ; "value", `List [ `String "low"; `String "high" ]
                    ]
                ; `Assoc
                    [ "table", `String "claude.\"claude-sonnet-4.5\""
                    ; "key", `String "cache-retention"
                    ; "value", `String "1h"
                    ]
                ] )
          ])
    in
    ignore
      (Candle_cfg_api.config_patch_json ~config ~actor:"tester"
         ~body_str:(dotted_patch_body ~dry_run:true) ()
       |> ok_or_fail "POST dry_run dotted model table patch");
    ignore
      (Candle_cfg_api.config_patch_json ~config ~actor:"tester"
         ~body_str:(dotted_patch_body ~dry_run:false) ()
       |> ok_or_fail "POST commit dotted model table patch");
    let patched_dotted_rt = read_file_raw runtime_toml_path in
    (match Runtime_toml.parse_string patched_dotted_rt with
     | Ok cfg ->
       Alcotest.(check bool) "dotted table patch expanded claude-sonnet-4.5-high binding" true
         (List.exists
            (fun (b : Runtime_schema.binding) ->
               b.provider_id = "claude" && b.model_id = "claude-sonnet-4.5-high")
            cfg.bindings)
     | Error errs ->
       Alcotest.fail
         (Printf.sprintf "dotted table patched runtime.toml parse failed (%d errors)\n%s"
            (List.length errs) patched_dotted_rt));
    Alcotest.(check bool) "dotted binding patch wrote cache-retention" true
      (contains_substr ~needle:"cache-retention = \"1h\"" patched_dotted_rt);
    let k_data =
      Candle_cfg_api.config_schema_json ~base_path ~target:(Target_keeper "alpha") ()
      |> ok_or_fail "GET keeper:alpha schema"
      |> json_member_exn "data"
    in
    let k_sha = json_string_exn "file_sha256" k_data in
    let k_fields =
      json_list_exn "categories" k_data
      |> List.concat_map (fun c -> json_list_exn "fields" c)
    in
    let assign_field =
      List.find (fun f -> json_string_exn "full_key" f = "runtime.assignments.runtime") k_fields
    in
    Alcotest.(check bool) "runtime.assignments.runtime writable" true
      (json_bool_exn "writable" assign_field);
    let enum_vals =
      json_list_exn "enum_values" assign_field
      |> List.map (function `String s -> s | _ -> "")
    in
    Alcotest.(check bool) "enum_values includes lane primary" true (List.mem "primary" enum_vals);
    (* Dual-file failure must NEVER partially mutate alpha.toml *)
    let bad_dual_body =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String k_sha
          ; "dry_run", `Bool false
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "table", `String "keeper"
                    ; "key", `String "instructions"
                    ; "value", `String "MUST_NOT_BE_WRITTEN"
                    ]
                ; `Assoc
                    [ "key", `String "runtime.assignments.runtime"
                    ; "value", `String "nonexistent-lane-xyz"
                    ]
                ] )
          ])
    in
    (match Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:bad_dual_body () with
     | Error _ -> ()
     | Ok _ -> Alcotest.fail "invalid runtime.assignments.runtime must fail");
    Alcotest.(check string) "failed dual-file patch leaves alpha.toml untouched" keeper_orig
      (read_file_raw keeper_toml_path);
    let patch_body ~dry_run =
      Yojson.Safe.to_string
        (`Assoc
          [ "target", `String "keeper:alpha"
          ; "expected_sha256", `String k_sha
          ; "dry_run", `Bool dry_run
          ; ( "changes"
            , `List
                [ `Assoc
                    [ "key", `String "runtime.assignments.runtime"
                    ; "value", `String "primary"
                    ]
                ] )
          ])
    in
    ignore
      (Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:(patch_body ~dry_run:true) ()
       |> ok_or_fail "POST dry_run keeper runtime assignment");
    ignore
      (Candle_cfg_api.config_patch_json ~config ~actor:"tester" ~body_str:(patch_body ~dry_run:false) ()
       |> ok_or_fail "POST commit keeper runtime assignment");
    Alcotest.(check string) "keeper alpha.toml stays untouched" keeper_orig
      (read_file_raw keeper_toml_path);
    let updated_rt = read_file_raw runtime_toml_path in
    let parsed_rt =
      match Runtime_toml.parse_string updated_rt with
      | Ok c -> c
      | Error errs ->
        Alcotest.fail
          (Printf.sprintf "updated runtime.toml parse failed (%d errors)\n--- text ---\n%s"
             (List.length errs) updated_rt)
    in
    Alcotest.(check (option string)) "runtime.toml keeper_assignments has alpha -> primary"
      (Some "primary") (List.assoc_opt "alpha" parsed_rt.keeper_assignments))
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
      , [ Alcotest.test_case "world conflicts + keeper diff + heat" `Quick test_memory_v2_world_and_diff
        ; Alcotest.test_case "Track A4 human-readable claim text in world diff" `Quick test_track_a_memory_diff_human_claim_text
        ; Alcotest.test_case "World_memory_store MVCC + keeper Memory OS internals + program_absorption" `Quick
            test_memory_os_world_mvcc_and_keeper_internals
        ] )
    ; ( "candle_and_config"
      , [ Alcotest.test_case "candle ledger root-cause diagnostics" `Quick test_candle_ledger_diagnostics
        ; Alcotest.test_case "config schema redaction + atomic patch" `Quick test_config_schema_redaction_and_patch_roundtrip
        ; Alcotest.test_case "config schema registry + routing_failover categories" `Quick test_config_schema_registry_and_routing_failover
        ; Alcotest.test_case "Track A6 hot-reload classification + hardened secret redaction" `Quick test_track_a_hot_reload_and_hardened_secrets
        ; Alcotest.test_case "optional runtime descriptors + keeper runtime.assignments dual-file patch" `Quick
            test_candle_config_optional_descriptors_and_keeper_runtime_assignment
        ] )
    ; ( "signal_and_scorecard"
      , [ Alcotest.test_case "board signal_only + succession chains" `Quick test_board_signal_and_succession_chains
        ; Alcotest.test_case "board signal_only expanding pagination + full-board succession chains" `Quick test_board_signal_pagination_and_full_succession_chains
        ; Alcotest.test_case "board succession chains shared cache + bounded scope" `Quick test_board_succession_chains_shared_cache_and_bounded_scope
        ; Alcotest.test_case "dashboard 24h rollup + groups" `Quick test_dashboard_24h_rollup_and_groups
        ; Alcotest.test_case "v2.5 neutral keeper.group grouping + config entity metadata" `Quick test_v25_neutral_keeper_groups_and_config_entity_metadata
        ; Alcotest.test_case "Track A3/A5 scorecard_24h + capabilities advertisement" `Quick test_track_a_scorecard_and_capabilities
        ] )
    ; ( "task_goal_link"
      , [ Alcotest.test_case "Track A7 link-goal API + strict keeper_task_claim" `Quick test_track_a_task_goal_link_and_strict_claim ] )
    ]
;;
