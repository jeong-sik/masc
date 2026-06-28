(** Tests for [Keeper_unified_turn_completion_contract.clear_for_operator_resume]
    — the typed latch recovery that closes the "resume doesn't stick"
    symptom in RFC-0047 §3.2 / plan hypothesis B.

    Pinned invariants:
    1. Boundary: the function clears ONLY the completion-contract latch
       pair — typed [last_failure_reason] when it is
       [Completion_contract_violation] and the meta
       [last_blocker] when its klass is [Completion_contract_violation].
       It must not touch [paused] (owned by the resume_reconcile_gate).
    2. Idempotence: running it twice on a clean meta is a no-op (no
       spurious side effects, no log lines).
    3. Cross-klass safety: a meta whose [last_blocker.klass] is
       [No_progress_loop] (or any other klass) is left untouched,
       even when [last_failure_reason] carries the
       completion-contract variant. The function reads them
       independently.
    4. Failure-reason cross-kind safety: an unrelated
       [Provider_runtime_error] failure reason is left alone. *)

open Alcotest

module KMR = Masc.Keeper_meta_contract
module KR = Masc.Keeper_registry
module CC = Masc.Keeper_unified_turn_completion_contract

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  dir
;;

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Unix.unlink path
  in
  try rm dir with
  | Sys_error _
  | Unix.Unix_error _ -> ()
;;

let legacy_base_json name =
  `Assoc
    [
      "name", `String name;
      "agent_name", `String (name ^ "-agent");
      "trace_id", `String ("trace-" ^ name);
      "tool_access", `List [];
    ]
;;

let make_meta name =
  match Masc.Keeper_meta_json_parse.meta_of_json (legacy_base_json name) with
  | Ok m -> m
  | Error err -> fail ("parse base: " ^ err)
;;

let completion_contract_failure_reason ?(detail = "completion contract violated") () =
  KR.Completion_contract_violation { detail }
;;

let unrelated_provider_runtime code =
  KR.Provider_runtime_error
    { code
    ; detail = "unrelated"
    ; provider_id = None
    ; http_status = None
    ; runtime_id = None
    ; reason = None
    }
;;

let test_clears_both_latches_when_both_set () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-both-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-both" in
       let blocker =
         KMR.blocker_info_of_class
           ~detail:"completion contract violated"
           KMR.Completion_contract_violation
       in
       let meta =
         make_meta keeper_name
         |> KMR.map_runtime (fun rt -> { rt with last_blocker = Some blocker })
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some (completion_contract_failure_reason ()));
       (* Sanity: both latches set before resume *)
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          (match entry.Masc.Keeper_registry.last_failure_reason with
           | Some (KR.Completion_contract_violation _) ->
             check string
               "pre-resume: failure reason is completion_contract_violation"
               CC.failure_reason_code
               CC.failure_reason_code
           | Some _ -> fail "expected Completion_contract_violation pre-resume"
           | None -> fail "expected Some failure_reason pre-resume");
          check bool
            "pre-resume: meta last_blocker klass is Completion_contract_violation"
            true
            (match entry.Masc.Keeper_registry.meta.runtime.last_blocker with
             | Some { KMR.klass = KMR.Completion_contract_violation; _ } -> true
             | _ -> false)
        | None -> fail "expected registered keeper pre-resume");
       let resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       (* last_blocker cleared in returned meta *)
       (match resumed_meta.runtime.last_blocker with
        | None -> ()
        | Some _ -> fail "expected last_blocker cleared in returned meta");
       (* Side effect: failure reason cleared in registry *)
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          (match entry.Masc.Keeper_registry.last_failure_reason with
           | None -> ()
           | Some _ -> fail "expected registry failure_reason cleared")
        | None -> fail "expected registered keeper post-resume"))
;;

let test_clears_only_meta_when_failure_reason_missing () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-meta-only-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-meta-only" in
       let blocker =
         KMR.blocker_info_of_class
           ~detail:"completion contract violated"
           KMR.Completion_contract_violation
       in
       let meta =
         make_meta keeper_name
         |> KMR.map_runtime (fun rt -> { rt with last_blocker = Some blocker })
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       (* No failure_reason set — function must still clear meta blocker. *)
       let resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       (match resumed_meta.runtime.last_blocker with
        | None -> ()
        | Some _ -> fail "expected meta blocker cleared even with no failure_reason"))
;;

let test_preserves_unrelated_blocker_klass () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-no-progress-meta-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-no-progress-meta" in
       let blocker =
         KMR.blocker_info_of_class
           ~detail:"no_progress loop detected"
           KMR.No_progress_loop
       in
       let meta =
         make_meta keeper_name
         |> KMR.map_runtime (fun rt -> { rt with last_blocker = Some blocker })
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       (* failure_reason IS the completion-contract code, but the meta
          blocker is No_progress_loop → function must NOT touch it. *)
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some (completion_contract_failure_reason ()));
       let resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       (match resumed_meta.runtime.last_blocker with
        | Some { KMR.klass = KMR.No_progress_loop; _ } -> ()
        | Some _ ->
          fail "expected No_progress_loop blocker preserved, got a different klass"
        | None -> fail "expected No_progress_loop blocker preserved");
       (* failure_reason IS cleared because its code matches *)
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          (match entry.Masc.Keeper_registry.last_failure_reason with
           | None -> ()
           | Some _ -> fail "expected registry failure_reason cleared")
        | None -> fail "expected registered keeper"))
;;

let test_preserves_unrelated_failure_reason_code () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-other-code-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-other-code" in
       let blocker =
         KMR.blocker_info_of_class
           ~detail:"completion contract violated"
           KMR.Completion_contract_violation
       in
       let meta =
         make_meta keeper_name
         |> KMR.map_runtime (fun rt -> { rt with last_blocker = Some blocker })
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       (* Different code → registry side effect must not fire. *)
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some (unrelated_provider_runtime "some_other_failure_code"));
       let _resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       (* failure_reason code preserved *)
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          (match entry.Masc.Keeper_registry.last_failure_reason with
           | Some (KR.Provider_runtime_error { code; _ }) ->
             check string
               "unrelated failure reason code preserved"
               "some_other_failure_code"
               code
           | Some _ -> fail "expected Provider_runtime_error preserved"
           | None -> fail "expected unrelated failure reason preserved")
        | None -> fail "expected registered keeper"))
;;

let test_failure_reason_does_not_touch_meta_blocker () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-fail-reason-only-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-fail-reason-only" in
       (* Meta has NO blocker; only the registry failure_reason matches.
          Function must clear the registry entry but the returned meta
          is byte-identical to the input. *)
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some (completion_contract_failure_reason ()));
       let resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       check bool
         "returned meta byte-identical when meta blocker absent"
         true
         (resumed_meta = meta);
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          (match entry.Masc.Keeper_registry.last_failure_reason with
           | None -> ()
           | Some _ -> fail "expected registry failure_reason cleared")
        | None -> fail "expected registered keeper"))
;;

let test_no_op_on_clean_meta () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-clean-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-clean" in
       let meta = make_meta keeper_name in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       let resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       check bool "no-op on clean meta" true (resumed_meta = meta))
;;

let test_does_not_touch_paused () =
  (* Boundary: clear_for_operator_resume must NOT mutate
     [paused] — that is the reconcile_gate's responsibility. *)
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir "masc-cc-boundary-" in
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
       let keeper_name = "cc-boundary" in
       let blocker =
         KMR.blocker_info_of_class
           ~detail:"completion contract violated"
           KMR.Completion_contract_violation
       in
       let meta =
         { (make_meta keeper_name
            |> KMR.map_runtime (fun rt -> { rt with last_blocker = Some blocker }))
           with
           paused = true
         }
       in
       Masc.Keeper_registry.clear ();
       ignore (Masc.Keeper_registry.register ~base_path:config.base_path keeper_name meta);
       Masc.Keeper_registry.set_failure_reason
         ~base_path:config.base_path
         keeper_name
         (Some (completion_contract_failure_reason ()));
       let resumed_meta = CC.clear_for_operator_resume ~base_path:config.base_path meta in
       check bool "paused preserved" true resumed_meta.paused;
       (* Registry-side paused state also untouched. *)
       (match Masc.Keeper_registry.get ~base_path:config.base_path keeper_name with
        | Some entry ->
          check bool
            "registry meta.paused preserved"
            true
            entry.Masc.Keeper_registry.meta.paused
        | None -> fail "expected registered keeper"))
;;

let () =
  run "keeper_unified_turn_completion_contract"
    [ ( "latch recovery",
        [ test_case "clears both latches when both set" `Quick
            test_clears_both_latches_when_both_set
        ; test_case "clears meta-only when failure_reason missing" `Quick
            test_clears_only_meta_when_failure_reason_missing
        ; test_case "preserves unrelated blocker klass" `Quick
            test_preserves_unrelated_blocker_klass
        ; test_case "preserves unrelated failure_reason code" `Quick
            test_preserves_unrelated_failure_reason_code
        ; test_case "failure_reason match does not touch meta blocker" `Quick
            test_failure_reason_does_not_touch_meta_blocker
        ; test_case "no-op on clean meta" `Quick
            test_no_op_on_clean_meta
        ; test_case "does not touch paused" `Quick
            test_does_not_touch_paused
        ] ) ]
;;
