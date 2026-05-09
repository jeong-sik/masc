(* RFC-0055: Capability-tier monotonicity for cascade fallback chains.

   A fallback edge source -> target is valid only if the target's
   capability profile is a superset of the source's profile.  This
   module provides the subset check used at config-load time. *)

open Cascade_capability_profile

let requirement_leq a b =
  match a, b with
  | Optional, _ -> true
  | Required, Required -> true
  | Required, Optional -> false

let is_subset_profile src dst =
  let s = required_capabilities_of src in
  let d = required_capabilities_of dst in
  requirement_leq s.inline_tools d.inline_tools
  && requirement_leq s.inline_tool_choice d.inline_tool_choice
  && requirement_leq s.runtime_mcp_tools d.runtime_mcp_tools
  && requirement_leq s.runtime_tool_events d.runtime_tool_events
  && requirement_leq s.runtime_mcp_http_headers d.runtime_mcp_http_headers
