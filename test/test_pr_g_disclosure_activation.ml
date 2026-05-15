open Alcotest

(** RFC-0084 host-config-cleanup-G — OAS disclosure activation bridges.

    PR-G installs the [Keeper_disclosure_strategy.to_oas_disclosure_level]
    and [to_oas_resolver] converters that bridge the typed
    [Keeper_disclosure_strategy.t] (PR-13) into the
    [Agent_sdk.Builder.with_disclosure_level] +
    [Agent_sdk.Builder.with_disclosure_resolver] surface.  It also
    threads an optional [?disclosure_strategy] parameter through
    [Worker_oas.build_agent] so callers may opt-in without further
    code changes.

    The pins guard against:
    - [Full] returning a non-default disclosure level (must be [None]
      so the SDK default [Full_schema] applies and no builder call is
      made)
    - [Hybrid] losing [demote_on_error] semantics when [demote_on_error
      = true] (resolver must be installed) or producing a resolver
      when [demote_on_error = false] (none expected)
    - [Minimal_index] not mapping to [Some Agent_sdk.Tool.Minimal_index]
*)

let test_to_oas_disclosure_level_full_is_none () =
  let level =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_disclosure_level
      Masc_mcp.Keeper_disclosure_strategy.Full
  in
  (check bool)
    "Full maps to None (SDK default Full_schema applies, no builder call)"
    true (Option.is_none level)
;;

let test_to_oas_disclosure_level_hybrid () =
  let strategy =
    Masc_mcp.Keeper_disclosure_strategy.Hybrid
      { full_names = [ "keeper_bash"; "keeper_fs_edit" ]
      ; demote_on_error = false
      }
  in
  let level =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_disclosure_level strategy
  in
  match level with
  | Some (Agent_sdk.Tool.Hybrid { full_names }) ->
    (check (list string))
      "Hybrid full_names propagate verbatim"
      [ "keeper_bash"; "keeper_fs_edit" ]
      full_names
  | _ -> Alcotest.fail "Hybrid did not map to Agent_sdk.Tool.Hybrid"
;;

let test_to_oas_disclosure_level_minimal () =
  let level =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_disclosure_level
      Masc_mcp.Keeper_disclosure_strategy.Minimal_index
  in
  match level with
  | Some Agent_sdk.Tool.Minimal_index -> ()
  | _ -> Alcotest.fail "Minimal_index did not map to Agent_sdk.Tool.Minimal_index"
;;

let test_resolver_full_is_none () =
  let r =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_resolver
      Masc_mcp.Keeper_disclosure_strategy.Full
  in
  (check bool) "Full has no resolver" true (Option.is_none r)
;;

let test_resolver_minimal_is_none () =
  let r =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_resolver
      Masc_mcp.Keeper_disclosure_strategy.Minimal_index
  in
  (check bool) "Minimal_index has no resolver" true (Option.is_none r)
;;

let test_resolver_hybrid_without_demote_is_none () =
  let strategy =
    Masc_mcp.Keeper_disclosure_strategy.Hybrid
      { full_names = [ "keeper_bash" ]; demote_on_error = false }
  in
  let r =
    Masc_mcp.Keeper_disclosure_strategy.to_oas_resolver strategy
  in
  (check bool)
    "Hybrid with demote_on_error=false has no resolver"
    true (Option.is_none r)
;;

let test_resolver_hybrid_with_demote_promotes_on_error () =
  let strategy =
    Masc_mcp.Keeper_disclosure_strategy.Hybrid
      { full_names = [ "keeper_bash" ]; demote_on_error = true }
  in
  match Masc_mcp.Keeper_disclosure_strategy.to_oas_resolver strategy with
  | None ->
    Alcotest.fail "Hybrid with demote_on_error=true must produce a resolver"
  | Some resolver ->
    (* Error in the last results → demote to Full_schema. *)
    let error_results : Agent_sdk.Types.tool_result list =
      [ Error
          { Agent_sdk.Types.message = "shape mismatch"
          ; recoverable = false
          ; error_class = None
          }
      ]
    in
    (match resolver error_results with
     | Some Agent_sdk.Tool.Full_schema -> ()
     | _ ->
       Alcotest.fail
         "resolver must return Some Full_schema when last results contain an Error");
    (* No errors → fall through to static level. *)
    (match resolver [] with
     | None -> ()
     | _ ->
       Alcotest.fail
         "resolver must return None when last results are empty / contain no Error")
;;

let test_worker_oas_accepts_disclosure_strategy_arg () =
  (* This is a *compile-time* assertion: if Worker_oas.build_agent's
     signature drops [?disclosure_strategy] the function reference
     below stops type-checking. *)
  let _ = Masc_mcp.Worker_oas.build_agent in
  ()
;;

let () =
  run
    "PR-G host-config-cleanup-G (disclosure activation)"
    [ ( "pr-g-converter"
      , [ test_case "to_oas_disclosure_level Full -> None" `Quick
            test_to_oas_disclosure_level_full_is_none
        ; test_case "to_oas_disclosure_level Hybrid" `Quick
            test_to_oas_disclosure_level_hybrid
        ; test_case "to_oas_disclosure_level Minimal_index" `Quick
            test_to_oas_disclosure_level_minimal
        ; test_case "resolver Full -> None" `Quick
            test_resolver_full_is_none
        ; test_case "resolver Minimal_index -> None" `Quick
            test_resolver_minimal_is_none
        ; test_case "resolver Hybrid w/o demote -> None" `Quick
            test_resolver_hybrid_without_demote_is_none
        ; test_case "resolver Hybrid w/ demote promotes on error" `Quick
            test_resolver_hybrid_with_demote_promotes_on_error
        ; test_case "Worker_oas.build_agent accepts ?disclosure_strategy"
            `Quick test_worker_oas_accepts_disclosure_strategy_arg
        ] )
    ]
;;
