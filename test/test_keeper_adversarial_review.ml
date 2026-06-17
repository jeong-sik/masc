(** Tests for [Keeper_adversarial_review] wake-on-fail routing.

    The LLM judgment ([run_review]) needs a runtime and is exercised through
    the shared engine elsewhere; here we verify the deterministic part: a [Fail]
    verdict records an attention item for the author keeper, [Pass]/[Warn] do
    not, and the same rejection deduplicates. *)

open Alcotest
module AR = Masc.Keeper_adversarial_review
module EA = Masc.Keeper_external_attention
module VC = Masc.Verifier_core
module PR = Prompt_registry

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun e -> rm_rf (Filename.concat path e));
      Unix.rmdir path)
    else
      Sys.remove path

let with_temp_base f =
  let base = Filename.temp_file "adv_review_test" "" in
  Sys.remove base;
  Sys.mkdir base 0o755;
  Fun.protect ~finally:(fun () -> rm_rf base) (fun () -> f base)

let write_prompt_file dir ~variables body =
  let path = Filename.concat dir "verification.adversarial_review.md" in
  let content =
    Printf.sprintf
      "---\ndescription: test adversarial review prompt\ncategory: \
       verification\ntemplate_variables: [%s]\n---\n\n%s"
      (String.concat ", " variables)
      body
  in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc content)

let with_prompt_dir ~variables body f =
  let dir = Filename.temp_file "adv_review_prompt" "" in
  Sys.remove dir;
  Sys.mkdir dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      rm_rf dir;
      PR.clear ())
    (fun () ->
      write_prompt_file dir ~variables body;
      PR.set_markdown_dir dir;
      PR.load_prompts_from_directory dir;
      f ())

let input ~author : AR.review_input =
  {
    task_id = "task-42";
    task_title = "Add immutable cache";
    task_description = "Refactor link cache to immutable map";
    author_keeper = author;
    evidence_refs = "PR #123";
  }

let pending base ~keeper =
  EA.pending_for_keeper ~base_path:base ~keeper_name:keeper ~limit:50 ()

let test_fail_wakes_author () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      check int "no pending before" 0 (List.length (pending base ~keeper:author));
      AR.act_on_verdict ~base_path:base ~input:(input ~author)
        (VC.Fail "unhandled error path at foo.ml:10");
      let items = pending base ~keeper:author in
      check int "one pending after fail" 1 (List.length items);
      let item = List.hd items in
      check bool "reason carried in preview" true
        (String.length item.EA.content_preview > 0))

let test_pass_does_not_wake () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      AR.act_on_verdict ~base_path:base ~input:(input ~author) VC.Pass;
      check int "no pending after pass" 0
        (List.length (pending base ~keeper:author)))

let test_warn_does_not_wake () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      AR.act_on_verdict ~base_path:base ~input:(input ~author) (VC.Warn "minor");
      check int "no pending after warn" 0
        (List.length (pending base ~keeper:author)))

let test_fail_dedup_same_reason () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      let v = VC.Fail "same reason" in
      AR.act_on_verdict ~base_path:base ~input:(input ~author) v;
      AR.act_on_verdict ~base_path:base ~input:(input ~author) v;
      check int "dedup: still one pending" 1
        (List.length (pending base ~keeper:author)))

let test_build_prompt_replaces_variables () =
  with_prompt_dir
    ~variables:[ "task_title"; "task_description"; "evidence_refs" ]
    "Title: {{task_title}}\nDescription: {{task_description}}\nEvidence: {{evidence_refs}}\n"
    (fun () ->
      match AR.build_prompt (input ~author:"builder-keeper") with
      | Ok rendered ->
        check bool "contains title" true
          (try
             ignore (Str.search_forward (Str.regexp_string "Add immutable cache") rendered 0);
             true
           with Not_found -> false);
        check bool "no raw braces" true
          (try
             ignore (Str.search_forward (Str.regexp_string "{{") rendered 0);
             false
           with Not_found -> true)
      | Error msg -> fail msg)

let test_build_prompt_fails_closed_on_unresolved_variable () =
  with_prompt_dir
    ~variables:[ "task_title"; "task_description"; "evidence_refs"; "unknown_var" ]
    "Missing {{unknown_var}}"
    (fun () ->
      match AR.build_prompt (input ~author:"builder-keeper") with
      | Ok rendered -> fail ("expected error, got: " ^ rendered)
      | Error msg -> check bool "error reported" true (String.length msg > 0))

let () =
  Alcotest.run "keeper-adversarial-review"
    [
      ( "wake-on-fail",
        [
          test_case "fail wakes author" `Quick test_fail_wakes_author;
          test_case "pass no wake" `Quick test_pass_does_not_wake;
          test_case "warn no wake" `Quick test_warn_does_not_wake;
          test_case "fail dedup same reason" `Quick test_fail_dedup_same_reason;
        ] );
      ( "render-fail-closed",
        [
          test_case "build_prompt replaces all variables" `Quick
            test_build_prompt_replaces_variables;
          test_case "build_prompt errors on unresolved variable" `Quick
            test_build_prompt_fails_closed_on_unresolved_variable;
        ] );
    ]
