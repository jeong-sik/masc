(** Keeper_turn_driver_helpers — pure helper functions extracted from
    [Keeper_turn_driver].

    These are top-level pure functions (no closures over outer state)
    that compute provider-attempt timeout bounds, health-key derivations,
    lane labels, etc. Lifting them out of the 1459-LOC
    [keeper_turn_driver.ml] is a foundation step toward the eventual
    A/B/C decomposition (Agent SDK call / runtime strategy / keeper
    bookkeeping) deferred from RFC-0047 Phase 4.

    No behavior change. Mechanical extraction.

    @since RFC-0048 — keeper_turn_driver split, helpers slice *)

(* RFC-0206: provider_rejections_for_no_tool_error deleted — multi-candidate
   tool-filter rejection lists have no meaning under single-runtime dispatch. *)

let checkpoint_after_attempt ?agent_ref = function
  | Some agent ->
      (match agent_ref with Some r -> r := Some agent | None -> ());
      Some (Agent_sdk.Agent.checkpoint agent)
  | None -> None
