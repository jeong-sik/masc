open Alcotest

module Usage = Runtime_provider_usage_window

let decode decoder json =
  match decoder (Yojson.Safe.from_string json) with
  | Ok report -> report
  | Error detail -> fail (Usage.decode_error_to_string detail)

let scope name = Runtime_quota_window.scope_of_credential ~provider_id:name None

let test_cap_removed_and_empty_report () =
  let scope = scope "snapshot_credit_lifecycle" in
  let cap = decode Usage.decode_openrouter_key
      {|{"data":{"limit":20,"limit_remaining":0}}|} in
  Usage.record ~scope ~observed_at:100. cap;
  let uncapped = decode Usage.decode_openrouter_key
      {|{"data":{"limit":null,"usage":21.5}}|} in
  Usage.record ~scope ~observed_at:101. uncapped;
  (match Usage.state ~scope with
   | Reported ({ window = { utilization = Usd { used; limit = None }; _ }; _ }, []) ->
       check (float 0.0001) "the removed cap leaves only uncapped USD use" 21.5 used
   | _ -> fail "old credit limit survived its removal");
  Usage.record ~scope ~observed_at:102.
    (decode Usage.decode_openrouter_key {|{"data":{"limit":null}}|});
  Usage.record ~scope ~observed_at:100.5 cap;
  match Usage.state ~scope with
  | Reported_no_windows { observed_at; source = Openrouter_key_read } ->
      check (float 0.) "empty report is retained and stale cap cannot return" 102. observed_at
  | _ -> fail "a removed cap returned or the empty report was lost"

let test_disabled_antigravity_bucket () =
  let scope = scope "snapshot_antigravity_lifecycle" in
  let report disabled = decode Usage.decode_antigravity_usage (Printf.sprintf
      {|{"status":"SUCCESS","num_turns":0,"command":{"name":"usage","data":{"groups":[{"buckets":[{"id":"week","window":"weekly","remaining_fraction":0},{"id":"short","window":"5h","remaining_fraction":0,"disabled":%b}]}]}}}|}
      disabled) in
  Usage.record ~scope ~observed_at:100. (report false);
  Usage.record ~scope ~observed_at:101. (report true);
  match Usage.state ~scope with
  | Reported ({ window = { limit_id = Some "week"; _ }; _ }, []) -> ()
  | _ -> fail "disabled Antigravity bucket is still displayed"

let test_sparse_codex_update () =
  let scope = scope "snapshot_codex_sparse" in
  let report json = decode Usage.decode_codex_rate_limits_updated json in
  Usage.record ~scope ~observed_at:100.
    (report {|{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}|});
  Usage.record ~scope ~observed_at:101.
    (report {|{"rateLimits":{"primary":null,"secondary":{"usedPercent":21,"windowDurationMins":10080}}}|});
  match Usage.state ~scope with
  | Reported ({ window = { kind = Five_hour; utilization = Percent 100; _ }; _ },
      [{ window = { kind = Seven_day; utilization = Percent 21; _ }; _ }]) -> ()
  | _ -> fail "sparse update erased an unstated window"

let test_mixed_sources_publish_only_accepted_windows () =
  let scope = scope "snapshot_mixed_source_acceptance" in
  let window id percent : Usage.window =
    { limit_id = Some id; kind = Five_hour; role = Gates_model_calls
    ; utilization = Percent percent; resets_at = None }
  in
  let report source windows : Usage.report = { source; windows } in
  let omitted = window "omitted" 10 in
  let held = window "shared" 80 in
  let foreign = window "foreign" 20 in
  Usage.record ~scope ~observed_at:100.
    (report Zai_quota_limit_read [omitted; window "shared" 10]);
  Usage.record ~scope ~observed_at:200.
    (report Codex_account_rate_limits_updated [held; foreign]);
  let observed = ref [] in
  Fun.protect
    ~finally:(fun () -> Usage.set_record_observer (fun ~scope:_ ~observed_at:_ _ -> ()))
    (fun () ->
      Usage.set_record_observer (fun ~scope ~observed_at accepted ->
        (* These reads acquire the public store lock again: the sink must run
           after publication and outside the recording critical section. *)
        observed :=
          (observed_at, accepted, Usage.state ~scope, Usage.recorded_scopes ()) :: !observed);
      let first = window "new-b" 30 and second = window "new-a" 40 in
      Usage.record ~scope ~observed_at:150.
        (report Zai_quota_limit_read
           [window "shared" 99; first; second; window "new-b" 99]);
      let expected : Usage.scope_state =
        Reported
          ({ window = foreign; source = Codex_account_rate_limits_updated; observed_at = 200. },
           [ { window = second; source = Zai_quota_limit_read; observed_at = 150. }
           ; { window = first; source = Zai_quota_limit_read; observed_at = 150. }
           ; { window = held; source = Codex_account_rate_limits_updated; observed_at = 200. }
           ])
      in
      (match !observed with
       | [(150., accepted, snapshot, scopes)] ->
         check bool "sink keeps accepted input order and the first duplicate" true
           (accepted = report Zai_quota_limit_read [first; second]);
         check bool "sink reads the already-published mixed-source state" true
           (snapshot = expected && List.mem scope scopes)
       | _ -> fail "accepted mixed-source report was not observed exactly once");
      Usage.record ~scope ~observed_at:140. (report Zai_quota_limit_read [omitted]);
      Usage.record ~scope ~observed_at:150. (report Zai_quota_limit_read [window "new-a" 99]);
      Usage.record ~scope ~observed_at:150.
        (report Claude_code_rate_limit_event [window "new-b" 99]);
      check int "stale source and equal-time window reports never reach the sink" 1
        (List.length !observed);
      check bool "own omission stays retired and newer other-source windows survive" true
        (Usage.state ~scope = expected))

let test_empty_reports_distinguish_unseen_and_reported_scopes () =
  let sparse_scope = scope "snapshot_empty_sparse_scope" in
  let complete_scope = scope "snapshot_empty_complete_scope" in
  let observed = ref [] in
  Fun.protect
    ~finally:(fun () -> Usage.set_record_observer (fun ~scope:_ ~observed_at:_ _ -> ()))
    (fun () ->
      Usage.set_record_observer (fun ~scope ~observed_at report ->
        observed := (scope, observed_at, report) :: !observed);
      Usage.record ~scope:sparse_scope ~observed_at:100.
        { source = Codex_account_rate_limits_updated; windows = [] };
      check bool "empty sparse update is still unreported" true
        (Usage.state ~scope:sparse_scope = Not_reported_since_start);
      check bool "empty sparse update does not register a scope" false
        (List.mem sparse_scope (Usage.recorded_scopes ()));
      check int "empty sparse update has no durable observation" 0 (List.length !observed);
      let empty : Usage.report = { source = Openrouter_key_read; windows = [] } in
      Usage.record ~scope:complete_scope ~observed_at:101. empty;
      check bool "empty complete report registers the scope" true
        (List.mem complete_scope (Usage.recorded_scopes ()));
      check bool "empty complete report keeps its observation time" true
        (Usage.state ~scope:complete_scope =
           Reported_no_windows { source = Openrouter_key_read; observed_at = 101. });
      check bool "empty complete report reaches the observer" true
        (!observed = [complete_scope, 101., empty]))

let test_quota_rest_uses_accepted_source_snapshot () =
  let scope = scope "snapshot_accepted_quota_source" in
  let window id : Usage.window =
    { limit_id = Some id; kind = Five_hour; role = Gates_model_calls
    ; utilization = Percent 100; resets_at = None }
  in
  let foreign = window "foreign" and own = window "own" in
  let report source windows : Usage.report = { source; windows } in
  let observed = ref [] in
  Runtime_quota_window.reset_for_testing ();
  Fun.protect
    ~finally:(fun () ->
      Usage.set_record_observer (fun ~scope:_ ~observed_at:_ _ -> ());
      Runtime_quota_window.reset_for_testing ())
    (fun () ->
      Usage.record ~scope ~observed_at:200.
        (report Codex_account_rate_limits_updated [foreign]);
      Usage.set_record_observer (fun ~scope ~observed_at accepted ->
        observed :=
          (accepted.windows, Runtime_quota_window.is_exhausted ~scope ~now:observed_at,
           Usage.state ~scope) :: !observed);
      Usage.record ~scope ~observed_at:100.
        (report Zai_quota_limit_read [foreign]);
      check bool "a newer foreign window cannot rest the accepted source" false
        (Runtime_quota_window.is_exhausted ~scope ~now:100.);
      Usage.record ~scope ~observed_at:101.
        (report Zai_quota_limit_read [own]);
      check bool "an accepted own window rests the scope" true
        (Runtime_quota_window.is_exhausted ~scope ~now:101.);
      Runtime_quota_window.note_succeeded ~scope;
      Usage.record ~scope ~observed_at:100. (report Zai_quota_limit_read [own]);
      Usage.record ~scope ~observed_at:101. (report Zai_quota_limit_read [own]);
      check bool "rejected old and equal reports do not restore cleared rest" false
        (Runtime_quota_window.is_exhausted ~scope ~now:101.);
      Usage.record ~scope ~observed_at:102. (report Zai_quota_limit_read []);
      let foreign_state : Usage.scope_state =
        Reported ({ window = foreign; source = Codex_account_rate_limits_updated;
                    observed_at = 200. }, [])
      in
      match List.rev !observed with
      | [([], false, first); ([held], true, _); ([], false, last)] ->
        check bool "the sink sees rest after acceptance and before notification" true
          (held = own);
        check bool "empty acceptance and revocation retain only the foreign window" true
          (first = foreign_state && last = foreign_state)
      | _ -> fail "quota rest, accepted reports and observed snapshots diverged")

let test_retraction_before_older_acceptance_converges () =
  let in_order = scope "snapshot_retraction_in_order" in
  let out_of_order = scope "snapshot_retraction_out_of_order" in
  let cap = decode Usage.decode_openrouter_key
      {|{"data":{"limit":20,"limit_remaining":5}}|} in
  let retracted = decode Usage.decode_openrouter_key
      {|{"data":{"limit":null}}|} in
  Usage.record ~scope:in_order ~observed_at:100. cap;
  Usage.record ~scope:in_order ~observed_at:200. retracted;
  Usage.record ~scope:out_of_order ~observed_at:200. retracted;
  Usage.record ~scope:out_of_order ~observed_at:100. cap;
  let expected : Usage.scope_state =
    Reported_no_windows { source = Openrouter_key_read; observed_at = 200. }
  in
  check bool "in-order and out-of-order retraction converge on the same state" true
    (Usage.state ~scope:in_order = expected
     && Usage.state ~scope:out_of_order = expected)

let () =
  run "provider usage snapshots"
    [ "account lifecycle",
      [ test_case "removed credit cap and empty report" `Quick test_cap_removed_and_empty_report
      ; test_case "disabled Antigravity bucket" `Quick test_disabled_antigravity_bucket
      ; test_case "sparse Codex update" `Quick test_sparse_codex_update
      ; test_case "mixed sources publish accepted windows before observing" `Quick
          test_mixed_sources_publish_only_accepted_windows
      ; test_case "empty reports distinguish unseen and reported scopes" `Quick
          test_empty_reports_distinguish_unseen_and_reported_scopes
      ; test_case "quota rest uses the accepted source snapshot" `Quick
          test_quota_rest_uses_accepted_source_snapshot
      ; test_case "retraction arriving before older acceptance converges" `Quick
          test_retraction_before_older_acceptance_converges ] ]
