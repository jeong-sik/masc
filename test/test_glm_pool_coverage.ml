(** GLM Pool Coverage Tests

    Tests for the GLM Cloud multi-model load balancer:
    - Model lookup (find_model_index, is_pool_model)
    - Selection strategy (select_model, select_model_preferring)
    - In-flight tracking (acquire, release, current_load)
    - RAII wrapper (with_model + exception safety)
    - Pool stats and capacity (get_stats, total_capacity, has_capacity)
*)

open Alcotest

module Glm_pool = Masc_mcp.Glm_pool

(** Reset pool state by releasing all in-flight requests. *)
let reset_pool () =
  let stats = Glm_pool.get_stats () in
  List.iter (fun (model_id, in_flight, _limit) ->
    for _ = 1 to in_flight do
      Glm_pool.release model_id
    done
  ) stats

(* ============================================================
   total_capacity / available_models
   ============================================================ *)

let test_total_capacity () =
  check int "total_capacity is 39" 39 Glm_pool.total_capacity

let test_available_models_count () =
  let stats = Glm_pool.get_stats () in
  check int "7 models in pool" 7 (List.length stats)

(* ============================================================
   find_model_index
   ============================================================ *)

let test_find_model_index_existing () =
  let idx = Glm_pool.find_model_index "glm-4.5" in
  check bool "found glm-4.5" true (idx >= 0)

let test_find_model_index_case_insensitive () =
  let idx = Glm_pool.find_model_index "GLM-4.5" in
  check bool "case insensitive" true (idx >= 0)

let test_find_model_index_not_found () =
  let idx = Glm_pool.find_model_index "nonexistent-model" in
  check int "not found returns -1" (-1) idx

let test_find_model_index_all_models () =
  let models = ["glm-4.5"; "glm-4.6v"; "glm-5"; "glm-4.7";
                 "glm-4.6"; "glm-4.6v-flashx"; "glm-4.7-flashx"] in
  List.iter (fun m ->
    let idx = Glm_pool.find_model_index m in
    check bool (Printf.sprintf "%s found" m) true (idx >= 0)
  ) models

(* ============================================================
   is_pool_model
   ============================================================ *)

let test_is_pool_model_true () =
  check bool "glm-5 is pool model" true (Glm_pool.is_pool_model "glm-5")

let test_is_pool_model_false () =
  check bool "gpt-4 not pool model" false (Glm_pool.is_pool_model "gpt-4")

let test_is_pool_model_flash_excluded () =
  (* glm-4.7-flash has limit 1, excluded from pool *)
  check bool "glm-4.7-flash not in pool" false
    (Glm_pool.is_pool_model "glm-4.7-flash")

(* ============================================================
   select_model (least-loaded strategy)
   ============================================================ *)

let test_select_model_returns_pool_model () =
  reset_pool ();
  let model = Glm_pool.select_model () in
  check bool "selected model is in pool" true (Glm_pool.is_pool_model model)

let test_select_model_prefers_least_loaded () =
  reset_pool ();
  (* Fill glm-4.5 (limit 10) with 9 requests — ratio 0.9 *)
  for _ = 1 to 9 do Glm_pool.acquire "glm-4.5" done;
  let model = Glm_pool.select_model () in
  (* Should NOT pick glm-4.5 since other models have ratio 0.0 *)
  check bool "avoids heavily loaded model" true (model <> "glm-4.5");
  for _ = 1 to 9 do Glm_pool.release "glm-4.5" done

let test_select_model_round_robin_fallback () =
  reset_pool ();
  (* Fill ALL models to capacity *)
  let stats = Glm_pool.get_stats () in
  List.iter (fun (model_id, _in_flight, limit) ->
    for _ = 1 to limit do Glm_pool.acquire model_id done
  ) stats;
  check bool "no capacity" false (Glm_pool.has_capacity ());
  (* select_model should still return something via round-robin *)
  let model = Glm_pool.select_model () in
  check bool "round-robin returns pool model" true (Glm_pool.is_pool_model model);
  (* cleanup *)
  let stats2 = Glm_pool.get_stats () in
  List.iter (fun (model_id, in_flight, _limit) ->
    for _ = 1 to in_flight do Glm_pool.release model_id done
  ) stats2

(* ============================================================
   acquire / release
   ============================================================ *)

let test_acquire_release () =
  reset_pool ();
  check int "initial load 0" 0 (Glm_pool.current_load ());
  Glm_pool.acquire "glm-4.5";
  check int "load after acquire" 1 (Glm_pool.current_load ());
  Glm_pool.release "glm-4.5";
  check int "load after release" 0 (Glm_pool.current_load ())

let test_acquire_non_pool_model () =
  reset_pool ();
  let load_before = Glm_pool.current_load () in
  Glm_pool.acquire "gpt-4";
  check int "non-pool acquire is no-op" load_before (Glm_pool.current_load ())

let test_release_non_pool_model () =
  reset_pool ();
  Glm_pool.release "gpt-4";
  check int "non-pool release is no-op" 0 (Glm_pool.current_load ())

let test_release_clamps_to_zero () =
  reset_pool ();
  Glm_pool.release "glm-4.5";
  check int "release clamps to 0" 0 (Glm_pool.current_load ())

(* ============================================================
   has_capacity / current_load
   ============================================================ *)

let test_has_capacity_initially () =
  reset_pool ();
  check bool "has capacity initially" true (Glm_pool.has_capacity ())

let test_current_load_multiple () =
  reset_pool ();
  Glm_pool.acquire "glm-4.5";
  Glm_pool.acquire "glm-5";
  Glm_pool.acquire "glm-4.6";
  check int "load is 3" 3 (Glm_pool.current_load ());
  Glm_pool.release "glm-4.5";
  Glm_pool.release "glm-5";
  Glm_pool.release "glm-4.6"

(* ============================================================
   get_stats
   ============================================================ *)

let test_get_stats_structure () =
  reset_pool ();
  let stats = Glm_pool.get_stats () in
  let (model_id, in_flight, limit) = List.hd stats in
  check bool "first model has name" true (String.length model_id > 0);
  check int "first model in_flight 0" 0 in_flight;
  check bool "first model limit > 0" true (limit > 0)

let test_get_stats_reflects_acquire () =
  reset_pool ();
  Glm_pool.acquire "glm-5";
  let stats = Glm_pool.get_stats () in
  let glm5_stat = List.find (fun (id, _, _) -> id = "glm-5") stats in
  let (_, in_flight, _) = glm5_stat in
  check int "glm-5 in_flight is 1" 1 in_flight;
  Glm_pool.release "glm-5"

(* ============================================================
   with_model (RAII wrapper)
   ============================================================ *)

let test_with_model_success () =
  reset_pool ();
  let result = Glm_pool.with_model None (fun model_id ->
    check bool "model is in pool" true (Glm_pool.is_pool_model model_id);
    42
  ) in
  check int "returns function result" 42 result;
  check int "released after success" 0 (Glm_pool.current_load ())

let test_with_model_exception_safety () =
  reset_pool ();
  (try
    ignore (Glm_pool.with_model None (fun _model_id ->
      failwith "test error"
    ))
  with Failure _ -> ());
  check int "released after exception" 0 (Glm_pool.current_load ())

let test_with_model_preferred () =
  reset_pool ();
  let result = Glm_pool.with_model (Some "glm-5") (fun model_id ->
    model_id
  ) in
  check string "preferred model used" "glm-5" result

let test_with_model_preferred_non_pool () =
  reset_pool ();
  let result = Glm_pool.with_model (Some "gpt-4") (fun model_id ->
    model_id
  ) in
  check string "non-pool model passed through" "gpt-4" result

(* ============================================================
   select_model_preferring
   ============================================================ *)

let test_select_model_preferring_none () =
  reset_pool ();
  let model = Glm_pool.select_model_preferring None in
  check bool "None falls back to pool" true (Glm_pool.is_pool_model model)

let test_select_model_preferring_available () =
  reset_pool ();
  let model = Glm_pool.select_model_preferring (Some "glm-4.6") in
  check string "preferred model selected" "glm-4.6" model

let test_select_model_preferring_at_capacity () =
  reset_pool ();
  (* Fill glm-4.6 to capacity (3) *)
  for _ = 1 to 3 do Glm_pool.acquire "glm-4.6" done;
  let model = Glm_pool.select_model_preferring (Some "glm-4.6") in
  check bool "falls back when at capacity" true (model <> "glm-4.6");
  for _ = 1 to 3 do Glm_pool.release "glm-4.6" done

let test_select_model_preferring_non_pool () =
  let model = Glm_pool.select_model_preferring (Some "gpt-4") in
  check string "non-pool model passed through" "gpt-4" model

(* ============================================================
   config loading (parse_model_json, hardcoded_models)
   ============================================================ *)

let test_parse_model_json_valid () =
  let json = `Assoc [
    ("model_id", `String "test-model");
    ("concurrency_limit", `Int 5);
    ("description", `String "test")
  ] in
  match Glm_pool.parse_model_json json with
  | Some m ->
      check string "model_id" "test-model" m.model_id;
      check int "concurrency_limit" 5 m.concurrency_limit;
      check string "description" "test" m.description
  | None -> fail "expected Some"

let test_parse_model_json_missing_fields () =
  let json = `Assoc [("model_id", `String "x")] in
  check bool "missing limit returns None" true
    (Glm_pool.parse_model_json json = None)

let test_parse_model_json_invalid_limit () =
  let json = `Assoc [
    ("model_id", `String "x");
    ("concurrency_limit", `Int 0)
  ] in
  check bool "zero limit returns None" true
    (Glm_pool.parse_model_json json = None)

let test_parse_model_json_no_description () =
  let json = `Assoc [
    ("model_id", `String "x");
    ("concurrency_limit", `Int 3)
  ] in
  match Glm_pool.parse_model_json json with
  | Some m -> check string "default empty description" "" m.description
  | None -> fail "expected Some"

let test_parse_model_json_float_limit () =
  let json = `Assoc [
    ("model_id", `String "x");
    ("concurrency_limit", `Float 5.0)
  ] in
  match Glm_pool.parse_model_json json with
  | Some m -> check int "float parsed as int" 5 m.concurrency_limit
  | None -> fail "expected Some for float limit"

let test_hardcoded_models_count () =
  check int "hardcoded has 7 models" 7
    (Array.length Glm_pool.hardcoded_models)

let test_hardcoded_models_total_capacity () =
  let cap = Array.fold_left
    (fun acc (m : Glm_pool.glm_model) -> acc + m.concurrency_limit) 0
    Glm_pool.hardcoded_models
  in
  check int "hardcoded total is 39" 39 cap

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  run "Glm_pool Coverage" [
    "available_models", [
      test_case "total_capacity is 39" `Quick test_total_capacity;
      test_case "7 models in pool" `Quick test_available_models_count;
    ];
    "find_model_index", [
      test_case "finds existing model" `Quick test_find_model_index_existing;
      test_case "case insensitive" `Quick test_find_model_index_case_insensitive;
      test_case "returns -1 for unknown" `Quick test_find_model_index_not_found;
      test_case "all 7 models findable" `Quick test_find_model_index_all_models;
    ];
    "is_pool_model", [
      test_case "true for pool model" `Quick test_is_pool_model_true;
      test_case "false for non-pool" `Quick test_is_pool_model_false;
      test_case "glm-4.7-flash excluded" `Quick test_is_pool_model_flash_excluded;
    ];
    "select_model", [
      test_case "returns pool model" `Quick test_select_model_returns_pool_model;
      test_case "prefers least loaded" `Quick test_select_model_prefers_least_loaded;
      test_case "round-robin at capacity" `Quick test_select_model_round_robin_fallback;
    ];
    "acquire_release", [
      test_case "acquire and release" `Quick test_acquire_release;
      test_case "non-pool acquire no-op" `Quick test_acquire_non_pool_model;
      test_case "non-pool release no-op" `Quick test_release_non_pool_model;
      test_case "release clamps to 0" `Quick test_release_clamps_to_zero;
    ];
    "has_capacity", [
      test_case "has capacity initially" `Quick test_has_capacity_initially;
    ];
    "current_load", [
      test_case "tracks multiple models" `Quick test_current_load_multiple;
    ];
    "get_stats", [
      test_case "returns structured data" `Quick test_get_stats_structure;
      test_case "reflects acquire state" `Quick test_get_stats_reflects_acquire;
    ];
    "with_model", [
      test_case "returns result" `Quick test_with_model_success;
      test_case "releases on exception" `Quick test_with_model_exception_safety;
      test_case "uses preferred model" `Quick test_with_model_preferred;
      test_case "passes non-pool through" `Quick test_with_model_preferred_non_pool;
    ];
    "select_model_preferring", [
      test_case "None uses pool" `Quick test_select_model_preferring_none;
      test_case "uses preferred" `Quick test_select_model_preferring_available;
      test_case "fallback at capacity" `Quick test_select_model_preferring_at_capacity;
      test_case "non-pool passthrough" `Quick test_select_model_preferring_non_pool;
    ];
    "config_loading", [
      test_case "parse valid JSON model" `Quick test_parse_model_json_valid;
      test_case "parse missing fields" `Quick test_parse_model_json_missing_fields;
      test_case "parse invalid limit" `Quick test_parse_model_json_invalid_limit;
      test_case "parse no description" `Quick test_parse_model_json_no_description;
      test_case "hardcoded model count" `Quick test_hardcoded_models_count;
      test_case "hardcoded total capacity" `Quick test_hardcoded_models_total_capacity;
      test_case "parse float limit" `Quick test_parse_model_json_float_limit;
    ];
  ]
