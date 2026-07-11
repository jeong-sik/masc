(** P0 keeper registry hardening tests.

    Verify typed validation errors on put/update, health-aware get, and the
    tool-dispatch fallback path that uses the original meta when the registry
    entry is corrupted. *)

open Alcotest

module KR = Masc.Keeper_registry
module KET = Masc.Keeper_tool_dispatch_runtime
module KLH = Masc.Keeper_lifecycle_hooks
module KSM = Keeper_state_machine
module Lane = Masc.Keeper_lane

let base_path = "/tmp/test_keeper_registry_hardening"

let make_meta ?(tool_access = []) name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("agent-" ^ name));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "test keeper");
          ("allowed_paths", `List [ `String "*" ]);
          ("tool_access", Json_util.json_string_list tool_access);
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> failwith ("make_meta failed: " ^ e)
;;

let register name =
  let meta = make_meta name in
  KR.register ~base_path meta.name meta
;;

let health_to_string = KR.registry_entry_validation_error_to_string

let test_put_entry_rejects_meta_name_mismatch () =
  KR.clear ();
  let entry = register "alice" in
  let corrupted = { entry with meta = { entry.meta with name = "bob" } } in
  match KR.put_entry ~base_path "alice" corrupted with
  | Ok () -> fail "put_entry accepted a meta.name mismatch"
  | Error (KR.Name_mismatch { expected; actual }) ->
    check string "expected name" "alice" expected;
    check string "actual name" "bob" actual
  | Error other -> fail ("unexpected validation error: " ^ health_to_string other)
;;

let test_update_entry_rejects_corrupted_result () =
  KR.clear ();
  let entry = register "alice" in
  let original_base_path = entry.base_path in
  (match
     KR.update_entry ~base_path "alice" (fun e -> { e with base_path = "wrong" })
   with
   | Ok () -> fail "update_entry accepted a corrupted closure result"
   | Error (KR.Base_path_mismatch _) -> ()
   | Error other -> fail ("unexpected validation error: " ^ health_to_string other));
  match KR.get ~base_path "alice" with
  | None -> fail "original entry disappeared after rejected update"
  | Some e -> check string "original base_path preserved" original_base_path e.base_path
;;

let test_unregister_exact_preserves_replacement_lane () =
  KR.clear ();
  let old_entry = register "alice" in
  let replacement = register "alice" in
  (match KR.unregister_exact old_entry with
   | KR.Exact_entry_replaced -> ()
   | KR.Exact_unregistered -> fail "stale entry removed its replacement lane"
   | KR.Exact_entry_missing -> fail "replacement lane unexpectedly missing");
  (match KR.get ~base_path "alice" with
   | Some current ->
     check bool "replacement remains registered" true (current == replacement)
   | None -> fail "replacement lane was removed");
  match KR.unregister_exact replacement with
  | KR.Exact_unregistered -> ()
  | KR.Exact_entry_missing -> fail "replacement disappeared before exact removal"
  | KR.Exact_entry_replaced -> fail "replacement identity changed unexpectedly"
;;

let test_unregister_exact_accepts_same_lane_record_update () =
  KR.clear ();
  let observed = register "alice" in
  (match
     KR.update_entry ~base_path "alice" (fun entry ->
       { entry with last_error = Some "immutable record replacement" })
   with
   | Ok () -> ()
   | Error error -> fail (KR.registry_entry_validation_error_to_string error));
  match KR.unregister_exact observed with
  | KR.Exact_unregistered -> ()
  | KR.Exact_entry_missing -> fail "same lane disappeared before removal"
  | KR.Exact_entry_replaced -> fail "same lane record update was treated as ABA"
;;

let test_update_entry_exact_preserves_replacement_lane () =
  KR.clear ();
  let old_entry = register "alice" in
  let replacement = register "alice" in
  (match
     KR.update_entry_exact old_entry (fun entry ->
       { entry with last_error = Some "stale lane mutation" })
   with
   | KR.Exact_update_replaced -> ()
   | KR.Exact_updated -> fail "stale exact update mutated the replacement lane"
   | KR.Exact_update_missing -> fail "replacement lane unexpectedly missing"
   | KR.Exact_update_invalid error ->
     fail (KR.registry_entry_validation_error_to_string error));
  match KR.get ~base_path "alice" with
  | Some current ->
    check bool "replacement identity preserved" true (current == replacement);
    check (option string) "replacement error field preserved" None current.last_error
  | None -> fail "replacement lane disappeared"
;;

let test_dispatch_event_exact_preserves_replacement_lane () =
  KR.clear ();
  let old_meta = make_meta "alice" in
  let old_entry = KR.register_offline ~base_path old_meta.name old_meta in
  let replacement = KR.register_offline ~base_path old_meta.name old_meta in
  (match KR.dispatch_event_exact old_entry KSM.Fiber_started with
   | Error _ -> ()
   | Ok _ -> fail "stale exact dispatch mutated the replacement lane");
  match KR.get ~base_path "alice" with
  | Some current ->
    check bool "replacement identity preserved" true (current == replacement);
    check
      string
      "replacement remains offline"
      "offline"
      (KSM.phase_to_string current.phase)
  | None -> fail "replacement lane disappeared"
;;

let test_lane_fork_rejects_cancelling_switch () =
  Eio_main.run @@ fun _env ->
  let lane = Lane.create () in
  let run_called = Atomic.make false in
  let cleanup_calls = Atomic.make 0 in
  let fork_result = Atomic.make None in
  (try
     Eio.Switch.run @@ fun sw ->
     Eio.Switch.fail sw (Failure "synthetic parent cancellation");
     Atomic.set
       fork_result
       (Some
          (Lane.fork
             ~sw
             lane
             ~run:(fun _ -> Atomic.set run_called true)
             ~cleanup:(fun _ ->
               Atomic.incr cleanup_calls;
               Ok ())))
   with
   | Failure _ -> ()
   | exn -> raise exn);
  (match Atomic.get fork_result with
   | Some (Error (Lane.Fork_failed _)) -> ()
   | Some (Error error) -> fail (Lane.start_error_to_string error)
   | Some (Ok ()) -> fail "fork reported success on an already-cancelling switch"
   | None -> fail "fork result was not captured");
  check bool "lane body was not run" false (Atomic.get run_called);
  check int "cleanup ran exactly once" 1 (Atomic.get cleanup_calls);
  match Lane.peek_exit lane with
  | Some { outcome = Lane.Cancelled_by_parent _; _ } -> ()
  | Some _ -> fail "lane exit did not preserve parent cancellation"
  | None -> fail "lane exit promise remained unresolved"
;;

let test_dispatch_write_failure_skips_phase_side_effects () =
  KR.clear ();
  KLH.reset_for_testing ();
  Fun.protect
    ~finally:(fun () -> KLH.reset_for_testing ())
    (fun () ->
       let hook_calls = ref 0 in
       KLH.register (fun ~keeper_id:_ _ -> incr hook_calls);
       let entry = register "alice" in
       let corrupted = { entry with meta = { entry.meta with name = "bob" } } in
       KR.For_testing.unsafe_put_entry ~base_path "alice" corrupted;
       match KR.dispatch_event ~base_path "alice" KSM.Fiber_started with
       | Ok _ -> fail "dispatch accepted a transition whose registry write failed"
       | Error (KSM.Invalid_transition _ | KSM.Precondition_violation _) ->
         check int "phase hook skipped before failed write" 0 !hook_calls
       | Error other ->
         fail
           ( "unexpected dispatch error: "
           ^ KSM.transition_error_to_string other ))
;;

let test_get_filters_corrupted_entry () =
  KR.clear ();
  let entry = register "alice" in
  let corrupted =
    { entry with
      meta =
        { entry.meta with
          runtime = { entry.meta.runtime with generation = -1 }
        }
    }
  in
  KR.For_testing.unsafe_put_entry ~base_path "alice" corrupted;
  (match KR.get ~base_path "alice" with
   | None -> ()
   | Some _ -> fail "get returned a corrupted entry");
  match KR.get_with_health ~base_path "alice" with
  | None -> fail "get_with_health returned None for an existing (corrupted) entry"
  | Some (e, KR.Required_field_missing { field }) ->
    check string "missing field" "generation" field;
    check string "entry base_path" base_path e.base_path
  | Some (_, other) -> fail ("unexpected health: " ^ health_to_string other)
;;

let test_wakeup_running_reports_typed_outcome () =
  KR.clear ();
  (match KR.wakeup_running ~base_path "missing" with
   | KR.Deferred_unregistered -> ()
   | KR.Signaled | KR.Deferred_not_running _ ->
     fail "missing keeper did not return Deferred_unregistered");
  let running = register "running" in
  Atomic.set running.fiber_wakeup false;
  (match KR.wakeup_running ~base_path "running" with
   | KR.Signaled -> check bool "running keeper is signaled" true (Atomic.get running.fiber_wakeup)
   | KR.Deferred_unregistered | KR.Deferred_not_running _ ->
     fail "running keeper was not signaled");
  let offline_meta = make_meta "offline" in
  let offline = KR.register_offline ~base_path offline_meta.name offline_meta in
  Atomic.set offline.fiber_wakeup false;
  (match KR.wakeup_running ~base_path "offline" with
   | KR.Deferred_not_running phase ->
     check string "deferred phase is explicit" "offline" (KSM.phase_to_string phase);
     check bool "offline keeper is not signaled" false (Atomic.get offline.fiber_wakeup)
   | KR.Signaled | KR.Deferred_unregistered ->
     fail "offline keeper did not return Deferred_not_running")
;;

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir path =
  let rec rm target =
    if Sys.file_exists target
    then
      if Sys.is_directory target
      then (
        Sys.readdir target |> Array.iter (fun name -> rm (Filename.concat target name));
        Unix.rmdir target)
      else Unix.unlink target
  in
  try rm path with _ -> ()
;;

let contains_substring text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop idx =
    idx + needle_len <= text_len
    && (String.sub text idx needle_len = needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let test_tool_dispatch_fallback_uses_original_meta () =
  let dir = temp_dir "registry_fallback" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
       Eio_main.run @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let config = Masc.Workspace.default_config dir in
       let meta = make_meta "fallback-keeper" in
       let ctx_work =
         Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"test"
           ~max_tokens:4000
       in
       ignore (KR.register ~base_path:config.base_path meta.name meta);
       Fun.protect
         ~finally:(fun () -> KR.unregister ~base_path:config.base_path meta.name)
         (fun () ->
            (match KR.get_with_health ~base_path:config.base_path meta.name with
             | None -> fail "registered entry not found"
             | Some (entry, _) ->
               let corrupted_meta =
                 { entry.meta with
                   name = "wrong-name"
                 ; tool_denylist = [ "Read" ]
                 }
               in
               let corrupted = { entry with meta = corrupted_meta } in
               KR.For_testing.unsafe_put_entry ~base_path:config.base_path meta.name corrupted);
            let result =
              KET.execute_keeper_tool_call_with_outcome
                ~config
                ~meta
                ~ctx_work
                ~exec_cache:None
                ~name:"Read"
                ~input:(`Assoc [ ("file_path", `String "config/tool_policy.toml") ])
                ()
            in
            check
              bool
              "fallback used original meta (Read not denied by corrupted registry entry)"
              false
              (contains_substring result.raw_output "\"error\":\"tool_not_allowed\"")))
;;

let () =
  run
    "keeper_registry_hardening"
    [ ( "put_entry"
      , [ test_case "rejects meta name mismatch" `Quick test_put_entry_rejects_meta_name_mismatch ]
      )
    ; ( "update_entry"
      , [ test_case
            "rejects corrupted closure result and preserves original"
            `Quick
            test_update_entry_rejects_corrupted_result
        ; test_case
            "exact update preserves replacement lane"
            `Quick
            test_update_entry_exact_preserves_replacement_lane
        ] )
    ; ( "unregister_exact"
      , [ test_case
            "stale entry preserves replacement lane"
            `Quick
            test_unregister_exact_preserves_replacement_lane
        ; test_case
            "same lane immutable update remains removable"
            `Quick
            test_unregister_exact_accepts_same_lane_record_update
        ] )
    ; ( "dispatch_event"
      , [ test_case
            "skips phase side effects when validated write fails"
            `Quick
            test_dispatch_write_failure_skips_phase_side_effects
        ; test_case
            "exact dispatch preserves replacement lane"
            `Quick
            test_dispatch_event_exact_preserves_replacement_lane
        ] )
    ; ( "keeper_lane"
      , [ test_case
            "rejects fork on an already-cancelling switch"
            `Quick
            test_lane_fork_rejects_cancelling_switch
        ] )
    ; ( "get_with_health"
      , [ test_case "get filters corrupted entry" `Quick test_get_filters_corrupted_entry ] )
    ; ( "wakeup_running"
      , [ test_case
            "reports signaled and deferred outcomes"
            `Quick
            test_wakeup_running_reports_typed_outcome
        ] )
    ; ( "tool_dispatch_fallback"
      , [ test_case "uses original meta on corrupted registry entry" `Quick
            test_tool_dispatch_fallback_uses_original_meta
        ] )
    ]
;;
