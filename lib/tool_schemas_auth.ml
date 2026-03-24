open Types

let schemas : tool_schema list = [
  {
    name = "masc_auth_enable";
    description = "Enable authentication for this room and return a room secret for authorized agents. \
Use when setting up a production room that needs access control. \
After enabling, create tokens with masc_auth_create_token; check state with masc_auth_status.";
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
    description = "Disable authentication for this room, allowing all agents unrestricted access. \
Use when reverting to development mode or troubleshooting auth issues. \
Pair with masc_auth_status to confirm auth is off.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_auth_status";
    description = "Check the current authentication configuration for this room (enabled, require_token, default_role). \
Use when verifying auth state before performing privileged operations. \
Pair with masc_auth_enable or masc_auth_disable to change settings.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_auth_create_token";
    description = "Create a new authentication token for an agent with a specified role (reader, worker, admin). \
Use when onboarding a new agent to an auth-enabled room. \
After masc_auth_enable; the token should be passed in subsequent requests.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to create token for");
        ]);
        ("role", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent role: 'reader' (read-only), 'worker' (can claim/lock/broadcast), 'admin' (full access)");
          ("default", `String "worker");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_auth_refresh";
    description = "Refresh an expired or soon-to-expire token, returning a new one. \
Use when your current token is about to expire and you need continued access. \
After masc_auth_create_token issued the original token.";
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
    description = "Revoke an agent's authentication token, requiring them to obtain a new one. \
Use when removing an agent's access or rotating compromised credentials. \
Pair with masc_auth_create_token to issue a replacement if needed.";
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
    description = "List all agent credentials including names, roles, and token expiry times (admin only). \
Use when auditing who has access to the room and their permission levels. \
Pair with masc_auth_revoke to remove stale credentials.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
