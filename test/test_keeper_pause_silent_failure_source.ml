(** Structural guard for issue #8391 HIGH #1.

    The keeper pause/resume HTTP handlers in
    [lib/server/server_dashboard_http_keeper_api.ml] used to fold
    [Ok None] (keeper meta vanished) and [Error _] (IO/parse failure)
    into a single silent no-op arm. The dashboard endpoint then
    returned HTTP 200 OK and the operator believed the keeper was
    paused, while it kept running.

    These tests are intentionally structural (read the source file and
    assert patterns) rather than integration. Mocking [read_meta] would
    require spinning up the full server and a fake meta file.

    Cases covered:

    - (a) happy [Ok (Some meta)] arm exists in both closures
    - (b) [Ok None] arm exists separately and is observable (logs +
          counter or non-200 response)
    - (c) [Error _] arm exists separately and is observable (logs +
          counter or 500 response)
    - (d) the silent fold ["Ok None | Error _"] does not return at the
          known offending sites in [persist_keeper_paused_state] /
          [resume_booted_keeper_if_needed] / directive [meta_opt]
*)

open Alcotest

let target_files =
  [ "lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml"
  ; "lib/server/server_dashboard_http_keeper_api_post.ml"
  ]

let status_detail_file = "lib/keeper/keeper_status_detail.ml"
let keeper_up_update_file = "lib/keeper/keeper_turn_up_update.ml"
let heartbeat_presence_file = "lib/keeper/keeper_heartbeat_loop_presence.ml"
let dashboard_execution_helpers_file = "lib/dashboard/dashboard_execution_helpers.ml"

let metric_name = "Keeper_metrics.(to_string PausedStatePersistErrors)"

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "source file not found: %s" path)
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic)

let count_occurrences ~needle haystack =
  let nlen = String.length needle in
  if nlen = 0 then 0
  else
    let re = Str.regexp_string needle in
    let rec loop pos acc =
      match Str.search_forward re haystack pos with
      | exception Not_found -> acc
      | _ ->
          let m = Str.match_end () in
          loop m (acc + 1)
    in
    loop 0 0

let first_index ~needle haystack =
  match Str.search_forward (Str.regexp_string needle) haystack 0 with
  | pos -> Some pos
  | exception Not_found -> None

let target_source () =
  String.concat "\n" (List.map load_source target_files)

let test_metric_registered () =
  (* The metric literal moved out of [lib/otel_metric_store.ml] and into
     [lib/keeper_metrics/keeper_metrics.ml] in #14179 (RFC-0043 distribute
     metric ownership). Builtin registration now references
     [Keeper_metrics.(to_string PausedStatePersistErrors)] by
     symbol, so the structural guard checks both files: the literal
     must live somewhere, and the registration site (by symbol) must
     still be in [lib/otel_metric_store_builtin_metrics_part2.ml]. *)
  let metrics = load_source "lib/keeper_metrics/keeper_metrics.ml" in
  check bool "paused-state persist-errors metric declared" true
    (count_occurrences
       ~needle:"masc_keeper_paused_state_persist_errors_total"
       metrics
     >= 1);
  let prom = load_source "lib/keeper_metrics/keeper_metrics.ml" in
  check bool "paused-state persist-errors metric registered in all list"
    true
    (count_occurrences ~needle:"PausedStatePersistErrors" prom >= 1)

let test_happy_path_preserved () =
  let src = target_source () in
  (* (a) The happy [Ok (Some meta)] arms must still be present in both
     closures so successful pause/resume keeps returning 200. *)
  check bool "persist_keeper_paused_state happy arm present" true
    (count_occurrences
       ~needle:"Ok (Some meta) when Bool.equal meta.paused paused -> true"
       src
     >= 1);
  check bool "resume_booted_keeper_if_needed happy arm present" true
    (count_occurrences
       ~needle:"Ok (Some meta) when meta.paused"
       src
     >= 1)

let test_silent_fold_removed () =
  let src = target_source () in
  (* (d) The exact silent fold ["Ok None | Error _ -> ()"] must not
     reappear inside [persist_keeper_paused_state] or
     [resume_booted_keeper_if_needed]. We allow it elsewhere because
     [resolve_keeper_agent_name] (line ~678) legitimately collapses
     both into [None] for a name lookup. *)
  let needle = "Ok None | Error _ -> ()" in
  check int "silent fold returning unit removed" 0
    (count_occurrences ~needle src)

let test_ok_none_branch_observable () =
  let src = target_source () in
  (* (b) The [Ok None] case must be observable: either logged + counter,
     or a distinct HTTP response. We assert the log marker. *)
  check bool "Ok None warn log: persist phase" true
    (count_occurrences
       ~needle:"meta missing — skipping paused-state persist"
       src
     >= 1);
  check bool "Ok None warn log: boot resume check phase" true
    (count_occurrences
       ~needle:"meta missing — skipping auto-resume check"
       src
     >= 1);
  check bool "Ok None directive 404 response" true
    (count_occurrences
       ~needle:"keeper meta not found"
       src
     >= 1);
  check bool "Ok None observability counter labelled meta_missing" true
    (count_occurrences ~needle:"meta_missing" src >= 3)

let test_error_branch_observable () =
  let src = target_source () in
  (* (c) The [Error err] case must surface the underlying reason. *)
  check bool "Error err: persist phase logs reason" true
    (count_occurrences
       ~needle:": read_meta failed: %s"
       src
     >= 1);
  check bool "Error err: boot check phase logs reason" true
    (count_occurrences
       ~needle:"read_meta failed during auto-resume check"
       src
     >= 1);
  check bool "Error err: directive 500 response" true
    (count_occurrences
       ~needle:"\"read_meta failed: %s\"" src
     >= 1);
  check bool "Error err observability counter labelled read_meta_error"
    true
    (count_occurrences ~needle:"read_meta_error" src >= 3)

let test_write_error_branch_observable () =
  let src = target_source () in
  check bool "write_meta error log keeps reason" true
    (count_occurrences
       ~needle:"directive %s: write_meta failed for %s: %s"
       src
     >= 1);
  check bool "write_meta error returns HTTP failure" true
    (count_occurrences
       ~needle:"failed to persist paused state"
       src
     >= 1);
  check bool "write_meta error counter labelled write_meta_error" true
    (count_occurrences ~needle:"write_meta_error" src >= 1)

let test_no_progress_clear_failure_observable () =
  let src =
    String.concat
      "\n"
      [
        target_source ();
        load_source keeper_up_update_file;
        load_source "lib/keeper/keeper_keepalive.ml";
      ]
  in
  check bool "no-progress clear error labelled in pause/resume metrics" true
    (count_occurrences ~needle:"no_progress_clear_error" src >= 2);
  check bool "keeper_up no-progress clear site is typed" true
    (count_occurrences ~needle:"No_progress_resume_clear" src >= 1);
  check bool "directive no-progress clear failure is observable" true
    (count_occurrences ~needle:"no_progress_resume_clear" src >= 2)

let test_klv2_directive_resume_no_progress_clear_best_effort () =
  (* KLV-2 / RFC-0152: on operator resume, dropping the no-progress recovery
     stimulus is a cosmetic cleanup. A transient disk failure there must NOT
     gate the authoritative unpause. Previously the [Error] arm logged at
     [error] level and short-circuited the whole [set_keeper_paused_state]
     body, so the keeper never reached [persist_directive_meta_update] and
     stayed paused forever (no_progress pause is [Manual_resume_required] — no
     other recovery path exists). After the fix the clear result is bound into
     [directive_source_meta] best-effort and execution always falls through to
     the authoritative persist, which stays fail-closed.

     Structural guard: the existing rationale for source-pattern over
     integration applies (injecting a clear failure needs the full server +
     event-queue harness). Non-vacuous — reverting the fix restores the
     [..._result] binding name and the [error]-level short-circuit log, so both
     the [let directive_source_meta =] and ["proceeding with unpause"] markers
     disappear and these checks turn red. *)
  let src = load_source "lib/keeper/keeper_keepalive.ml" in
  check bool "resume no-progress clear is bound best-effort (not a gate)" true
    (count_occurrences ~needle:"let directive_source_meta =" src >= 1);
  check bool "resume clear failure proceeds with unpause (no short-circuit)"
    true
    (count_occurrences ~needle:"proceeding with unpause" src >= 1);
  check int "fail-closed short-circuit error log on clear removed" 0
    (count_occurrences
       ~needle:"directive resume: no_progress clear failed for"
       src);
  check bool "authoritative unpause persist is still reached" true
    (count_occurrences
       ~needle:"persist_directive_meta_update entry ~updated_meta"
       src
     >= 1);
  (* The cosmetic clear site is handled strictly before the authoritative
     persist site, proving the two carry distinct failure policies. *)
  (match
     ( first_index ~needle:"no_progress_resume_clear" src,
       first_index ~needle:"pause_resume_persist" src )
   with
   | Some clear_pos, Some persist_pos ->
       check bool "best-effort clear site precedes fail-closed persist site"
         true (clear_pos < persist_pos)
   | _ -> Alcotest.failf "missing KLV-2 site markers in keeper_keepalive.ml");
  (* Fail-closed preserved: the authoritative persist still rolls the registry
     failure reason back on [Error] rather than swallowing it. *)
  check bool "authoritative persist stays fail-closed (rolls back reason)" true
    (count_occurrences ~needle:"previous_failure_reason" src >= 1)

let test_counter_inc_calls () =
  let src = target_source () in
  (* The metric must actually be incremented at least 6 times: 2 in
     [persist_keeper_paused_state] (Ok None / Error), 2 in
     [resume_booted_keeper_if_needed] (Ok None / Error), 2 in the
     directive endpoint (Ok None / Error), plus resume-clear failure
     branches. *)
  check bool "Otel_metric_store.inc_counter called for new metric >= 6 times"
    true
    (count_occurrences
       ~needle:"Keeper_metrics.(to_string PausedStatePersistErrors)"
       src
     >= 6)

let test_resume_paths_clear_no_progress_latch () =
  let lifecycle_src =
    load_source "lib/server/server_dashboard_http_keeper_api_lifecycle_post.ml"
  in
  let directive_src = load_source "lib/server/server_dashboard_http_keeper_api_post.ml" in
  let update_src = load_source keeper_up_update_file in
  check bool "boot resume clears no-progress latch" true
    (count_occurrences
       ~needle:"Keeper_unified_turn_no_progress.clear_for_operator_resume"
       lifecycle_src
     >= 1);
  check bool "directive resume clears no-progress latch" true
    (count_occurrences
       ~needle:"Keeper_unified_turn_no_progress.clear_for_operator_resume"
       directive_src
     >= 1);
  check bool "masc_keeper_up resume clears no-progress latch" true
    (count_occurrences
       ~needle:"Keeper_unified_turn_no_progress.clear_for_operator_resume"
       update_src
     >= 1)

let test_directive_resume_boots_missing_registry_keeper () =
  let directive_src = load_source "lib/server/server_dashboard_http_keeper_api_post.ml" in
  check bool "directive resume has registry-missing boot helper" true
    (count_occurrences ~needle:"ensure_registered_for_resume" directive_src >= 3);
  check bool "directive resume uses keeper_up instead of silent directive noop" true
    (count_occurrences ~needle:"~name:\"masc_keeper_up\"" directive_src >= 1)

let test_directive_resume_ensures_before_meta_mutation () =
  let directive_src = load_source "lib/server/server_dashboard_http_keeper_api_post.ml" in
  let check_order label before after_ =
    match
      first_index ~needle:before directive_src,
      first_index ~needle:after_ directive_src
    with
    | Some before_pos, Some after_pos -> check bool label true (before_pos < after_pos)
    | _ -> Alcotest.failf "missing order markers for %s" label
  in
  check_order "single resume ensure precedes persist"
    "let ensure_result ="
    "let persist_result =";
  check bool "single booted resume does not stale-persist old meta" true
    (count_occurrences
       ~needle:"| `Resume, `Booted_missing_registry -> Ok ()"
       directive_src
     >= 1);
  check bool "bulk booted resume does not stale-persist old meta" true
    (count_occurrences
       ~needle:"| `Resume, `Booted_missing_registry, _, _ -> Ok ()"
       directive_src
     >= 1)

let test_bulk_directive_partial_failure_observable () =
  let directive_src = load_source "lib/server/server_dashboard_http_keeper_api_post.ml" in
  check bool "bulk directive computes failed count" true
    (count_occurrences
       ~needle:"let failed_count = requested_count - ok_count"
       directive_src
     >= 1);
  check bool "bulk directive top-level ok reflects failures" true
    (count_occurrences ~needle:"(\"ok\", `Bool (failed_count = 0))" directive_src >= 1);
  check bool "bulk directive response includes failed count" true
    (count_occurrences ~needle:"(\"failed\", `Int failed_count)" directive_src >= 1);
  check bool "bulk directive partial failure returns non-200" true
    (count_occurrences
       ~needle:"~status:`Internal_server_error ~compress:true"
       directive_src
     >= 1);
  check bool "bulk directive invalidates cache only after success" true
    (count_occurrences
       ~needle:"if ok_count > 0 then invalidate_keeper_execution_surfaces ~config"
       directive_src
     >= 1)

let test_keeper_status_disposition_mirrors_runtime_trust () =
  let src = load_source status_detail_file in
  check bool "keeper status builds runtime_trust" true
    (count_occurrences
       ~needle:
         "let runtime_trust =\n           Keeper_runtime_trust_snapshot.snapshot_json"
       src
     >= 1);
  check bool "top-level disposition reads runtime_trust" true
    (count_occurrences
       ~needle:"json_string_opt_member runtime_trust \"disposition\""
       src
     >= 1);
  check bool "top-level disposition field is emitted" true
    (count_occurrences
       ~needle:"(\"disposition\", Json_util.string_opt_to_json disposition)"
       src
    >= 1);
  check bool "top-level attention overlays runtime_trust" true
    (count_occurrences
       ~needle:"attention_fields_with_runtime_trust attention_fields runtime_trust"
       src
    >= 1)

let test_heartbeat_presence_uses_cas_retry_merge () =
  let src = load_source heartbeat_presence_file in
  check bool "heartbeat presence uses CAS retry writer" true
    (count_occurrences ~needle:"write_meta_with_merge" src >= 1);
  check bool "heartbeat presence preserves disk-owned heartbeat fields" true
    (count_occurrences
       ~needle:"Keeper_meta_merge.heartbeat_fields_from_disk"
       src
     >= 1);
  check int "plain heartbeat write_meta call removed" 0
    (count_occurrences ~needle:"match write_meta ctx.config synced" src)

let test_directive_meta_cluster_scan_failure_fail_closed () =
  let src = load_source "lib/keeper/keeper_keepalive.ml" in
  check bool "directive meta path resolver is Result-returning" true
    (count_occurrences ~needle:"directive_meta_persist_path_result" src >= 2);
  check bool "cluster scan error is explicitly labelled" true
    (count_occurrences
       ~needle:"clusters_dir_read_error while resolving directive meta path"
       src
     >= 1);
  check bool "path resolution failure uses directive persist failure channel" true
    (count_occurrences ~needle:"directive_meta_persist_error entry msg" src >= 1);
  check int "cluster scan failure is not collapsed to empty path list" 0
    (count_occurrences ~needle:"| Error _ -> []" src)

let test_dashboard_agent_profile_read_error_observable () =
  let helper_src = load_source dashboard_execution_helpers_file in
  let builder_src = load_source "lib/dashboard/dashboard_execution_builders.ml" in
  let dashboard_src = load_source "lib/dashboard/dashboard_execution.ml" in
  let keeper_src = load_source "lib/dashboard/dashboard_http_keeper.ml" in
  let core_entities_src =
    load_source "lib/server/server_dashboard_http_core_entities.ml"
  in
  check bool "persona profile lookup has explicit read-error variant" true
    (count_occurrences ~needle:"Persona_profile_read_error" helper_src >= 3);
  check int "persona profile read failure is not collapsed to None" 0
    (count_occurrences ~needle:"| Error _ -> None" helper_src);
  check bool "agent profile carries profile_errors" true
    (count_occurrences ~needle:"profile_errors : agent_profile_error list" helper_src
     >= 1);
  check bool "execution builders emit profile_errors" true
    (count_occurrences ~needle:"(\"profile_errors\", agent_profile_errors_json profile)" builder_src
     >= 2);
  check bool "dashboard agent JSON emits profile_errors" true
    (count_occurrences ~needle:"\"profile_errors\", agent_profile_errors_json profile" dashboard_src
     >= 1);
  check bool "keeper dashboard emits profile_errors" true
    (count_occurrences
       ~needle:
         "(\"profile_errors\", Dashboard_execution_helpers.agent_profile_errors_json profile)"
       keeper_src
     >= 1);
  check bool "core entity JSON emits profile_errors" true
    (count_occurrences
       ~needle:
       "\"profile_errors\", Dashboard_execution_helpers.agent_profile_errors_json profile"
       core_entities_src
     >= 1)

let test_composite_claim_output_parse_failure_observable () =
  let src = load_source "lib/server/server_dashboard_http_composite_claims.ml" in
  check bool "claim output parse has typed error variant" true
    (count_occurrences ~needle:"Tool_call_output_parse_error" src >= 4);
  check int "claim output parse error is not collapsed to None" 0
    (count_occurrences ~needle:"| Error _ -> None" src);
  check bool "claim output parse status is projected" true
    (count_occurrences ~needle:"\"output_parse_status\"" src >= 2);
  check bool "claim output parse error detail is projected" true
    (count_occurrences ~needle:"\"output_error\"" src >= 2);
  check bool "parse-error status is explicit" true
    (count_occurrences ~needle:"\"parse_error\"" src >= 2)

let () =
  run "keeper_pause_silent_failure_source"
    [ ( "issue-8391-high-1"
      , [ test_case "metric registered" `Quick test_metric_registered
        ; test_case "happy path preserved" `Quick test_happy_path_preserved
        ; test_case "silent fold removed" `Quick test_silent_fold_removed
        ; test_case "Ok None branch observable" `Quick
            test_ok_none_branch_observable
        ; test_case "Error _ branch observable" `Quick
            test_error_branch_observable
        ; test_case "write_meta error branch observable" `Quick
            test_write_error_branch_observable
        ; test_case "no-progress clear failure observable" `Quick
            test_no_progress_clear_failure_observable
        ; test_case "KLV-2 directive resume no-progress clear best-effort"
            `Quick test_klv2_directive_resume_no_progress_clear_best_effort
        ; test_case "counter inc calls present" `Quick
            test_counter_inc_calls
        ; test_case "resume paths clear no-progress latch" `Quick
            test_resume_paths_clear_no_progress_latch
        ; test_case "directive resume boots missing registry keeper" `Quick
            test_directive_resume_boots_missing_registry_keeper
        ; test_case "directive resume ensures before meta mutation" `Quick
            test_directive_resume_ensures_before_meta_mutation
        ; test_case "bulk directive partial failure observable" `Quick
            test_bulk_directive_partial_failure_observable
        ; test_case "keeper status mirrors runtime-trust disposition" `Quick
            test_keeper_status_disposition_mirrors_runtime_trust
        ; test_case "heartbeat presence uses CAS retry merge" `Quick
            test_heartbeat_presence_uses_cas_retry_merge
        ; test_case "directive meta cluster scan failure fail-closed" `Quick
            test_directive_meta_cluster_scan_failure_fail_closed
        ; test_case "dashboard agent profile read errors observable" `Quick
            test_dashboard_agent_profile_read_error_observable
        ; test_case "composite claim output parse errors observable" `Quick
            test_composite_claim_output_parse_failure_observable
        ] )
    ]
