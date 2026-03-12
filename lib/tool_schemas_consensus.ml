open Types

let schemas : tool_schema list = [
  {
    name = "masc_consensus_start";
    description = "Start a voting session for consensus. Agents vote approve/reject/abstain with reasons.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic to vote on");
        ]);
        ("quorum", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum votes required (default: 2)");
        ]);
        ("threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Majority threshold 0.0-1.0 (default: 0.5)");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_consensus_vote";
    description = "Cast a vote in a consensus session.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "approve"; `String "reject"; `String "abstain"]);
          ("description", `String "Your vote");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for your vote");
        ]);
      ]);
      ("required", `List [`String "session_id"; `String "decision"]);
    ];
  };
  {
    name = "masc_consensus_close";
    description = "Close a voting session and get the result.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
      ]);
      ("required", `List [`String "session_id"]);
    ];
  };
  {
    name = "masc_consensus_result";
    description = "Get the result of a voting session (Unanimous/Majority/Deadlock/Escalate).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The voting session ID");
        ]);
      ]);
      ("required", `List [`String "session_id"]);
    ];
  };
]
