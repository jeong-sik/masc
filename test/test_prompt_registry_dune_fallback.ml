(** Behavioural pin for the DUNE_SOURCEROOT markdown-dir fallback
    (quick-suite unmasking #24377, 'Prompt ... is missing' class).

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

    This suite runs under dune, so DUNE_SOURCEROOT is present by
    construction; the no-dune (production) branch is byte-identical to the
    pre-change behaviour and is not reachable from a dune-run test. *)

open Alcotest

(* A prompt file that ships in config/prompts/ and is rendered on the live
   completion-review path — the exact key the CI failures named. *)
let known_prompt_key = "verification.anti_rationalization"

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
  let dir = Filename.temp_file "prompt-fallback-pin" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () ->
      Prompt_registry.set_markdown_dir dir;
      (match Prompt_registry.get_markdown_dir () with
       | Some pinned -> check string "pin is visible, not the fallback" dir pinned
       | None -> fail "explicit pin must be visible through get_markdown_dir");
      check string
        "prompt is truly absent under an empty pinned dir (fallback does \
         not leak through)"
        ""
        (String.trim (Prompt_registry.get_prompt known_prompt_key)))

let () =
  run "prompt_registry_dune_fallback"
    [
      ( "markdown_dir_fallback",
        [
          test_case "unpinned registry falls back to DUNE_SOURCEROOT" `Quick
            test_fallback_engages_when_unpinned;
          test_case "explicit pin wins over the fallback" `Quick
            test_explicit_pin_wins_over_fallback;
        ] );
    ]
