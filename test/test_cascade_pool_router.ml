open Alcotest
module H = Masc_mcp.Cascade_health_tracker
module Pool = Masc_mcp.Cascade_pool
module Router = Masc_mcp.Cascade_pool_router

let check_strings = check (list string)

let test_parse_provider_list_env_edges () =
  let default = [ "default" ] in
  check_strings
    "unset uses default"
    default
    (Router.For_testing.parse_provider_list_value ~default None);
  check_strings
    "empty override is empty list"
    []
    (Router.For_testing.parse_provider_list_value ~default (Some ""));
  check_strings
    "whitespace override is empty list"
    []
    (Router.For_testing.parse_provider_list_value ~default (Some "   "));
  check_strings
    "filters empty comma elements"
    [ "openai"; "glm" ]
    (Router.For_testing.parse_provider_list_value ~default (Some " openai,, glm, "))
;;

let test_empty_env_override_rejected_by_pool_create () =
  let default = [ "default" ] in
  let empty = Router.For_testing.parse_provider_list_value ~default (Some "") in
  check_raises
    "empty override rejected by pool create"
    (Invalid_argument
       "Cascade_pool.create: provider_keys must not be empty for Tier1 pool")
    (fun () -> ignore (Pool.create Pool.Tier1 ~provider_keys:empty))
;;

let find_pool router id = Router.pools router |> List.find (fun pool -> Pool.id pool = id)

let cooldown_provider pool provider_key =
  H.record_hard_quota (Pool.health_tracker pool) ~provider_key ()
;;

let cooldown_all pool = Pool.provider_keys pool |> List.iter (cooldown_provider pool)

let test_emergency_pool_activates_after_primary_tiers_cooldown () =
  let router =
    Router.For_testing.create_from_provider_keys
      ~tier1_keys:[ "tier1-a" ]
      ~tier2_keys:[ "tier2-a" ]
      ~emergency_keys:[ "emergency-a" ]
  in
  cooldown_all (find_pool router Pool.Tier1);
  cooldown_all (find_pool router Pool.Tier2);
  let seen = ref [] in
  match
    Router.execute_with_fallback router ~keeper_name:"keeper" (fun ~provider_key ->
      seen := provider_key :: !seen;
      Ok provider_key)
  with
  | Ok provider ->
    check string "emergency provider selected" "emergency-a" provider;
    check_strings "only emergency attempted" [ "emergency-a" ] (List.rev !seen)
  | Error (`All_pools_exhausted reasons) ->
    fail ("expected emergency fallback, got exhausted: " ^ String.concat "; " reasons)
;;

let () =
  run
    "cascade_pool_router"
    [ ( "provider_list"
      , [ test_case "env override edge cases" `Quick test_parse_provider_list_env_edges
        ; test_case
            "empty override rejected by pool create"
            `Quick
            test_empty_env_override_rejected_by_pool_create
        ] )
    ; ( "fallback"
      , [ test_case
            "emergency activates after primary tiers cooldown"
            `Quick
            test_emergency_pool_activates_after_primary_tiers_cooldown
        ] )
    ]
;;
