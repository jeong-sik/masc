(* Runtime-manifest parsing and failover-mode classification for
   --inject-failover (lib/keeper_canary/keeper_canary_failover.ml, masc
   task-12, M2 PR-C). The HTTP fetch lives in bin/ and is exercised by
   live runs; the verdict logic is what must never drift. *)

module F = Keeper_canary_failover

let row ?(turn = Some 7) ?(error_kind = None) ?candidate ~ts ~event ~runtime ()
  : Yojson.Safe.t
  =
  let decision_fields =
    (match candidate with
     | Some candidate -> [ ("runtime_id", `String candidate) ]
     | None -> [])
    @
    match error_kind with
    | Some kind -> [ ("error_kind", `String kind) ]
    | None -> []
  in
  `Assoc
    ([ ("ts", `String ts)
     ; ("event", `String event)
     ; ("runtime_id", `String runtime)
     ]
     @ (match turn with Some n -> [ ("keeper_turn_id", `Int n) ] | None -> [])
     @
     match decision_fields with
     | [] -> []
     | fields -> [ ("decision", `Assoc fields) ])

let response rows = `Assoc [ ("manifest_rows", `List rows) ]

let parsed label rows =
  match F.parse_manifest_rows (response rows) with
  | Ok attempts -> attempts
  | Error msg -> Alcotest.failf "%s: %s" label msg

let test_parse_keeps_attribution_events_only () =
  let attempts =
    parsed
      "mixed rows"
      [ row ~ts:"2026-08-16T00:00:01Z" ~event:"runtime_routed" ~runtime:"a" ()
      ; row ~ts:"2026-08-16T00:00:02Z" ~event:"checkpoint_saved" ~runtime:"a" ()
      ; row ~ts:"2026-08-16T00:00:03Z" ~event:"turn_finished" ~runtime:"a" ()
      ; row
          ~ts:"2026-08-16T00:00:04Z"
          ~event:"runtime_failed"
          ~runtime:"a"
          ~error_kind:(Some "provider_unreachable")
          ()
      ; row ~ts:"2026-08-16T00:00:05Z" ~event:"runtime_completed" ~runtime:"b" ()
      ]
  in
  Alcotest.(check int) "three attribution rows" 3 (List.length attempts);
  match attempts with
  | [ routed; failed; completed ] ->
    Alcotest.(check bool) "routed" true (routed.F.event = F.Routed);
    (match failed.F.error_kind with
     | Some (F.Error_kind k) ->
       Alcotest.(check string) "error kind carried" "provider_unreachable" k
     | None -> Alcotest.fail "expected error_kind on the failed row");
    Alcotest.(check string) "completed runtime" "b" completed.F.runtime_id
  | _ -> Alcotest.fail "unexpected attempt shape"

let test_parse_rejects_malformed_attribution_row () =
  let broken =
    `Assoc [ ("ts", `String "2026-08-16T00:00:01Z"); ("event", `String "runtime_routed") ]
  in
  match F.parse_manifest_rows (response [ broken ]) with
  | Ok _ -> Alcotest.fail "expected Error for attribution row missing runtime_id"
  | Error msg ->
    Alcotest.(check bool)
      "mentions runtime_id"
      true
      (Astring.String.is_infix ~affix:"runtime_id" msg)

let test_parse_rejects_missing_manifest_rows () =
  match F.parse_manifest_rows (`Assoc [ ("keeper", `String "x") ]) with
  | Ok _ -> Alcotest.fail "expected Error"
  | Error msg ->
    Alcotest.(check bool)
      "mentions manifest_rows"
      true
      (Astring.String.is_infix ~affix:"manifest_rows" msg)

let test_classify_in_turn () =
  let attempts =
    parsed
      "in-turn walk"
      [ row ~ts:"2026-08-16T00:00:01Z" ~event:"runtime_routed" ~runtime:"a" ()
      ; row
          ~ts:"2026-08-16T00:00:02Z"
          ~event:"runtime_failed"
          ~runtime:"a"
          ~error_kind:(Some "network")
          ()
      ; row ~ts:"2026-08-16T00:00:03Z" ~event:"runtime_routed" ~runtime:"b" ()
      ; row ~ts:"2026-08-16T00:00:04Z" ~event:"runtime_completed" ~runtime:"b" ()
      ]
  in
  let mode, windowed = F.classify ~window_start:"2026-08-16T00:00:00Z" ~attempts in
  Alcotest.(check string) "mode" "in_turn" (F.mode_to_string mode);
  Alcotest.(check int) "all four rows in window" 4 (List.length windowed)

let test_classify_deferred () =
  (* Turn 7 fails on a; turn 8 (a later cycle) routes and completes on b —
     no single turn saw two candidates. *)
  let attempts =
    parsed
      "deferred switch"
      [ row ~turn:(Some 7) ~ts:"2026-08-16T00:00:01Z" ~event:"runtime_routed" ~runtime:"a" ()
      ; row
          ~turn:(Some 7)
          ~ts:"2026-08-16T00:00:02Z"
          ~event:"runtime_failed"
          ~runtime:"a"
          ~error_kind:(Some "provider_effect_fenced")
          ()
      ; row ~turn:(Some 8) ~ts:"2026-08-16T00:00:03Z" ~event:"runtime_routed" ~runtime:"b" ()
      ; row ~turn:(Some 8) ~ts:"2026-08-16T00:00:04Z" ~event:"runtime_completed" ~runtime:"b" ()
      ]
  in
  let mode, _ = F.classify ~window_start:"2026-08-16T00:00:00Z" ~attempts in
  Alcotest.(check string) "mode" "deferred" (F.mode_to_string mode)

let test_classify_not_observed () =
  let attempts =
    parsed
      "single healthy runtime"
      [ row ~ts:"2026-08-16T00:00:01Z" ~event:"runtime_routed" ~runtime:"a" ()
      ; row ~ts:"2026-08-16T00:00:02Z" ~event:"runtime_completed" ~runtime:"a" ()
      ]
  in
  let mode, _ = F.classify ~window_start:"2026-08-16T00:00:00Z" ~attempts in
  Alcotest.(check string) "mode" "not_observed" (F.mode_to_string mode)

let test_classify_window_excludes_earlier_rows () =
  (* The failover-looking pair sits before the window; only a healthy
     completion falls inside. The verdict must not read history. *)
  let attempts =
    parsed
      "stale history"
      [ row ~ts:"2026-08-16T00:00:01Z" ~event:"runtime_routed" ~runtime:"a" ()
      ; row
          ~ts:"2026-08-16T00:00:02Z"
          ~event:"runtime_failed"
          ~runtime:"a"
          ~error_kind:(Some "network")
          ()
      ; row ~ts:"2026-08-16T00:00:03Z" ~event:"runtime_routed" ~runtime:"b" ()
      ; row ~ts:"2026-08-16T00:10:00Z" ~event:"runtime_routed" ~runtime:"b" ()
      ; row ~ts:"2026-08-16T00:10:01Z" ~event:"runtime_completed" ~runtime:"b" ()
      ]
  in
  let mode, windowed = F.classify ~window_start:"2026-08-16T00:05:00Z" ~attempts in
  Alcotest.(check string) "mode" "not_observed" (F.mode_to_string mode);
  Alcotest.(check int) "only windowed rows" 2 (List.length windowed)

let test_lane_walk_attribution_prefers_decision_candidate () =
  (* #28871: rows from a lane walk keep the lane id at top level and put
     the attempted candidate in decision.runtime_id. The turn-44 live
     shape: llama fails at idx 0, glm completes at idx 1, every top-level
     runtime_id identical. Attribution by candidate must classify this as
     an in-turn walk; attribution by top-level id would call it a
     same-runtime retry. *)
  let lane = "llama_cpp.qwen3-8-27b-llama" in
  let attempts =
    parsed
      "lane walk"
      [ row ~ts:"2026-08-16T00:00:01Z" ~event:"runtime_routed" ~runtime:lane
          ~candidate:lane ()
      ; row
          ~ts:"2026-08-16T00:00:02Z"
          ~event:"runtime_failed"
          ~runtime:lane
          ~candidate:lane
          ~error_kind:(Some "api")
          ()
      ; row ~ts:"2026-08-16T00:00:03Z" ~event:"runtime_routed" ~runtime:lane
          ~candidate:"glm-coding.glm-5-turbo" ()
      ; row ~ts:"2026-08-16T00:00:04Z" ~event:"runtime_completed" ~runtime:lane
          ~candidate:"glm-coding.glm-5-turbo" ()
      ]
  in
  (match attempts with
   | _ :: _ :: routed_glm :: _ ->
     Alcotest.(check string)
       "candidate id wins over lane id"
       "glm-coding.glm-5-turbo"
       routed_glm.F.runtime_id
   | _ -> Alcotest.fail "unexpected attempt shape");
  let mode, _ = F.classify ~window_start:"2026-08-16T00:00:00Z" ~attempts in
  Alcotest.(check string) "mode" "in_turn" (F.mode_to_string mode)

let test_classify_same_runtime_failure_is_not_failover () =
  (* a fails, then a completes on retry — same runtime, no switch. *)
  let attempts =
    parsed
      "same-runtime retry"
      [ row
          ~ts:"2026-08-16T00:00:01Z"
          ~event:"runtime_failed"
          ~runtime:"a"
          ~error_kind:(Some "timeout")
          ()
      ; row ~ts:"2026-08-16T00:00:02Z" ~event:"runtime_completed" ~runtime:"a" ()
      ]
  in
  let mode, _ = F.classify ~window_start:"2026-08-16T00:00:00Z" ~attempts in
  Alcotest.(check string) "mode" "not_observed" (F.mode_to_string mode)

let () =
  Alcotest.run
    "keeper_canary_failover"
    [ ( "parse"
      , [ Alcotest.test_case "keeps attribution events only" `Quick
            test_parse_keeps_attribution_events_only
        ; Alcotest.test_case "rejects malformed attribution row" `Quick
            test_parse_rejects_malformed_attribution_row
        ; Alcotest.test_case "rejects missing manifest_rows" `Quick
            test_parse_rejects_missing_manifest_rows
        ] )
    ; ( "classify"
      , [ Alcotest.test_case "in-turn walk" `Quick test_classify_in_turn
        ; Alcotest.test_case "deferred switch" `Quick test_classify_deferred
        ; Alcotest.test_case "not observed" `Quick test_classify_not_observed
        ; Alcotest.test_case "window excludes earlier rows" `Quick
            test_classify_window_excludes_earlier_rows
        ; Alcotest.test_case "lane walk attribution prefers decision candidate" `Quick
            test_lane_walk_attribution_prefers_decision_candidate
        ; Alcotest.test_case "same-runtime retry is not failover" `Quick
            test_classify_same_runtime_failure_is_not_failover
        ] )
    ]
