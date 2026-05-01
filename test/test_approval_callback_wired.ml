(** #7883 — Structural + behavioural tests that every OAS Agent
    builder / run_named site in MASC installs an approval_callback.

    Background: OAS emits [WARN] "ApprovalRequired but no approval
    callback — executing" when an agent has [approval = None] and a
    tool marked ApprovalRequired is called. The tool executes anyway
    (fail-open). #7883 observed two fleet events where the WARN fired
    and the tool ran. Log promotion to ERROR via [oas_log_bridge] is
    observability, not a gate.

    This test locks the wiring in:

    1. Behavioural: [Approval_callbacks.reject_by_default] returns
       [Reject _] for any tool, so any Builder that accidentally
       defaults to it will fail loudly instead of executing.
    2. Behavioural: [Approval_callbacks.auto_approve] returns
       [Approve] (unchanged contract, for trusted system runs).
    3. Structural: every MASC source file that constructs an
       [Agent_sdk.Agent.t] via [Agent_sdk.Builder.build_safe] wires an approval
       callback (with_approval, or threads ~approval to a helper that
       does). Missing wiring → fail-open, the exact bug #7883.
    4. Structural: every MASC call site of
       [Oas_worker.run_named] / [Oas_worker_named.run_named*] passes
       [~approval:...].

    Detection is grep-based on source. False positives are acceptable
    (over-constrains wiring); false negatives regress the security
    gate and are not acceptable. *)

module AC = Masc_mcp.Approval_callbacks

let check_reject name (result : Agent_sdk.Hooks.approval_decision) =
  match result with
  | Reject reason ->
      Alcotest.(check bool)
        (Printf.sprintf "%s rejects with non-empty reason" name)
        true (String.length reason > 0)
  | Approve ->
      Alcotest.fail
        (Printf.sprintf "%s: expected Reject, got Approve (fail-open bug \
                         #7883 regressed)" name)
  | Edit _ ->
      Alcotest.fail
        (Printf.sprintf "%s: expected Reject, got Edit" name)

let check_approve name (result : Agent_sdk.Hooks.approval_decision) =
  match result with
  | Approve -> ()
  | Reject reason ->
      Alcotest.fail
        (Printf.sprintf "%s: expected Approve, got Reject %S" name reason)
  | Edit _ ->
      Alcotest.fail
        (Printf.sprintf "%s: expected Approve, got Edit" name)

(* ── 1. reject_by_default fails closed on every input ───────────── *)

let test_reject_by_default_rejects_any_tool () =
  let tools =
    [ "masc_worktree_create"; "masc_code_write"; "keeper_destroy";
      "bash_exec"; "unknown_tool"; "" ]
  in
  List.iter
    (fun tool_name ->
      let decision =
        AC.reject_by_default ~tool_name ~input:(`Assoc [])
      in
      check_reject ("reject_by_default " ^ tool_name) decision)
    tools

let test_reject_by_default_reason_mentions_tool () =
  let decision : Agent_sdk.Hooks.approval_decision =
    AC.reject_by_default ~tool_name:"masc_worktree_create"
      ~input:(`Assoc [])
  in
  match decision with
  | Reject reason ->
      Alcotest.(check bool)
        "reject reason names the tool so agents can diagnose"
        true
        (try ignore (Str.search_forward
                       (Str.regexp_string "masc_worktree_create") reason 0);
             true
         with Not_found -> false)
  | Approve ->
      Alcotest.fail "reject_by_default regressed to Approve"
  | Edit _ ->
      Alcotest.fail "reject_by_default regressed to Edit"

(* ── 2. auto_approve contract unchanged for trusted system runs ─── *)

let test_auto_approve_approves () =
  let decision =
    AC.auto_approve ~tool_name:"anything" ~input:(`Assoc [])
  in
  check_approve "auto_approve" decision

(* ── 3. Structural: every Builder.build_safe call site installs
       an approval callback via with_approval or threads ~approval. ─ *)

(** Find the MASC repo root from the test cwd. dune runs tests from
    the repo root; fall back to climbing until we see [lib/]. *)
let repo_root () =
  let rec climb dir depth =
    if depth > 6 then dir
    else if Sys.file_exists (Filename.concat dir "lib") &&
            Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else climb (Filename.dirname dir) (depth + 1)
  in
  climb (Sys.getcwd ()) 0

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let file_contains path needle =
  try
    let s = read_file path in
    ignore (Str.search_forward (Str.regexp_string needle) s 0);
    true
  with Sys_error _ | Not_found -> false

let file_matches path pattern =
  try
    let s = read_file path in
    ignore (Str.search_forward (Str.regexp pattern) s 0);
    true
  with Sys_error _ | Not_found -> false

(** Each MASC source file that calls [Agent_sdk.Builder.build_safe] must
    also install an approval callback. We express this as: the file
    contains "with_approval" OR threads the caller-supplied
    [?approval] into a helper that does (e.g. oas_worker_exec wires
    the optional approval field into the Builder). *)
let builder_sites = [
  (* Worker OAS Builder — issue #8232 path. *)
  ( "lib/worker_oas.ml",
    "Agent_sdk.Builder.build_safe",
    "Agent_sdk.Builder.with_approval" );
  (* Oas_worker_exec Builder — run_named pipeline. This file wires
     config.approval into the builder directly. *)
  ( "lib/oas_worker_exec.ml",
    "Agent_sdk.Builder.build_safe",
    "Agent_sdk.Builder.with_approval" );
]

let test_builder_sites_wire_approval () =
  let root = repo_root () in
  List.iter
    (fun (rel_path, marker, approval_marker) ->
      let path = Filename.concat root rel_path in
      Alcotest.(check bool)
        (Printf.sprintf "%s: exists" rel_path)
        true (Sys.file_exists path);
      Alcotest.(check bool)
        (Printf.sprintf "%s: contains %S" rel_path marker)
        true (file_contains path marker);
      Alcotest.(check bool)
        (Printf.sprintf
           "%s: Builder site must install approval via %S \
            (fail-open guard, #7883)"
           rel_path approval_marker)
        true (file_contains path approval_marker))
    builder_sites

(** Every MASC call site of [Oas_worker.run_named] or
    [Oas_worker_named.run_named*] must pass [~approval:...]. The
    regex matches any argument value so callers may install
    auto_approve, reject_by_default, or a governance callback. *)
let run_named_sites = [
  "lib/autoresearch_codegen.ml";
  "lib/auto_responder.ml";
  "lib/tool_deep_review.ml";
  "lib/anti_rationalization.ml";
  "lib/server/server_openai_compat.ml";
  "lib/dashboard/dashboard_operator_judge.ml";
  "lib/dashboard/dashboard_governance_judge.ml";
  "lib/keeper/keeper_agent_run.ml";
  "lib/verifier_oas.ml";
]

let test_run_named_sites_pass_approval () =
  let root = repo_root () in
  List.iter
    (fun rel_path ->
      let path = Filename.concat root rel_path in
      Alcotest.(check bool)
        (Printf.sprintf "%s: exists" rel_path)
        true (Sys.file_exists path);
      Alcotest.(check bool)
        (Printf.sprintf
           "%s: run_named call site must pass ~approval:... \
            (fail-open guard, #7883)"
           rel_path)
        true (file_matches path "~approval:"))
    run_named_sites

(* ── Suite ──────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "approval_callback_wired"
    [
      ( "reject_by_default",
        [ Alcotest.test_case "rejects every tool" `Quick
            test_reject_by_default_rejects_any_tool;
          Alcotest.test_case "reason names the tool" `Quick
            test_reject_by_default_reason_mentions_tool;
        ] );
      ( "auto_approve",
        [ Alcotest.test_case "approves" `Quick
            test_auto_approve_approves;
        ] );
      ( "structural",
        [ Alcotest.test_case "Builder.build_safe sites install with_approval"
            `Quick test_builder_sites_wire_approval;
          Alcotest.test_case "run_named call sites pass ~approval"
            `Quick test_run_named_sites_pass_approval;
        ] );
    ]
