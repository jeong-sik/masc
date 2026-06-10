open Alcotest
module F = Keeper_sandbox_factory_failure

let test_registry_lookup () =
  let e = Failure "registry: keeper 'agent-42' not found" in
  match F.classify_error e with
  | F.Registry_lookup msg ->
    check string "registry msg" "registry: keeper 'agent-42' not found" msg
  | other -> fail ("expected Registry_lookup, got " ^ F.to_string other)
;;

let test_sandbox_profile_resolution () =
  let e = Failure "effective_sandbox: no matching profile for tier" in
  match F.classify_error e with
  | F.Sandbox_profile_resolution _ -> ()
  | other -> fail ("expected Sandbox_profile_resolution, got " ^ F.to_string other)
;;

let test_runtime_image_missing () =
  let e = Failure "keeper sandbox docker image is not configured" in
  match F.classify_error e with
  | F.Runtime_image_missing _ -> ()
  | other -> fail ("expected Runtime_image_missing, got " ^ F.to_string other)
;;

let test_runtime_creation () =
  let e = Failure "runtime create: docker run failed: OOM" in
  match F.classify_error e with
  | F.Runtime_creation _ -> ()
  | other -> fail ("expected Runtime_creation, got " ^ F.to_string other)
;;

let test_cwd_normalization () =
  let e = Failure "normalize_path: invalid root" in
  match F.classify_error e with
  | F.Cwd_normalization _ -> ()
  | other -> fail ("expected Cwd_normalization, got " ^ F.to_string other)
;;

let test_cwd_projection () =
  let e = Failure "profile_independent_cwd: unexpected abs path" in
  match F.classify_error e with
  | F.Cwd_projection _ -> ()
  | other -> fail ("expected Cwd_projection, got " ^ F.to_string other)
;;

let test_cache_cleanup () =
  let e = Failure "cleanup: container teardown timeout" in
  match F.classify_error e with
  | F.Cache_cleanup _ -> ()
  | other -> fail ("expected Cache_cleanup, got " ^ F.to_string other)
;;

let test_internal_fallback () =
  let e = Not_found in
  match F.classify_error e with
  | F.Internal _ -> ()
  | other -> fail ("expected Internal, got " ^ F.to_string other)
;;

let test_to_string_labels () =
  check string "Registry_lookup"
    "registry_lookup:x" (F.to_string (F.Registry_lookup "x"));
  check string "Sandbox_profile_resolution"
    "sandbox_profile_resolution:x" (F.to_string (F.Sandbox_profile_resolution "x"));
  check string "Runtime_image_missing"
    "runtime_image_missing:x" (F.to_string (F.Runtime_image_missing "x"));
  check string "Runtime_creation"
    "runtime_creation:x" (F.to_string (F.Runtime_creation "x"));
  check string "Cwd_normalization"
    "cwd_normalization:x" (F.to_string (F.Cwd_normalization "x"));
  check string "Cwd_projection"
    "cwd_projection:x" (F.to_string (F.Cwd_projection "x"));
  check string "Cache_cleanup"
    "cache_cleanup:x" (F.to_string (F.Cache_cleanup "x"));
  check string "Internal"
    "internal:x" (F.to_string (F.Internal "x"))
;;

let () =
  run "keeper_sandbox_factory_failure"
    [ ("classification",
      [ test_case "registry lookup classifies" `Quick test_registry_lookup;
        test_case "sandbox profile resolution classifies" `Quick test_sandbox_profile_resolution;
        test_case "runtime image missing classifies" `Quick test_runtime_image_missing;
        test_case "runtime creation classifies" `Quick test_runtime_creation;
        test_case "cwd normalization classifies" `Quick test_cwd_normalization;
        test_case "cwd projection classifies" `Quick test_cwd_projection;
        test_case "cache cleanup classifies" `Quick test_cache_cleanup;
        test_case "unknown exceptions fall back to Internal" `Quick test_internal_fallback;
      ]);
      ("label_format",
      [ test_case "to_string labels match variants" `Quick test_to_string_labels;
      ]);
    ]