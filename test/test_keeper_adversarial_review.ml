(** Tests for [Keeper_adversarial_review] wake-on-fail routing.

    The LLM judgment ([run_review]) needs a runtime and is exercised through
    the shared engine elsewhere; here we verify the deterministic part: a [Fail]
    verdict records an attention item for the author keeper, [Pass]/[Warn] do
    not, and repeated task-level FAIL verdicts deduplicate. *)

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

let ensure_fs env =
  Masc.Server_startup_state.mark_state_ready
    ~backend:Masc.Server_startup_state.Filesystem_backend
  |> Result.get_ok;
  Masc_test_deps.init_eio_clock env;
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env)

let publication_recovery_registry env sw config =
  let registry_root =
    Eio.Path.(Eio.Stdenv.fs env / Masc.Workspace.masc_root_dir config)
  in
  match
    Fs_compat.open_publication_recovery_registry
      ~sw
      ~fs:(Eio.Stdenv.fs env)
      ~registry_root
  with
  | Ok registry -> registry
  | Error error ->
    fail
      (Fs_compat.publication_recovery_registry_error_to_string error)

let operator_ctx env sw config agent_name : _ Operator_control.context =
  {
    config;
    agent_name;
    sw;
    clock = Eio.Stdenv.clock env;
    proc_mgr = Some (Eio.Stdenv.process_mgr env);
    net = Some (Eio.Stdenv.net env);
    publication_recovery_provider =
      Masc_test_deps.publication_recovery_provider
        (publication_recovery_registry env sw config);
    mcp_session_id = None;
  }

let make_meta name : Masc.Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

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

let input_with_evidence ~author evidence_refs : AR.review_input =
  { (input ~author) with evidence_refs }

let pending base ~keeper =
  EA.pending_for_keeper ~base_path:base ~keeper_name:keeper ~limit:50 ()

let check_ok = function
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg

let test_response_text_accepts_strict_json () =
  let raw =
    {|{"verdict":"FAIL","reason":"bad branch","evidence":[{"path":"lib/foo.ml","line":12,"quote":"let bad = true"}]}|}
  in
  match AR.For_testing.parse_grounded_verdict_from_response_text raw with
  | Ok grounded ->
    check string
      "verdict"
      "FAIL"
      (VC.verdict_constructor_name grounded.VC.verdict);
    check int "evidence count" 1 (List.length grounded.VC.evidence)
  | Error msg -> fail ("strict JSON response rejected: " ^ msg)

let test_response_text_rejects_embedded_json () =
  let raw =
    {|Here is the verdict: {"verdict":"PASS","reason":null,"evidence":[]}|}
  in
  match AR.For_testing.parse_grounded_verdict_from_response_text raw with
  | Error _ -> ()
  | Ok grounded ->
    failf
      "embedded JSON should be rejected, got %s"
      (VC.verdict_to_string grounded.VC.verdict)

let check_response_text_rejected label raw =
  match AR.For_testing.parse_grounded_verdict_from_response_text raw with
  | Error _ -> ()
  | Ok grounded ->
    failf
      "%s should be rejected, got %s"
      label
      (VC.verdict_to_string grounded.VC.verdict)

let test_response_text_rejects_empty_text () =
  check_response_text_rejected "empty response" "";
  check_response_text_rejected "whitespace response" "  \n\t  "

let test_response_text_rejects_malformed_json () =
  check_response_text_rejected
    "malformed JSON response"
    {|{"verdict":"PASS","reason":null,"evidence":[]|}

let test_response_text_rejects_non_object_json () =
  check_response_text_rejected
    "array JSON response"
    {|[{"verdict":"PASS","reason":null,"evidence":[]}]|}

let test_fail_wakes_author () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      check int "no pending before" 0 (List.length (pending base ~keeper:author));
      AR.act_on_verdict ~base_path:base ~input:(input ~author)
        (VC.Fail "unhandled error path at foo.ml:10")
      |> check_ok;
      let items = pending base ~keeper:author in
      check int "one pending after fail" 1 (List.length items);
      let item = List.hd items in
      check bool "reason carried in preview" true
        (String.length item.EA.content_preview > 0))

let test_pass_does_not_wake () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      AR.act_on_verdict ~base_path:base ~input:(input ~author) VC.Pass
      |> check_ok;
      check int "no pending after pass" 0
        (List.length (pending base ~keeper:author)))

let test_warn_does_not_wake () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      AR.act_on_verdict ~base_path:base ~input:(input ~author) (VC.Warn "minor")
      |> check_ok;
      check int "no pending after warn" 0
        (List.length (pending base ~keeper:author)))

let test_fail_dedup_different_reasons () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      AR.act_on_verdict ~base_path:base ~input:(input ~author)
        (VC.Fail "error path at foo.ml:10")
      |> check_ok;
      AR.act_on_verdict ~base_path:base ~input:(input ~author)
        (VC.Fail "same bug, different wording at foo.ml:11")
      |> check_ok;
      check int "dedup: still one pending for the task" 1
        (List.length (pending base ~keeper:author)))

let test_grounded_fail_carries_evidence_metadata () =
  with_temp_base (fun base ->
      let author = "builder-keeper" in
      let evidence : VC.grounded_ref =
        { path = "lib/foo.ml"; line = Some 12; quote = "let bad = true" }
      in
      let grounded =
        match VC.grounded_of (VC.Fail "bad branch") [ evidence ] with
        | Ok value -> value
        | Error msg -> fail msg
      in
      AR.act_on_grounded_verdict ~base_path:base ~input:(input ~author) grounded
      |> check_ok;
      let item =
        match pending base ~keeper:author with
        | [ item ] -> item
        | items -> failf "expected one pending item, got %d" (List.length items)
      in
      check (option string) "evidence count metadata" (Some "1")
        (List.assoc_opt "evidence_count" item.EA.metadata);
      let grounded_json =
        match List.assoc_opt "grounded_verdict" item.EA.metadata with
        | Some raw -> Yojson.Safe.from_string raw
        | None -> fail "missing grounded_verdict metadata"
      in
      let open Yojson.Safe.Util in
      check string "grounded verdict" "FAIL"
        (grounded_json |> member "verdict" |> to_string);
      let first = grounded_json |> member "evidence" |> to_list |> List.hd in
      check string "grounded path" "lib/foo.ml"
        (first |> member "path" |> to_string);
      check int "grounded line" 12 (first |> member "line" |> to_int);
      check string "grounded quote" "let bad = true"
        (first |> member "quote" |> to_string))

let test_digest_projects_grounded_external_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let author = "builder-keeper" in
  with_temp_base (fun base ->
      Fun.protect
        ~finally:(fun () ->
          Masc.Keeper_keepalive.stop_keepalive author;
          Masc.Keeper_registry.clear ();
          Masc.Keeper_runtime.reset_test_state base)
        (fun () ->
          let config = Masc.Workspace.default_config base in
          ignore (Masc.Workspace.init config ~agent_name:(Some "operator"));
          (match Masc.Keeper_meta_store.write_meta config (make_meta author) with
          | Ok () -> ()
          | Error err -> fail ("write_meta failed: " ^ err));
          let evidence : VC.grounded_ref =
            { path = "lib/foo.ml"; line = Some 12; quote = "let bad = true" }
          in
          let grounded =
            match VC.grounded_of (VC.Fail "bad branch") [ evidence ] with
            | Ok value -> value
            | Error msg -> fail msg
          in
          AR.act_on_grounded_verdict ~base_path:base ~input:(input ~author)
            grounded
          |> check_ok;
          let digest =
            match
              Operator_control.digest_json ~actor:"dashboard"
                (operator_ctx env sw config "dashboard")
            with
            | Ok json -> json
            | Error err -> fail err
          in
          let open Yojson.Safe.Util in
          let attention_items = digest |> member "attention_items" |> to_list in
          let review_attention =
            attention_items
            |> List.find_opt (fun item ->
                 let target_id_matches =
                   match item |> member "target_id" with
                   | `String value -> String.equal value author
                   | _ -> false
                 in
                 (item |> member "kind" |> to_string)
                 = "keeper_review_rejected"
                 && target_id_matches)
            |> Option.value ~default:`Null
          in
          check bool "review attention projected" true
            (review_attention <> `Null);
          check string "review attention severity" "bad"
            (review_attention |> member "severity" |> to_string);
          let grounded_json =
            review_attention |> member "evidence" |> member "grounded_verdict"
            |> to_string |> Yojson.Safe.from_string
          in
          let first = grounded_json |> member "evidence" |> to_list |> List.hd in
          check string "projected grounded path" "lib/foo.ml"
            (first |> member "path" |> to_string);
          check int "projected grounded line" 12
            (first |> member "line" |> to_int)))

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

let test_build_prompt_preserves_literal_braces_in_values () =
  with_prompt_dir
    ~variables:[ "task_title"; "task_description"; "evidence_refs" ]
    "Evidence: {{evidence_refs}}\n"
    (fun () ->
      let evidence_refs = {|snippet: "{{ .Release.Name }}"|} in
      match
        AR.build_prompt
          (input_with_evidence ~author:"builder-keeper" evidence_refs)
      with
      | Ok rendered ->
        check bool "literal braces from value preserved" true
          (try
             ignore
               (Str.search_forward
                  (Str.regexp_string {|{{ .Release.Name }}|})
                  rendered 0);
             true
           with Not_found -> false)
      | Error msg -> fail msg)

let () =
  Alcotest.run "keeper-adversarial-review"
    [
      ( "response-parser",
        [
          test_case "accepts strict JSON response" `Quick
            test_response_text_accepts_strict_json;
          test_case "rejects embedded JSON response" `Quick
            test_response_text_rejects_embedded_json;
          test_case "rejects empty response text" `Quick
            test_response_text_rejects_empty_text;
          test_case "rejects malformed JSON response" `Quick
            test_response_text_rejects_malformed_json;
          test_case "rejects non-object JSON response" `Quick
            test_response_text_rejects_non_object_json;
        ] );
      ( "wake-on-fail",
        [
          test_case "fail wakes author" `Quick test_fail_wakes_author;
          test_case "pass no wake" `Quick test_pass_does_not_wake;
          test_case "warn no wake" `Quick test_warn_does_not_wake;
          test_case "fail dedup different reasons" `Quick
            test_fail_dedup_different_reasons;
          test_case "grounded fail carries evidence metadata" `Quick
            test_grounded_fail_carries_evidence_metadata;
          test_case "digest projects grounded external attention" `Quick
            test_digest_projects_grounded_external_attention;
        ] );
      ( "render-fail-closed",
        [
          test_case "build_prompt replaces all variables" `Quick
            test_build_prompt_replaces_variables;
          test_case "build_prompt errors on unresolved variable" `Quick
            test_build_prompt_fails_closed_on_unresolved_variable;
          test_case "build_prompt preserves literal braces in values" `Quick
            test_build_prompt_preserves_literal_braces_in_values;
        ] );
    ]
