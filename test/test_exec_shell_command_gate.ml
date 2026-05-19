(** Phase 1 SSOT facade tests + Phase 0 baseline corpus driver.

    SSOT: Shell IR Promotion Goal Plan - 2026-05-18, Phase 0 PR-A
    (baseline corpus) and Phase 1 PR-1 (Shell_command_gate facade).

    This file exercises three contracts:

    1. [Masc_exec_command_gate.Shell_command_gate.gate] verdict shape
       matches what {!test/fixtures/shell_gate/baseline.jsonl}
       records for each corpus row (Phase 0 - baseline pin).
    2. [Masc_mcp.Worker_dev_tools.validate_command_coding_with_allowlist]
       legacy verdict also matches the recorded baseline so any future
       behavior change (Phase 2+) is visible as a corpus diff, not as
       a silent flip.
    3. Phase 1 facade-specific Plan invariants that the JSONL corpus
       cannot express cleanly: quoted pipe single-stage shape, real
       3-stage pipeline ordering, nested pipeline rejection,
       typed-pipeline lowering through [lower_typed_pipeline]. *)

module Gate = Masc_exec_command_gate.Shell_command_gate
module W = Masc_mcp.Worker_dev_tools

let allowed = [ "rg"; "sort"; "head"; "wc"; "cat"; "git"; "ls"; "grep" ]

let allowlist : Gate.allowlist_policy =
  { allowed_commands = allowed; allow_pipes = true }
;;

(* {1 Baseline corpus} *)

type fixture = {
  raw_cmd : string;
  category : string;
  expected_legacy_verdict : string;
  expected_ir_verdict : string;
  ir_detail : string option;
  note : string;
}

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when String.trim root <> "" -> root
  | _ -> Sys.getcwd ()
;;

let fixture_path () =
  Filename.concat (source_root ()) "test/fixtures/shell_gate/baseline.jsonl"
;;

let assoc_string key json =
  match Yojson.Safe.Util.member key json with
  | `String s -> s
  | other ->
    Alcotest.failf
      "fixture key %s expected string, got %s"
      key
      (Yojson.Safe.to_string other)
;;

let assoc_string_opt key json =
  match Yojson.Safe.Util.member key json with
  | `Null -> None
  | `String s -> Some s
  | other ->
    Alcotest.failf
      "fixture key %s expected string|null, got %s"
      key
      (Yojson.Safe.to_string other)
;;

let parse_fixture_line line =
  let json = Yojson.Safe.from_string line in
  { raw_cmd = assoc_string "raw_cmd" json
  ; category = assoc_string "category" json
  ; expected_legacy_verdict = assoc_string "expected_legacy_verdict" json
  ; expected_ir_verdict = assoc_string "expected_ir_verdict" json
  ; ir_detail = assoc_string_opt "ir_detail" json
  ; note = assoc_string "note" json
  }
;;

let load_corpus () =
  let path = fixture_path () in
  let ic =
    try open_in path
    with Sys_error msg -> Alcotest.failf "open %s failed: %s" path msg
  in
  let rec loop acc =
    match input_line ic with
    | line ->
      let line = String.trim line in
      if line = "" then loop acc else loop (parse_fixture_line line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let fixtures = loop [] in
  close_in ic;
  fixtures
;;

(* Legacy verdict tagging — short string aligned with the JSONL
   schema. The {!W.block_reason} variant is private to the module,
   so we use {!W.block_reason_to_string} indirectly via tag mapping. *)
let legacy_tag (result : (unit, W.block_reason) result) : string =
  match result with
  | Ok () -> "ok"
  | Error W.Empty_command -> "empty_command"
  | Error W.Chain_or_redirect -> "chain_or_redirect"
  | Error W.Injection -> "injection"
  | Error W.Process_substitution -> "process_substitution"
  | Error W.Unsafe_redirect -> "unsafe_redirect"
  | Error W.Pipes_not_allowed -> "pipes_not_allowed"
  | Error W.Direct_dune_invocation -> "direct_dune_invocation"
  | Error (W.Command_not_allowed _) -> "command_not_allowed"
;;

let ir_detail_tag = function
  | Gate.Allow _ -> None
  | Gate.Reject { reason; _ } -> Some (Gate.reject_reason_tag reason)
  | Gate.Cannot_parse { reason } -> Some (Gate.parse_reason_tag reason)
  | Gate.Too_complex { reason } -> Some (Gate.too_complex_reason_tag reason)
;;

let run_corpus_row fixture =
  let label =
    Printf.sprintf
      "[%s] %S"
      fixture.category
      (if String.length fixture.raw_cmd > 60 then
         String.sub fixture.raw_cmd 0 60 ^ "..."
       else fixture.raw_cmd)
  in
  let legacy =
    W.validate_command_coding_with_allowlist ~allowed_commands:allowed fixture.raw_cmd
  in
  Alcotest.(check string)
    (label ^ " legacy verdict")
    fixture.expected_legacy_verdict
    (legacy_tag legacy);
  let ir =
    Gate.gate
      ~raw:fixture.raw_cmd
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  in
  Alcotest.(check string)
    (label ^ " ir verdict")
    fixture.expected_ir_verdict
    (Gate.verdict_tag ir);
  Alcotest.(check (option string))
    (label ^ " ir detail")
    fixture.ir_detail
    (ir_detail_tag ir);
  (* Note is kept for log readability — fail-safe assertion that the
     fixture has a rationale. Empty notes are corpus rot. *)
  if String.length (String.trim fixture.note) = 0 then
    Alcotest.failf "%s: corpus row missing note (rationale)" label
;;

let test_corpus_pinned () =
  let corpus = load_corpus () in
  if List.length corpus = 0 then
    Alcotest.fail "baseline.jsonl loaded zero rows — corpus path or content broken";
  List.iter run_corpus_row corpus
;;

let test_corpus_covers_required_buckets () =
  let corpus = load_corpus () in
  let categories =
    List.map (fun f -> f.category) corpus
    |> List.sort_uniq String.compare
  in
  (* Plan Phase 0 minimum set. Each must appear at least once in the
     corpus so future PRs cannot quietly drop a coverage axis. *)
  let required =
    [ "successful"
    ; "rejected"
    ; "too_complex"
    ; "quoted_pipe"
    ; "regex_alternation"
    ; "real_pipeline"
    ; "redirection"
    ; "glob"
    ; "path_traversal"
    ]
  in
  List.iter
    (fun bucket ->
      if not (List.mem bucket categories) then
        Alcotest.failf "Plan Phase 0 corpus bucket %S missing" bucket)
    required
;;

(* {1 Plan-specific Phase 1 invariants — exercised directly, not
       through the JSONL.} *)

let test_quoted_pipe_single_stage_shape () =
  (* Plan G2.1: quoted [|] must not become a stage delimiter. *)
  match
    Gate.gate
      ~raw:"rg 'foo|bar' lib"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Allow context ->
    Alcotest.(check int) "stage count" 1 (Gate.stage_count context);
    Alcotest.(check (list string))
      "stage bins"
      [ "rg" ]
      context.Gate.stage_bins;
    Alcotest.(check bool) "is_pipeline" false (Gate.is_pipeline context)
  | other ->
    Alcotest.failf
      "expected Allow for quoted pipe, got %s"
      (Gate.verdict_tag other)
;;

let test_real_three_stage_pipeline_ordering () =
  (* Plan G2.2 composition contract: typed and raw pipelines must
     produce the same non-nested ordered Simple stage list. *)
  match
    Gate.gate
      ~raw:"rg foo lib | sort | head -20"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Allow context ->
    Alcotest.(check int) "stage count" 3 (Gate.stage_count context);
    Alcotest.(check (list string))
      "stage bins ordered"
      [ "rg"; "sort"; "head" ]
      context.Gate.stage_bins;
    Alcotest.(check (option string))
      "last stage"
      (Some "head")
      (Gate.last_stage_bin context);
    Alcotest.(check bool) "is_pipeline" true (Gate.is_pipeline context);
    (* AST shape must be Pipeline of Simples — no nesting. *)
    (match context.Gate.ast with
     | Masc_exec.Shell_ir.Pipeline stages ->
       List.iter
         (function
           | Masc_exec.Shell_ir.Simple _ -> ()
           | Masc_exec.Shell_ir.Pipeline _ ->
             Alcotest.fail "stage was nested Pipeline — should be Simple")
         stages
     | Masc_exec.Shell_ir.Simple _ ->
       Alcotest.fail "expected Pipeline AST, got Simple")
  | other ->
    Alcotest.failf
      "expected Allow for 3-stage pipeline, got %s"
      (Gate.verdict_tag other)
;;

let test_pipeline_segment_rejection_carries_stage_index () =
  match
    Gate.gate
      ~raw:"rg foo | sed s/a/b/ | head -20"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Reject { reason = Gate.Pipeline_segment_disallowed { stage = 2; bin = "sed" }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected stage 2 sed rejection, got %s"
      (Gate.verdict_tag other)
;;

let test_pipes_disabled () =
  let policy : Gate.allowlist_policy =
    { allowed_commands = allowed; allow_pipes = false }
  in
  match
    Gate.gate
      ~raw:"rg foo | head -20"
      ~allowlist:policy
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Reject { reason = Gate.Pipes_not_allowed { stages = 2 }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Pipes_not_allowed, got %s"
      (Gate.verdict_tag other)
;;

let test_lower_typed_single_stage () =
  (* Plan: typed input must share the verdict surface with raw input.
     A one-stage typed pipeline lowers to [Allow] with [Simple] AST. *)
  let stage : Masc_exec.Shell_ir.simple =
    { bin =
        (match Masc_exec.Bin.of_string "rg" with
         | Ok b -> b
         | Error _ -> Alcotest.fail "Bin.of_string rg failed")
    ; args = [ Masc_exec.Shell_ir.Lit "foo"; Masc_exec.Shell_ir.Lit "lib" ]
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Masc_exec.Sandbox_target.host ()
    }
  in
  match
    Gate.lower_typed_pipeline ~stages:[ stage ] ~sandbox:Gate.host_sandbox
  with
  | Gate.Allow context ->
    Alcotest.(check int) "stage count" 1 (Gate.stage_count context);
    (match context.Gate.ast with
     | Masc_exec.Shell_ir.Simple _ -> ()
     | Masc_exec.Shell_ir.Pipeline _ ->
       Alcotest.fail "single stage typed input must lower to Simple AST")
  | other ->
    Alcotest.failf
      "expected Allow, got %s"
      (Gate.verdict_tag other)
;;

let make_stage bin args =
  { Masc_exec.Shell_ir.bin =
      (match Masc_exec.Bin.of_string bin with
       | Ok b -> b
       | Error _ -> Alcotest.failf "Bin.of_string %s failed" bin)
  ; args = List.map (fun a -> Masc_exec.Shell_ir.Lit a) args
  ; env = []
  ; cwd = None
  ; redirects = []
  ; sandbox = Masc_exec.Sandbox_target.host ()
  }
;;

let test_lower_typed_three_stage_matches_raw () =
  (* Plan G2.2 composition contract: typed [a;b;c] and raw "a | b | c"
     must produce the same [Pipeline [Simple a; Simple b; Simple c]]
     shape and the same stage_bins ordering. *)
  let typed =
    Gate.lower_typed_pipeline
      ~stages:[ make_stage "rg" [ "foo"; "lib" ]
              ; make_stage "sort" []
              ; make_stage "head" [ "-20" ]
              ]
      ~sandbox:Gate.host_sandbox
  in
  let raw =
    Gate.gate
      ~raw:"rg foo lib | sort | head -20"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  in
  match typed, raw with
  | Gate.Allow tc, Gate.Allow rc ->
    Alcotest.(check (list string))
      "typed and raw share stage_bins"
      rc.Gate.stage_bins
      tc.Gate.stage_bins;
    Alcotest.(check int)
      "typed and raw share stage_count"
      (Gate.stage_count rc)
      (Gate.stage_count tc)
  | _ ->
    Alcotest.failf
      "typed=%s raw=%s — expected both Allow"
      (Gate.verdict_tag typed)
      (Gate.verdict_tag raw)
;;

let test_lower_typed_empty_is_cannot_parse () =
  match
    Gate.lower_typed_pipeline ~stages:[] ~sandbox:Gate.host_sandbox
  with
  | Gate.Cannot_parse { reason = Gate.Parse_error } -> ()
  | other ->
    Alcotest.failf
      "empty typed pipeline must yield Cannot_parse parse_error, got %s"
      (Gate.verdict_tag other)
;;

let test_path_policy_rejects () =
  (* Path policy classifier is invoked on every literal arg. *)
  let classify ~raw_path =
    if raw_path = "/etc/shadow" then `Deny "shadow not allowed"
    else `Allow
  in
  let policy = { Gate.classify = Some classify } in
  match
    Gate.gate
      ~raw:"cat /etc/shadow"
      ~allowlist
      ~path_policy:policy
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Reject { reason = Gate.Path_outside_policy { stage = 1; raw_path = "/etc/shadow"; _ }; _ } -> ()
  | other ->
    Alcotest.failf
      "expected Path_outside_policy reject, got %s"
      (Gate.verdict_tag other)
;;

let test_sandbox_target_propagates_to_every_stage () =
  (* Plan: sandbox context is echoed through the IR so downstream
     dispatch does not re-parse. Verify every stage carries the
     supplied sandbox target. *)
  let sandbox = Gate.host_sandbox in
  match
    Gate.gate
      ~raw:"rg foo lib | sort | head -20"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox
  with
  | Gate.Allow context ->
    List.iter
      (fun (s : Masc_exec.Shell_ir.simple) ->
        match s.sandbox with
        | Masc_exec.Sandbox_target.Host -> ()
        | Masc_exec.Sandbox_target.Docker _ ->
          Alcotest.fail "expected Host sandbox on every stage")
      context.Gate.stages
  | other ->
    Alcotest.failf
      "expected Allow, got %s"
      (Gate.verdict_tag other)
;;

let test_too_complex_reason_tags_are_stable () =
  (* Telemetry tags must not change shape without an intentional
     migration — downstream JSONL consumers depend on these. *)
  Alcotest.(check string)
    "unsupported_nested_pipeline tag"
    "unsupported_nested_pipeline"
    (Gate.too_complex_reason_tag Gate.Unsupported_nested_pipeline);
  Alcotest.(check string)
    "heredoc tag"
    "heredoc"
    (Gate.too_complex_reason_tag (Gate.Unsupported_construct `Heredoc));
  Alcotest.(check string)
    "cmd_subst tag"
    "cmd_subst"
    (Gate.too_complex_reason_tag (Gate.Unsupported_construct `Cmd_subst))
;;

(* {1 Phase 0 PR-A2 corpus extension — three new fixtures}

   The fixtures are also pinned by [test_corpus_pinned] above. These
   dedicated tests exist so a regression on any of the three new
   divergence/policy axes produces a focused failure label instead of
   a generic "row N legacy/ir verdict mismatch". *)

let test_backslash_pipe_in_double_quotes_diverges () =
  (* Corpus fixture: rg "a\|b"
     Legacy: ok (forbidden_shell_chars_coding excludes \ and the
       quote-aware splitter does not see the inner |).
     IR: Cannot_parse Parse_error (lexer rejects \ in dq_body and
       classify_too_complex matches no single-char rule for this
       input).
     Phase 0 PR-A2: new divergence row. *)
  match
    Gate.gate
      ~raw:"rg \"a\\|b\""
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Cannot_parse { reason = Gate.Parse_error } -> ()
  | other ->
    Alcotest.failf
      "expected Cannot_parse parse_error for backslash-pipe in dq, got %s"
      (Gate.verdict_tag other)
;;

let test_brace_expansion_is_too_complex_glob_brace () =
  (* Corpus fixture: ls {a,b}.txt
     Legacy: ok (brace not in forbidden_shell_chars_coding).
     IR: Too_complex (Unsupported_construct `Glob_brace).
     Phase 0 PR-A2: new fixture covering classify_too_complex's
     [has "{" || has "}"] arm — previously no corpus row exercised
     it. *)
  match
    Gate.gate
      ~raw:"ls {a,b}.txt"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Too_complex { reason = Gate.Unsupported_construct `Glob_brace } -> ()
  | other ->
    Alcotest.failf
      "expected Too_complex glob_brace for brace expansion, got %s"
      (Gate.verdict_tag other)
;;

let test_absolute_path_traversal_phase1_allows () =
  (* Corpus fixture: cat /etc/passwd
     Legacy: ok (no metachar trigger).
     IR (Phase 1, allow_all_paths default): Allow with single Simple
       stage [cat /etc/passwd]. Phase 5 will install a path policy
       that flips this row to Reject Path_outside_policy — this
       fixture exists so the flip is a visible, intentional corpus
       diff and not a silent behavior change.
     Phase 0 PR-A2: first absolute-path-outside-repo fixture. *)
  match
    Gate.gate
      ~raw:"cat /etc/passwd"
      ~allowlist
      ~path_policy:Gate.allow_all_paths
      ~sandbox:Gate.host_sandbox
  with
  | Gate.Allow context ->
    Alcotest.(check int) "stage count" 1 (Gate.stage_count context);
    Alcotest.(check (list string))
      "stage bins"
      [ "cat" ]
      context.Gate.stage_bins;
    Alcotest.(check bool) "is_pipeline" false (Gate.is_pipeline context)
  | other ->
    Alcotest.failf
      "expected Allow for absolute path under Phase 1 default policy, got %s"
      (Gate.verdict_tag other)
;;

let () =
  Alcotest.run
    "exec_shell_command_gate"
    [ ( "phase_0_corpus"
      , [ Alcotest.test_case "baseline.jsonl pinned" `Quick test_corpus_pinned
        ; Alcotest.test_case
            "all required buckets present"
            `Quick
            test_corpus_covers_required_buckets
        ] )
    ; ( "phase_1_shape"
      , [ Alcotest.test_case
            "quoted pipe stays single-stage"
            `Quick
            test_quoted_pipe_single_stage_shape
        ; Alcotest.test_case
            "3-stage pipeline preserves ordering and AST shape"
            `Quick
            test_real_three_stage_pipeline_ordering
        ; Alcotest.test_case
            "pipeline rejection carries 1-indexed stage"
            `Quick
            test_pipeline_segment_rejection_carries_stage_index
        ; Alcotest.test_case
            "allow_pipes=false yields Pipes_not_allowed"
            `Quick
            test_pipes_disabled
        ] )
    ; ( "phase_1_typed_lower"
      , [ Alcotest.test_case
            "single-stage typed input lowers to Simple"
            `Quick
            test_lower_typed_single_stage
        ; Alcotest.test_case
            "3-stage typed input matches raw stage_bins"
            `Quick
            test_lower_typed_three_stage_matches_raw
        ; Alcotest.test_case
            "empty typed input is Cannot_parse"
            `Quick
            test_lower_typed_empty_is_cannot_parse
        ] )
    ; ( "phase_1_policy"
      , [ Alcotest.test_case
            "path policy reject carries stage + raw path"
            `Quick
            test_path_policy_rejects
        ; Alcotest.test_case
            "sandbox target propagates to every stage"
            `Quick
            test_sandbox_target_propagates_to_every_stage
        ] )
    ; ( "phase_1_telemetry"
      , [ Alcotest.test_case
            "too_complex reason tags stable"
            `Quick
            test_too_complex_reason_tags_are_stable
        ] )
    ; ( "phase_0_pr_a2"
      , [ Alcotest.test_case
            "backslash pipe in double quotes diverges"
            `Quick
            test_backslash_pipe_in_double_quotes_diverges
        ; Alcotest.test_case
            "brace expansion classified as glob_brace"
            `Quick
            test_brace_expansion_is_too_complex_glob_brace
        ; Alcotest.test_case
            "absolute path traversal allows under Phase 1 default"
            `Quick
            test_absolute_path_traversal_phase1_allows
        ] )
    ]
;;
