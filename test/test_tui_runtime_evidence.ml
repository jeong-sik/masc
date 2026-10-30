open Alcotest
module Evidence = Masc_tui_runtime_evidence
let row id ~cached = `Assoc [
  "runtime_id", `String id; "entry_count", `Int 2; "success_count", `Int 1;
  "error_count", `Int 1; "usage_sample_count", `Int 1; "telemetry_sample_count", `Int 0;
  "cached_input", cached; "total_cost_usd", `Null;
  "recent_entries", `List [`Assoc ["ts_unix", `Float 1000.; "outcome", `String "success";
    "input_tokens", `Int 100; "output_tokens", `Null]]]
let cache = `Assoc ["input_tokens", `Int 100; "cache_read_tokens", `Int 0; "sample_count", `Int 1]
let payload rows = `Assoc [
  "specifications", `List [`Assoc ["runtime_id", `String "account-one.model";
    "catalog_context", `Null; "catalog_max_output", `Null; "model_context", `Int 272000;
    "provider_context", `Null; "binding_context", `Int 500000]];
  "history", `Assoc ["state", `String "ready"; "window_minutes", `Int 1440; "observed_at", `Float 1234.;
    "unattributed_entries", `Int 7; "runtimes", `List rows;
    "cache", `Assoc ["state", `String "stale_refreshing"; "generated_at", `Float 1234.];
    "cost_read", `Assoc ["state", `String "unavailable"]]]
let read json = match Evidence.decode json with Ok value -> value | Error detail -> fail detail
let value label lines = List.assoc label lines
let contains text part =
  let length = String.length part in
  let rec loop at = at + length <= String.length text
    && (String.sub text at length = part || loop (at + 1)) in loop 0
let reject_bad_coverage () =
  let bad = `Assoc ["input_tokens", `Int 100; "cache_read_tokens", `Int 101; "sample_count", `Int 1] in
  check bool "cache cannot exceed inclusive input" true (Result.is_error (Evidence.decode (payload [row "one" ~cached:bad])));
  check bool "duplicate runtime identity is refused" true
    (Result.is_error (Evidence.decode (payload [row "one" ~cached:cache; row "one" ~cached:cache])))
let replace_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> fail "expected object fixture"
let map_field key f json = replace_field key (f (Yojson.Safe.Util.member key json)) json
let recent_outcomes () =
  List.iter (fun (outcome, label) ->
    let runtime = row "one" ~cached:cache |> map_field "recent_entries" (function
      | `List entries -> `List (List.map (replace_field "outcome" (`String outcome)) entries)
      | _ -> fail "expected recent entries") in
    let lines = Evidence.lines (read (payload [runtime])) ~runtime_id:"one" in
    check bool "non-error outcome is shown without claiming completion" true
      (contains (value "Last non-error turn" lines) label);
    check bool "recent entry retains its outcome" true
      (contains (value "Recent non-error turn" lines) label))
    ["success", "completed"; "checkpoint", "checkpoint"; "input_required", "input required"];
  let bad = row "one" ~cached:cache |> map_field "recent_entries" (function
    | `List entries -> `List (List.map (replace_field "outcome" (`String "error")) entries)
    | _ -> fail "expected recent entries") in
  check bool "error is not accepted as a recent non-error turn" true
    (Result.is_error (Evidence.decode (payload [bad])))
let invalid_dates () =
  let baseline = payload [row "one" ~cached:cache] in
  let bad_recent = row "one" ~cached:cache |> map_field "recent_entries" (function
    | `List entries -> `List (List.map (replace_field "ts_unix" (`Float 1e300)) entries)
    | _ -> fail "expected recent entries") in
  List.iter (fun json ->
    check bool "platform-unrenderable dates fail before rendering" true
      (Result.is_error (Evidence.decode json)))
    [payload [bad_recent]; baseline |> map_field "history" (replace_field "observed_at" (`Float 1e300))]

let () = run "TUI runtime evidence" ["operator reading", [
  test_case "checkpoint and input-required outcomes retain their meaning" `Quick recent_outcomes;
  test_case "unrenderable timestamps fail decoding" `Quick invalid_dates;
  test_case "invalid sample coverage" `Quick reject_bad_coverage]]
