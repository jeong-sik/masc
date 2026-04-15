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
  ]
