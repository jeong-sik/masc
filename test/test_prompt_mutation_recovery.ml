exception Observer_failed
exception Cancel_waiter

let key = "test.recovery"

let write_file path contents =
  let channel = open_out path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)

let with_registry f =
  Eio_main.run @@ fun _env ->
  Eio_guard.enable ();
  let base_path = Filename.temp_file "prompt-recovery-" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  let prompts = Filename.concat base_path "prompts" in
  Unix.mkdir prompts 0o700;
  let masc_dir = Filename.concat base_path ".masc" in
  Unix.mkdir masc_dir 0o700;
  write_file (Filename.concat prompts (key ^ ".md"))
    "---\ndescription: recovery fixture\ncategory: test\n---\nfile body";
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.set_restore_failure_observer (fun () -> ());
      Prompt_registry.clear ();
      Eio_guard.disable ();
      Fs_compat.remove_tree base_path)
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir prompts;
      f ~base_path ~path:(Filename.concat masc_dir "prompt_overrides.json"))

let set_persisted base_path text =
  match Prompt_registry.set_override_persisted ~base_path key text with
  | Ok () -> ()
  | Error (Validation_error detail | Persistence_error detail) ->
      Alcotest.fail detail

let test_observer_failure_keeps_committed_restore_and_allows_next_write () =
  with_registry @@ fun ~base_path ~path ->
  set_persisted base_path "stale override";
  write_file path "{";
  let failure = Observer_failed in
  Prompt_registry.set_restore_failure_observer (fun () -> raise failure);
  (match Prompt_registry.restore_overrides base_path with
   | () -> Alcotest.fail "observer failure disappeared"
   | exception exn ->
       Alcotest.(check bool) "original observer exception" true (exn == failure));
  Alcotest.(check string) "rejected restore already committed fallback"
    "file body" (Prompt_registry.get_prompt key);
  Prompt_registry.set_restore_failure_observer (fun () -> ());
  set_persisted base_path "repaired override";
  Prompt_registry.clear_prompt_override key;
  Prompt_registry.restore_overrides base_path;
  Alcotest.(check string) "next persisted mutation survives reload"
    "repaired override" (Prompt_registry.get_prompt key);
  (match Prompt_registry.clear_prompt_override_persisted ~base_path key with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  Prompt_registry.restore_overrides base_path;
  Alcotest.(check string) "persisted clear remains usable"
    "file body" (Prompt_registry.get_prompt key)

let test_observer_can_persist_a_followup () =
  with_registry @@ fun ~base_path ~path ->
  write_file path "{";
  let observed_fallback = ref false in
  Prompt_registry.set_restore_failure_observer (fun () ->
    observed_fallback := String.equal "file body" (Prompt_registry.get_prompt key);
    set_persisted base_path "observer repair");
  Prompt_registry.restore_overrides base_path;
  Alcotest.(check bool) "observer sees committed fallback" true !observed_fallback;
  Alcotest.(check string) "observer mutation remains live"
    "observer repair" (Prompt_registry.get_prompt key);
  Prompt_registry.set_restore_failure_observer (fun () -> ());
  Prompt_registry.clear_prompt_override key;
  Prompt_registry.restore_overrides base_path;
  Alcotest.(check string) "observer repair is durable"
    "observer repair" (Prompt_registry.get_prompt key)

let test_coordination_exceptions_keep_identity_backtrace_and_reusability () =
  with_registry @@ fun ~base_path:_ ~path:_ ->
  let store = Prompt_registry_store.default () in
  let locked f = Prompt_registry_store.with_override_mutation_lock store f in
  List.iter
    (fun failure ->
      let original_backtrace = ref "" in
      (match locked (fun () ->
         try raise failure with exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           original_backtrace := Printexc.raw_backtrace_to_string backtrace;
           Printexc.raise_with_backtrace exn backtrace) with
       | () -> Alcotest.fail "coordination exception disappeared"
       | exception exn ->
           let backtrace = Printexc.get_raw_backtrace () in
           Alcotest.(check bool) "original exception identity" true (exn == failure);
           (* Re-raise adds propagation frames; the original throwing frames
              remain the prefix rather than being replaced by the unlock site. *)
           let observed = Printexc.raw_backtrace_to_string backtrace in
           Alcotest.(check bool) "throwing frames were captured" true
             (String.length !original_backtrace > 0);
           Alcotest.(check bool) "original throwing frames retained" true
             (String.starts_with ~prefix:!original_backtrace observed));
      Alcotest.(check int) "coordination lock remains usable" 42
        (locked (fun () -> 42)))
    [ Failure "callback failure"; Eio.Cancel.Cancelled Cancel_waiter ]

let test_waiting_mutation_is_cancellable () =
  with_registry @@ fun ~base_path:_ ~path:_ ->
  let store = Prompt_registry_store.default () in
  let locked f = Prompt_registry_store.with_override_mutation_lock store f in
  Eio.Switch.run @@ fun sw ->
  let held, signal_held = Eio.Promise.create () in
  let release, signal_release = Eio.Promise.create () in
  let owner_done, signal_owner_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    locked (fun () ->
      Eio.Promise.resolve signal_held ();
      Eio.Promise.await release);
    Eio.Promise.resolve signal_owner_done ());
  Eio.Promise.await held;
  let context, signal_context = Eio.Promise.create () in
  let cancelled, signal_cancelled = Eio.Promise.create () in
  let entered = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    let was_cancelled =
      try
        Eio.Cancel.sub (fun cancellation ->
          Eio.Promise.resolve signal_context cancellation;
          locked (fun () -> entered := true));
        false
      with Eio.Cancel.Cancelled _ -> true
    in
    Eio.Promise.resolve signal_cancelled was_cancelled);
  Eio.Cancel.cancel (Eio.Promise.await context) Cancel_waiter;
  let was_cancelled = Eio.Promise.await cancelled in
  Eio.Promise.resolve signal_release ();
  Eio.Promise.await owner_done;
  Alcotest.(check bool) "waiting cancellation propagated" true was_cancelled;
  Alcotest.(check bool) "cancelled mutation never entered" false !entered;
  Alcotest.(check int) "subsequent mutation enters" 7 (locked (fun () -> 7))

let () =
  Printexc.record_backtrace true;
  Alcotest.run "prompt-mutation-recovery"
    [ "recovery",
      [ Alcotest.test_case "raising observer preserves commit and future writes"
          `Quick test_observer_failure_keeps_committed_restore_and_allows_next_write
      ; Alcotest.test_case "observer can persist a followup" `Quick
          test_observer_can_persist_a_followup
      ; Alcotest.test_case "coordination exceptions preserve provenance" `Quick
          test_coordination_exceptions_keep_identity_backtrace_and_reusability
      ; Alcotest.test_case "waiting mutation cancellation" `Quick
          test_waiting_mutation_is_cancellable
      ] ]
