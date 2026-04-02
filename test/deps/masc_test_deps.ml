(* Shared dependency re-export for MASC test suite.
   Also hosts tiny test helpers that need a single SSOT across files. *)

let init_keeper_tool_registry () =
  if not (Masc_mcp.Tool_dispatch.is_tag_registry_initialized ()) then
    let _ = Masc_mcp.Mcp_server_eio.governance_defaults in
    ()
