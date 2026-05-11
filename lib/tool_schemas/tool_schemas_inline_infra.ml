open Masc_domain

(** Issue #8520: hand-mirrored from [Mcp_session.valid_action_strings].
    [masc_tool_schemas] only depends on [masc_types], so it cannot
    derive directly. The sync regression test in [test_types.ml ::
    mcp_session_action_ssot] catches drift. Same shape as
    #8467/#8480/#8484/#8490/#8493/#8506/#8513 mirror+sync pattern. *)
let mcp_session_action_enum_strings =
  [ "get"; "create"; "list"; "cleanup"; "remove" ]

(* RFC-0057 PR-2c: masc_approval_pending, masc_approval_get, masc_spawn
   moved to codegen (Tool_descriptors_gen via Tool_schemas_misc.schemas).
   masc_mcp_session remains here because its [action] enum is locked
   to [mcp_session_action_enum_strings] above by the SSOT regression
   test; codegen needs a shared enum source RFC before it can swap. *)
let schemas : tool_schema list = [
  (* masc_mcp_session *)
  {
    name = "masc_mcp_session";
    description = "Create, get, list, or remove MCP sessions that track client context across requests. \
Use when managing multi-request workflows that need session continuity (Mcp-Session-Id header). \
Pair with masc_subscription to receive session-scoped event notifications.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          (* Issue #8520: derive from local mirror tracking
             [Mcp_session.valid_action_strings]. *)
          ("enum", `List (List.map (fun s -> `String s) mcp_session_action_enum_strings));
          ("description", `String "Session action");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Session ID (for get/remove)");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (for create)");
        ]);
      ]);
      ("required", `List [`String "action"]);
      ("additionalProperties", `Bool false);
    ];
  };
]
