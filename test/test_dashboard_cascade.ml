(** Smoke tests for {!Dashboard_cascade} — the dashboard projection
    of cascade config + health tracker.

    These tests exercise the JSON-shape contract the HTTP routes rely on.
    They do not hit the network or the real cascade.json — they validate
    that each top-level field exists with the expected type so a schema
    regression is caught without starting the server. *)

open Alcotest

let json : Yojson.Safe.t testable =
  let pp fmt j = Format.fprintf fmt "%s" (Yojson.Safe.to_string j) in
  testable pp Yojson.Safe.equal

let member key = Yojson.Safe.Util.member key

let to_list_opt = function
  | `List xs -> Some xs
  | _ -> None

(* ── config_json ───────────────────────────────────── *)

let test_config_shape () =
  let j = Masc_mcp.Dashboard_cascade.config_json () in
  (* Required top-level keys *)
  (match member "updated_at" j with
   | `String _ -> () | _ -> fail "updated_at should be string");
  (match member "config_path" j with
   | `String _ | `Null -> ()
   | _ -> fail "config_path should be string or null");
  (match member "profiles" j with
   | `List _ -> () | _ -> fail "profiles should be list");
  (match member "keeper_profiles" j with
   | `List _ -> () | _ -> fail "keeper_profiles should be list")

let test_config_profile_shape () =
  let j = Masc_mcp.Dashboard_cascade.config_json () in
  match to_list_opt (member "profiles" j) with
  | None | Some [] -> fail "expected at least one profile"
  | Some (p :: _) ->
    (match member "name" p with
     | `String _ -> () | _ -> fail "profile.name should be string");
    (match member "source" p with
     | `String s when List.mem s ["named"; "default_fallback"; "hardcoded_defaults"] -> ()
     | `String s -> fail (Printf.sprintf "unexpected source: %s" s)
     | _ -> fail "profile.source should be string");
    (match member "candidates" p with
     | `List _ -> () | _ -> fail "profile.candidates should be list")

let test_config_candidate_shape () =
  let j = Masc_mcp.Dashboard_cascade.config_json () in
  let rec first_nonempty_candidates = function
    | [] -> None
    | p :: rest ->
      (match to_list_opt (member "candidates" p) with
       | Some (c :: _) -> Some c
       | _ -> first_nonempty_candidates rest)
  in
  match to_list_opt (member "profiles" j) with
  | None -> fail "profiles missing"
  | Some profiles ->
    (match first_nonempty_candidates profiles with
     | None -> () (* No candidates is allowed when config_path is None *)
     | Some c ->
       let fields = ["model"; "config_weight"; "effective_weight";
                     "success_rate"; "in_cooldown"] in
       List.iter (fun k ->
         match member k c with
         | `Null -> fail (Printf.sprintf "candidate.%s missing" k)
         | _ -> ()) fields)

(* ── health_json ───────────────────────────────────── *)

let test_health_shape () =
  let j = Masc_mcp.Dashboard_cascade.health_json () in
  (match member "updated_at" j with
   | `String _ -> () | _ -> fail "updated_at should be string");
  (match member "window_sec" j with
   | `Float _ -> () | _ -> fail "window_sec should be float");
  (match member "cooldown_threshold" j with
   | `Int _ -> () | _ -> fail "cooldown_threshold should be int");
  (match member "cooldown_sec" j with
   | `Float _ -> () | _ -> fail "cooldown_sec should be float");
  (match member "providers" j with
   | `List _ -> () | _ -> fail "providers should be list")

let test_health_serializable () =
  let j = Masc_mcp.Dashboard_cascade.health_json () in
  let s = Yojson.Safe.to_string j in
  check bool "non-empty json" true (String.length s > 0);
  (* Roundtrip *)
  let reparsed = Yojson.Safe.from_string s in
  check json "roundtrip" j reparsed

(* ── SLO (LT-11) ─────────────────────────────────────── *)

module ST = Masc_mcp.Cascade_strategy_trace

let mk_trace ?(ts = 0.0) ?(strategy = "failover") ~kind () =
  { ST.ts; cascade_name = "c1"; strategy; cycle = 0;
    candidates_in = 1; candidates_out = 1; backoff_ms = 0; kind }

let assert_field name fields =
  match List.assoc_opt name fields with
  | Some v -> v
  | None -> fail (Printf.sprintf "field %s missing" name)

let slo_fields () =
  match Masc_mcp.Dashboard_cascade.slo_json () with
  | `Assoc fs -> fs
  | _ -> fail "expected assoc"

let current_field fields key =
  match assert_field "current" fields with
  | `Assoc cs ->
    (match List.assoc_opt key cs with
     | Some v -> v
     | None -> fail (Printf.sprintf "current.%s missing" key))
  | _ -> fail "current not assoc"

let test_slo_empty_ring_is_ok () =
  ST.clear ();
  let fs = slo_fields () in
  (match assert_field "status" fs with
   | `String "ok" -> ()
   | _ -> fail "expected status=ok on empty ring");
  (match current_field fs "ordered_ratio" with
   | `Float v -> check (float 0.0) "idle treated as 1.0" 1.0 v
   | _ -> fail "ordered_ratio not float")

let test_slo_all_ordered () =
  ST.clear ();
  for _ = 1 to 10 do
    ST.record (mk_trace ~kind:ST.Ordered ())
  done;
  let fs = slo_fields () in
  (match current_field fs "ordered_ratio" with
   | `Float v -> check (float 0.0) "all ordered → 1.0" 1.0 v
   | _ -> fail "ordered_ratio not float");
  (match assert_field "status" fs with
   | `String "ok" -> ()
   | _ -> fail "expected status=ok")

let test_slo_partial_filtered () =
  ST.clear ();
  for _ = 1 to 90 do
    ST.record (mk_trace ~kind:ST.Ordered ())
  done;
  for _ = 1 to 10 do
    ST.record (mk_trace ~kind:ST.Filtered_empty ())
  done;
  let fs = slo_fields () in
  (match current_field fs "ordered_ratio" with
   | `Float v ->
     check bool "ratio ≈ 0.9 (< 0.99 target)" true (v < 0.99);
     check bool "ratio > 0.8" true (v > 0.8)
   | _ -> fail "ordered_ratio not float");
  (match assert_field "status" fs with
   | `String ("violated") -> ()
   | `String "warn" -> ()  (* depending on exhaustion_count too *)
   | `String other -> fail (Printf.sprintf "expected violated/warn, got %s" other)
   | _ -> fail "status not string")

let test_slo_exhaustion_breach () =
  ST.clear ();
  for _ = 1 to 11 do
    ST.record (mk_trace ~kind:ST.Exhausted ())
  done;
  let fs = slo_fields () in
  (match current_field fs "exhaustion_count" with
   | `Int v -> check bool "exhaustion_count >= 11 (> 10 target)" true (v >= 11)
   | _ -> fail "exhaustion_count not int");
  (match assert_field "status" fs with
   | `String "violated" -> ()
   | _ -> fail "expected status=violated");
  (match assert_field "violations" fs with
   | `List xs ->
     check bool "violations includes exhaustion_count" true
       (List.exists (function `String "exhaustion_count" -> true | _ -> false) xs)
   | _ -> fail "violations not list")

let test_slo_burn_rate_math () =
  ST.clear ();
  (* 98 ordered + 2 filtered_empty → ratio = 0.98 → burn = 2.0 *)
  for _ = 1 to 98 do ST.record (mk_trace ~kind:ST.Ordered ()) done;
  for _ = 1 to 2 do ST.record (mk_trace ~kind:ST.Filtered_empty ()) done;
  let fs = slo_fields () in
  (match current_field fs "burn_rate" with
   | `Float v ->
     check bool "burn_rate ≈ 2.0 (> 1.0 target)" true (v > 1.9 && v < 2.1)
   | _ -> fail "burn_rate not float")

let test_slo_top_level_shape () =
  ST.clear ();
  let fs = slo_fields () in
  check bool "has updated_at" true (List.mem_assoc "updated_at" fs);
  check bool "has window_sample_size" true (List.mem_assoc "window_sample_size" fs);
  check bool "has targets" true (List.mem_assoc "targets" fs);
  check bool "has current" true (List.mem_assoc "current" fs);
  check bool "has status" true (List.mem_assoc "status" fs);
  check bool "has violations" true (List.mem_assoc "violations" fs)

(* ── Suite ─────────────────────────────────────────── *)

let () =
  run "dashboard_cascade" [
    "config_json", [
      test_case "top-level shape" `Quick test_config_shape;
      test_case "profile shape" `Quick test_config_profile_shape;
      test_case "candidate shape" `Quick test_config_candidate_shape;
    ];
    "health_json", [
      test_case "top-level shape" `Quick test_health_shape;
      test_case "roundtrip serializable" `Quick test_health_serializable;
    ];
    "slo_json", [
      test_case "top-level shape" `Quick test_slo_top_level_shape;
      test_case "empty ring → status ok, ratio 1.0" `Quick test_slo_empty_ring_is_ok;
      test_case "all ordered → ratio 1.0" `Quick test_slo_all_ordered;
      test_case "partial filtered drops ratio" `Quick test_slo_partial_filtered;
      test_case "exhaustion > 10 → violated" `Quick test_slo_exhaustion_breach;
      test_case "burn_rate math" `Quick test_slo_burn_rate_math;
    ];
  ]
