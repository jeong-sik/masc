(** Pure-function unit tests for [Dashboard_feature_health].

    Audit P2 follow-up (2026-04-29 §3.1.2) — listed as
    "테스트 완전 부재" with the recommendation
    "basic smoke test".  Closes that gap with property pins
    instead of a smoke test (richer regression coverage). *)

module H = Masc_mcp.Dashboard_feature_health
module R = Feature_flag_registry

(** Force-unset an env var around [f] so {!R.runtime_value}'s
    [Sys.getenv_opt] read does not pick up an inherited value
    from the developer's shell or another test in the same
    process (Copilot review feedback). *)
let with_env_unset name f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name "";
  let finally () =
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally f

(* ─── (1) status_to_string exhaustiveness ──────────────────────── *)

let test_status_to_string_healthy () =
  assert (H.status_to_string H.Healthy = "healthy")

let test_status_to_string_warning () =
  assert (H.status_to_string H.Warning = "warning")

let test_status_to_string_inactive () =
  assert (H.status_to_string H.Inactive = "inactive")

let test_status_to_string_deprecated () =
  assert (H.status_to_string H.Deprecated = "deprecated")

let test_status_to_string_distinct () =
  let labels =
    [ H.Healthy; H.Warning; H.Inactive; H.Deprecated ]
    |> List.map H.status_to_string
  in
  let unique = List.sort_uniq compare labels in
  assert (List.length unique = 4)

(* ─── (2) lifecycle_to_status mapping ──────────────────────────── *)

let test_lifecycle_active_maps_to_healthy () =
  assert (H.lifecycle_to_status R.Active = H.Healthy)

let test_lifecycle_experimental_maps_to_warning () =
  assert (H.lifecycle_to_status R.Experimental = H.Warning)

let test_lifecycle_deprecated_maps_to_deprecated () =
  assert (
    H.lifecycle_to_status (R.Deprecated "any reason")
    = H.Deprecated)

let test_lifecycle_deprecated_empty_reason_still_maps () =
  (* Edge: an empty deprecation reason still produces Deprecated
     status (the reason string is irrelevant for the status
     classification). *)
  assert (H.lifecycle_to_status (R.Deprecated "") = H.Deprecated)

(* ─── (3) feature_to_health_item: status derivation ──────────── *)

let dummy_flag ~env_name ~lifecycle ~default =
  {
    R.env_name;
    description = "test fixture";
    default;
    category = "runtime";
    lifecycle;
    since = "0.0.0";
  }

let test_active_enabled_is_healthy () =
  (* Active + runtime_value=true → Healthy.  Force the env var
     unset so an inherited shell value cannot flip the flag and
     break the test. *)
  let env = "MASC_TEST_HEALTH_ACTIVE_ENABLED_XYZ123" in
  with_env_unset env @@ fun () ->
  let f = dummy_flag ~env_name:env ~lifecycle:R.Active ~default:true in
  let item = H.feature_to_health_item f in
  assert (item.is_enabled = true);
  assert (item.status = H.Healthy)

let test_active_disabled_is_inactive () =
  let env = "MASC_TEST_HEALTH_ACTIVE_DISABLED_XYZ123" in
  with_env_unset env @@ fun () ->
  let f = dummy_flag ~env_name:env ~lifecycle:R.Active ~default:false in
  let item = H.feature_to_health_item f in
  assert (item.is_enabled = false);
  assert (item.status = H.Inactive)

let test_experimental_is_warning_regardless_of_enabled () =
  let env = "MASC_TEST_HEALTH_EXPERIMENTAL_XYZ123" in
  with_env_unset env @@ fun () ->
  let f =
    dummy_flag ~env_name:env ~lifecycle:R.Experimental ~default:true
  in
  let item = H.feature_to_health_item f in
  assert (item.status = H.Warning)

let test_deprecated_is_deprecated_regardless_of_enabled () =
  let env = "MASC_TEST_HEALTH_DEPRECATED_XYZ123" in
  with_env_unset env @@ fun () ->
  let f =
    dummy_flag ~env_name:env
      ~lifecycle:(R.Deprecated "use MASC_X instead") ~default:true
  in
  let item = H.feature_to_health_item f in
  assert (item.status = H.Deprecated)

let test_lifecycle_field_serialised () =
  let env = "MASC_TEST_HEALTH_LIFECYCLE_FIELD_XYZ123" in
  with_env_unset env @@ fun () ->
  let f =
    dummy_flag ~env_name:env
      ~lifecycle:(R.Deprecated "old API") ~default:false
  in
  let item = H.feature_to_health_item f in
  assert (item.lifecycle = "deprecated: old API")

(* ─── (4) get_feature_categories: distinct + sorted ─────────── *)

let test_categories_are_distinct () =
  let cats = H.get_feature_categories () in
  let unique = List.sort_uniq String.compare cats in
  assert (List.length cats = List.length unique)

let test_categories_sorted () =
  let cats = H.get_feature_categories () in
  let sorted = List.sort String.compare cats in
  assert (cats = sorted)

let test_categories_subset_of_documented () =
  (* Same documented set as Feature_flag_registry §2 invariant. *)
  let allowed =
    [ "transport"; "tool"; "keeper"; "dashboard"; "inference";
      "runtime" ]
  in
  let cats = H.get_feature_categories () in
  List.iter
    (fun c ->
      if not (List.mem c allowed) then begin
        Printf.eprintf "unexpected category %S\n" c;
        assert false
      end)
    cats

(* ─── (5) count_by_status partition ────────────────────────────── *)

let test_count_by_status_partition () =
  (* The 4 status buckets together must account for every
     feature.  Pin that
       count Healthy + count Warning + count Inactive
       + count Deprecated = total. *)
  let features = H.get_all_features () in
  let total = List.length features in
  let h = H.count_by_status features H.Healthy in
  let w = H.count_by_status features H.Warning in
  let i = H.count_by_status features H.Inactive in
  let d = H.count_by_status features H.Deprecated in
  assert (h + w + i + d = total)

let test_count_by_status_nonneg () =
  let features = H.get_all_features () in
  let h = H.count_by_status features H.Healthy in
  let w = H.count_by_status features H.Warning in
  let i = H.count_by_status features H.Inactive in
  let d = H.count_by_status features H.Deprecated in
  assert (h >= 0);
  assert (w >= 0);
  assert (i >= 0);
  assert (d >= 0)

(* ─── (6) JSON shape ──────────────────────────────────────────── *)

let test_feature_health_item_json_shape () =
  let f =
    dummy_flag ~env_name:"MASC_TEST_HEALTH_JSON_XYZ123"
      ~lifecycle:R.Active ~default:true
  in
  let item = H.feature_to_health_item f in
  let j = H.feature_health_item_to_json item in
  let expected_keys =
    [ "env_name"; "description"; "category"; "lifecycle";
      "is_enabled"; "source"; "status"; "since" ]
  in
  List.iter
    (fun k ->
      let v = Yojson.Safe.Util.member k j in
      if v = `Null then begin
        Printf.eprintf "missing field %S\n" k;
        assert false
      end)
    expected_keys

let test_overview_json_total_matches () =
  let features = H.get_all_features () in
  let j = H.overview_json features in
  let total =
    Yojson.Safe.Util.member "total_features" j
    |> Yojson.Safe.Util.to_int
  in
  assert (total = List.length features)

(* ─── runner ──────────────────────────────────────────────────── *)

let () =
  test_status_to_string_healthy ();
  test_status_to_string_warning ();
  test_status_to_string_inactive ();
  test_status_to_string_deprecated ();
  test_status_to_string_distinct ();
  test_lifecycle_active_maps_to_healthy ();
  test_lifecycle_experimental_maps_to_warning ();
  test_lifecycle_deprecated_maps_to_deprecated ();
  test_lifecycle_deprecated_empty_reason_still_maps ();
  test_active_enabled_is_healthy ();
  test_active_disabled_is_inactive ();
  test_experimental_is_warning_regardless_of_enabled ();
  test_deprecated_is_deprecated_regardless_of_enabled ();
  test_lifecycle_field_serialised ();
  test_categories_are_distinct ();
  test_categories_sorted ();
  test_categories_subset_of_documented ();
  test_count_by_status_partition ();
  test_count_by_status_nonneg ();
  test_feature_health_item_json_shape ();
  test_overview_json_total_matches ();
  print_endline
    "test_dashboard_feature_health: all assertions passed"
