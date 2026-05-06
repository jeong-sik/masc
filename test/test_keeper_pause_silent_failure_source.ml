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

let target_file = "lib/server/server_dashboard_http_keeper_api.ml"

let status_detail_file = "lib/keeper/keeper_status_detail.ml"

let metric_name = "metric_keeper_paused_state_persist_errors"

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

let test_metric_registered () =
  let prom = load_source "lib/prometheus.ml" in
  check bool "paused-state persist-errors metric declared" true
    (count_occurrences
       ~needle:"masc_keeper_paused_state_persist_errors_total"
       prom
     >= 1);
  check bool "paused-state persist-errors metric registered with HELP"
    true
    (count_occurrences ~needle:metric_name prom >= 2)

let test_happy_path_preserved () =
  let src = load_source target_file in
  (* (a) The happy [Ok (Some meta)] arms must still be present in both
     closures so successful pause/resume keeps returning 200. *)
  check bool "persist_keeper_paused_state happy arm present" true
    (count_occurrences
       ~needle:"Ok (Some meta) when Bool.equal meta.paused paused -> ()"
       src
     >= 1);
  check bool "resume_booted_keeper_if_needed happy arm present" true
    (count_occurrences
       ~needle:"Ok (Some meta) when meta.paused"
       src
     >= 1)

let test_silent_fold_removed () =
  let src = load_source target_file in
  (* (d) The exact silent fold ["Ok None | Error _ -> ()"] must not
     reappear inside [persist_keeper_paused_state] or
     [resume_booted_keeper_if_needed]. We allow it elsewhere because
     [resolve_keeper_agent_name] (line ~678) legitimately collapses
     both into [None] for a name lookup. *)
  let needle = "Ok None | Error _ -> ()" in
  check int "silent fold returning unit removed" 0
    (count_occurrences ~needle src)

let test_ok_none_branch_observable () =
  let src = load_source target_file in
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
  let src = load_source target_file in
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

let test_counter_inc_calls () =
  let src = load_source target_file in
  (* The metric must actually be incremented at least 4 times: 2 in
     [persist_keeper_paused_state] (Ok None / Error), 2 in
     [resume_booted_keeper_if_needed] (Ok None / Error), 2 in the
     directive endpoint (Ok None / Error) — total 6. *)
  check bool "Prometheus.inc_counter called for new metric >= 6 times"
    true
    (count_occurrences
       ~needle:"Prometheus.metric_keeper_paused_state_persist_errors"
       src
     >= 6)

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
        ; test_case "counter inc calls present" `Quick
            test_counter_inc_calls
        ; test_case "keeper status mirrors runtime-trust disposition" `Quick
            test_keeper_status_disposition_mirrors_runtime_trust
        ] )
    ]
