(** Runtime tool-name canonicalisation over the descriptor-owned routing table. *)

type runtime_decision_outcome =
  | Route_hit of { internal : string }
  | Already_internal of { canonical : string }
  | Miss

(** Single-SSOT entry for runtime tool-name routing.

    Runtime callers should use this typed decision when they need provenance,
    or [canonical_tool_name] / [canonical_tool_name_observed] when they only
    need the pure or telemetry-emitting string projection. *)
let runtime_decision name =
  match Keeper_tool_alias.canonical_resolution name with
  | Keeper_tool_alias.Public_name { internal } -> Route_hit { internal }
  | Keeper_tool_alias.Internal { canonical } -> Already_internal { canonical }
  | Keeper_tool_alias.Unknown -> Miss

let canonical_tool_name name =
  match runtime_decision name with
  | Route_hit { internal } -> internal
  | Already_internal { canonical } -> canonical
  | Miss -> name
;;

let canonical_tool_name_observed name =
  let stripped = Keeper_tool_alias.strip_mcp_masc_prefix name in
  match runtime_decision name with
  | Route_hit { internal } ->
    Keeper_tool_alias.record_route_outcome ~tool:stripped ~routed_to:internal ~result:"ok";
    internal
  | Already_internal { canonical } ->
    Keeper_tool_alias.record_route_outcome
      ~tool:canonical
      ~routed_to:canonical
      ~result:"ok";
    canonical
  | Miss ->
    Keeper_tool_alias.record_route_outcome ~tool:name ~routed_to:"none" ~result:"miss";
    name
;;
