(* test/test_codex_cli_omission_dedup_10097.ml

   #10097: 143 identical WARN lines per session for codex_cli
   keeper-bound runtime MCP omissions masked unrelated warnings
   in [grep WARN] output.  [record_codex_cli_omission] splits
   the signal:

     - WARN logged once per distinct fingerprint (sorted,
       comma-joined tool list) — operator sees the structural
       fact the first time a given set is stripped;
     - Prometheus counter [masc_codex_cli_mcp_tool_omission_total
       {tool}] increments on EVERY call so dashboards retain the
       frequency signal.

   The test pins:

     1. Counter increments on every call (even repeat calls with
        the same fingerprint) — the frequency signal is not
        deduplicated.
     2. Fingerprint is order-insensitive (sorted) — the same set
        in different orders counts as one fingerprint.
     3. A genuinely new fingerprint (different tool set) is NOT
        silenced — changed omission sets are new information and
        must be re-logged.
     4. Per-tool label isolation — a call with [keeper_shell]
        does not leak into the [keeper_fs_edit] bucket.
     5. Empty tool list is a no-op — fires neither the counter
        nor the WARN.
*)

(* Set MASC_BASE_PATH before Masc_mcp module init (Cdal_verdict_
   gate calls base_path at init time — #9903 prod-guard). *)
let () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-codex-omission-10097-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir
;;

module T = Masc_mcp.Oas_worker_exec_transport
module Prom = Masc_mcp.Prometheus

let metric = Prom.metric_codex_cli_mcp_tool_omission
let counter_for ~tool = Prom.metric_value_or_zero metric ~labels:[ "tool", tool ] ()

(* Counter must increment on every invocation, even when the
   fingerprint has been seen before (the WARN dedup is about log
   noise; the Prometheus rate signal stays honest). *)
let test_counter_increments_on_every_call () =
  T.reset_codex_cli_omission_dedup_for_tests ();
  let tool = "keeper_library_search_t1_10097" in
  let before = counter_for ~tool in
  T.record_codex_cli_omission ~tools:[ tool ];
  T.record_codex_cli_omission ~tools:[ tool ];
  T.record_codex_cli_omission ~tools:[ tool ];
  Alcotest.(check (float 0.0001))
    "counter +3 across three calls with same fingerprint"
    (before +. 3.0)
    (counter_for ~tool)
;;

(* Fingerprint is the sorted list, so [a; b] and [b; a] are one
   set — reordering must not bypass dedup. *)
let test_fingerprint_is_order_insensitive () =
  let a = "keeper_shell_t2_10097" in
  let b = "keeper_fs_edit_t2_10097" in
  Alcotest.(check string)
    "sorted [b;a] and sorted [a;b] yield same fingerprint"
    (T.codex_cli_omission_fingerprint [ a; b ])
    (T.codex_cli_omission_fingerprint [ b; a ])
;;

(* Different tool sets must NOT be silenced by each other.
   Regression guard for over-eager dedup (a single global flag
   would lose genuinely new information when the omission set
   evolves). *)
let test_new_fingerprint_reprints_warn () =
  T.reset_codex_cli_omission_dedup_for_tests ();
  let fp1 = T.codex_cli_omission_fingerprint [ "keeper_shell_t3_10097" ] in
  let fp2 =
    T.codex_cli_omission_fingerprint
      [ "keeper_shell_t3_10097"; "keeper_fs_edit_t3_10097" ]
  in
  Alcotest.(check bool)
    "fp1 is fresh on first encounter"
    false
    (T.codex_cli_omission_fingerprint_seen fp1);
  Alcotest.(check bool)
    "fp1 is seen on second encounter"
    true
    (T.codex_cli_omission_fingerprint_seen fp1);
  Alcotest.(check bool)
    "fp2 is fresh even though fp1 is seen — new set is new information"
    false
    (T.codex_cli_omission_fingerprint_seen fp2);
  Alcotest.(check bool)
    "fp2 is seen on second encounter"
    true
    (T.codex_cli_omission_fingerprint_seen fp2)
;;

(* Per-tool labels must stay isolated — a call with tool X must
   not leak into tool Y's bucket.  Same anti-pattern guard as
   the other counter tests in this tick series. *)
let test_per_tool_label_isolation () =
  T.reset_codex_cli_omission_dedup_for_tests ();
  let x = "keeper_shell_t4_10097" in
  let y = "keeper_fs_edit_t4_10097" in
  let before_y = counter_for ~tool:y in
  T.record_codex_cli_omission ~tools:[ x ];
  Alcotest.(check (float 0.0001))
    "tool Y bucket unchanged when X is omitted"
    before_y
    (counter_for ~tool:y);
  Alcotest.(check bool) "tool X bucket grew" true (counter_for ~tool:x >= 1.0)
;;

(* Empty list must be a pure no-op: no counter, no WARN.  The
   call site checks [if codex_keeper_bound_actor_tools <> []]
   before [record_codex_cli_omission] was introduced, and the
   helper defends the contract so future callers cannot
   accidentally trigger the dedup slot on empty input. *)
let test_empty_tools_is_noop () =
  T.reset_codex_cli_omission_dedup_for_tests ();
  let probe = "keeper_probe_empty_t5_10097" in
  let before = counter_for ~tool:probe in
  T.record_codex_cli_omission ~tools:[];
  Alcotest.(check (float 0.0001))
    "probe bucket unchanged"
    before
    (counter_for ~tool:probe);
  let empty_fp = T.codex_cli_omission_fingerprint [] in
  (* An empty fingerprint, if it were ever recorded, would burn
     one dedup slot — assert it was NOT seen. *)
  Alcotest.(check bool)
    "empty fingerprint never recorded"
    false
    (T.codex_cli_omission_fingerprint_seen empty_fp);
  (* Clean up the slot we just opened so other tests are not
     affected by the side-effect check above. *)
  T.reset_codex_cli_omission_dedup_for_tests ()
;;

let () =
  Alcotest.run
    "codex_cli_omission_dedup_10097"
    [ ( "counter"
      , [ Alcotest.test_case
            "increments on every call"
            `Quick
            test_counter_increments_on_every_call
        ; Alcotest.test_case
            "per-tool label isolation"
            `Quick
            test_per_tool_label_isolation
        ] )
    ; ( "fingerprint"
      , [ Alcotest.test_case
            "order-insensitive"
            `Quick
            test_fingerprint_is_order_insensitive
        ; Alcotest.test_case "new set reprints" `Quick test_new_fingerprint_reprints_warn
        ] )
    ; ( "empty"
      , [ Alcotest.test_case "empty tools is no-op" `Quick test_empty_tools_is_noop ] )
    ]
;;
