(** Behavioural pin for the DUNE_SOURCEROOT markdown-dir fallback
    (#24377, #33239).

    Contract under test, in priority order:

    - (a) with no [set_markdown_dir] pin, a test executable running under
          dune (DUNE_SOURCEROOT set, [<root>/config/prompts] exists)
          resolves prompts through the fallback — the failure mode that
          broke dozens of quick-suite executables inside the CI sandbox
          can no longer exist
    - (b) an explicit [set_markdown_dir] pin always wins over the
          fallback, so fixtures that pin an empty directory to exercise
          true prompt absence (test_keeper_prompt_external's
          [with_task_create_prompt_missing]) keep working
    - (c) the fallback loads the directory it pins, so a slot key — the
          [### effect] paragraph of [judge.md], which has no file of its
          own — resolves and takes an override the same way a file key
          does
    - (d) [clear] unpins, and the next resolution pins and loads again,
          because suites call [clear] between cases and then rely on (c)
    - (e) an explicit pin loads its directory too, so a suite that pins
          [config/prompts] and never calls a load sees the slot keys
    - (f) the fallback never waits on the mutation lock: override
          validation reaches it while that lock is held, and with the Eio
          guard enabled the registry mutexes are real and do not re-enter

    This suite runs under dune, so DUNE_SOURCEROOT is present by
    construction; the no-dune (production) branch is byte-identical to the
    pre-change behaviour and is not reachable from a dune-run test. *)

open Alcotest

(* A prompt file that ships in config/prompts/ and is rendered on the live
   completion-review path — the exact key the CI failures named. *)
let known_prompt_key = "verification"

(* A slot key: the [### effect] paragraph of config/prompts/judge.md, not a
   file of its own, so it resolves only once the directory was loaded into
   the registry's slot table (#33239). *)
let slot_key = Prompt_names.judge_effect

let render_slot () = Prompt_registry.render_prompt_template slot_key []

let check_slot_renders label =
  match render_slot () with
  | Ok rendered ->
      check bool (label ^ ": rendered text is not empty") true
        (String.trim rendered <> "")
  | Error detail -> fail (label ^ ": " ^ detail)

let with_empty_dir f =
  let dir = Filename.temp_file "prompt-fallback-pin" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () -> f dir)

let test_fallback_engages_when_unpinned () =
  Prompt_registry.clear ();
  (match Prompt_registry.get_markdown_dir () with
   | Some dir ->
       check bool "fallback dir is <root>/config/prompts" true
         (Filename.check_suffix dir (Filename.concat "config" "prompts"))
   | None ->
       fail
         "expected the DUNE_SOURCEROOT fallback to engage for an unpinned \
          registry under dune");
  check bool "a shipped prompt resolves through the fallback" true
    (String.trim (Prompt_registry.get_prompt known_prompt_key) <> "")

let test_explicit_pin_wins_over_fallback () =
  Prompt_registry.clear ();
  with_empty_dir (fun dir ->
      Prompt_registry.set_markdown_dir dir;
      (match Prompt_registry.get_markdown_dir () with
       | Some pinned -> check string "pin is visible, not the fallback" dir pinned
       | None -> fail "explicit pin must be visible through get_markdown_dir");
      check string
        "prompt is truly absent under an empty pinned dir (fallback does \
         not leak through)"
        ""
        (String.trim (Prompt_registry.get_prompt known_prompt_key)))

let test_slot_key_resolves_through_the_fallback () =
  Prompt_registry.clear ();
  check_slot_renders "no pin, first resolution";
  check bool "the slot resolves against its group file judge.md" true
    (match (Prompt_registry.resolve_prompt slot_key).file_path with
     | Some path -> String.equal (Filename.basename path) "judge.md"
     | None -> false);
  match Prompt_registry.get_markdown_dir () with
  | Some dir ->
      check bool "the fallback left the registry pinned to <root>/config/prompts"
        true
        (Filename.check_suffix dir (Filename.concat "config" "prompts"))
  | None -> fail "the fallback must leave the registry pinned"

(* An override validates against the registered metadata, so a slot key
   the fallback did not register reads as an unknown key. *)
let test_slot_key_takes_an_override_through_the_fallback () =
  Prompt_registry.clear ();
  let override_text = "judge text under test" in
  (match Prompt_registry.set_override slot_key override_text with
   | Ok () -> ()
   | Error detail -> fail ("override on the fallback-loaded slot key: " ^ detail));
  check string "the override is the effective text" override_text
    (Prompt_registry.get_prompt slot_key);
  Prompt_registry.clear ()

let test_fallback_loads_again_after_clear () =
  Prompt_registry.clear ();
  check_slot_renders "before clear";
  Prompt_registry.clear ();
  check_slot_renders "after clear"

let test_explicit_empty_pin_keeps_the_slot_key_missing () =
  Prompt_registry.clear ();
  with_empty_dir (fun dir ->
      Prompt_registry.set_markdown_dir dir;
      match render_slot () with
      | Ok rendered ->
          fail ("slot key resolved under an empty pinned dir: " ^ rendered)
      | Error detail ->
          check string "missing, not some other error"
            (Printf.sprintf "Prompt '%s' is missing" slot_key)
            detail)

(* The shape test_hitl_summary_worker uses: an explicit pin and no load
   call. *)
let test_explicit_pin_loads_the_directory () =
  Prompt_registry.clear ();
  Prompt_registry.set_markdown_dir (Masc_test_deps.source_path "config/prompts");
  check_slot_renders "explicit pin, no load call"

(* One fiber holds the mutation lock; another resolves a slot key in an
   unpinned registry, which pins and loads the fallback. The resolving
   fiber holds no lock, so [Eio.Mutex.lock] waits outside any
   [Cancel.protect] and the timeout can cancel it: a fallback that waited
   on the mutation lock fails here instead of hanging the suite. *)
let test_fallback_does_not_wait_on_the_mutation_lock () =
  Prompt_registry.clear ();
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Eio_guard.enable ();
  Eio.Switch.on_release sw Eio_guard.disable;
  let held, resolve_held = Eio.Promise.create () in
  let release, resolve_release = Eio.Promise.create () in
  let holder =
    Eio.Fiber.fork_promise ~sw (fun () ->
        Prompt_registry_store.with_override_mutation_lock
          (Prompt_registry_store.default ())
          (fun () ->
            Eio.Promise.resolve resolve_held ();
            Eio.Promise.await release))
  in
  Eio.Promise.await held;
  let outcome =
    match Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 render_slot with
    | result -> result
    | exception Eio.Time.Timeout ->
        Error "the fallback waited on the mutation lock another fiber holds"
  in
  Eio.Promise.resolve resolve_release ();
  Eio.Promise.await_exn holder;
  (match outcome with
   | Ok rendered ->
       check bool "rendered text is not empty" true (String.trim rendered <> "")
   | Error detail -> fail detail);
  Prompt_registry.clear ()

let () =
  run "prompt_registry_dune_fallback"
    [
      ( "markdown_dir_fallback",
        [
          test_case "unpinned registry falls back to DUNE_SOURCEROOT" `Quick
            test_fallback_engages_when_unpinned;
          test_case "explicit pin wins over the fallback" `Quick
            test_explicit_pin_wins_over_fallback;
          test_case "a slot key resolves through the fallback" `Quick
            test_slot_key_resolves_through_the_fallback;
          test_case "a slot key takes an override through the fallback" `Quick
            test_slot_key_takes_an_override_through_the_fallback;
          test_case "the fallback loads again after clear" `Quick
            test_fallback_loads_again_after_clear;
          test_case "an explicit empty pin keeps the slot key missing" `Quick
            test_explicit_empty_pin_keeps_the_slot_key_missing;
          test_case "an explicit pin loads the directory it pins" `Quick
            test_explicit_pin_loads_the_directory;
          test_case "the fallback does not wait on the mutation lock" `Quick
            test_fallback_does_not_wait_on_the_mutation_lock;
        ] );
    ]
