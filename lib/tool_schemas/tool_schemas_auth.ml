open Types

let schemas : tool_schema list = [
  {
    name = "masc_auth_enable";
    description = "Enable authentication for this room and return a room secret.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("require_token", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, all actions require a valid token. If false, tokens are optional but provide elevated permissions.");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
  {
    name = "masc_auth_disable";
    description = "Disable authentication for this room, allowing all agents unrestricted access.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_auth_status";
    description = "Check the current authentication configuration (enabled, require_token, default_role).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_auth_create_token";
    description = "Create a new authentication token for an agent with a specified role (reader, worker, admin).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to create token for");
        ]);
        ("role", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "reader"; `String "worker"; `String "admin"]);
          ("description", `String "Agent role: reader (read-only), worker (claim/lock/broadcast), admin (full access)");
          ("default", `String "worker");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_auth_refresh";
    description = "Refresh an expired or soon-to-expire token, returning a new one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("token", `Assoc [
          ("type", `String "string");
          ("description", `String "Your current token");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "token"]);
    ];
  };
  {
    name = "masc_auth_revoke";
    description = "Revoke an agent's authentication token, requiring them to obtain a new one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name whose token to revoke");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_auth_list";
    description = "List all agent credentials including names, roles, and token expiry times (admin only).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
