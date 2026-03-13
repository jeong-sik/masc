open Types

let schemas : tool_schema list = [
  {
    name = "masc_debate_start";
    description = "Start a structured debate on a topic. Agents can take positions (support/oppose/neutral) \
and provide arguments with evidence. Use for: complex decisions, design discussions, technical debates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "The topic to debate");
        ]);
      ]);
      ("required", `List [`String "topic"]);
    ];
  };
  {
    name = "masc_debate_argue";
    description = "Add an argument to an ongoing debate. Take a position and provide your reasoning. \
Use reply_to to respond to a specific argument (ping-pong style).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID");
        ]);
        ("position", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Your position on the topic");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Your argument");
        ]);
        ("evidence", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Supporting evidence (optional)");
        ]);
        ("reply_to", `Assoc [
          ("type", `String "integer");
          ("description", `String "Index of argument to reply to (for ping-pong debate)");
        ]);
        ("mentions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Agent names to mention/notify");
        ]);
      ]);
      ("required", `List [`String "debate_id"; `String "content"]);
    ];
  };
  {
    name = "masc_debate_close";
    description = "Close a debate. No more arguments can be added.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID to close");
        ]);
      ]);
      ("required", `List [`String "debate_id"]);
    ];
  };
  {
    name = "masc_debate_status";
    description = "Get status and summary of a debate.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("debate_id", `Assoc [
          ("type", `String "string");
          ("description", `String "The debate ID");
        ]);
      ]);
      ("required", `List [`String "debate_id"]);
    ];
  };
  {
    name = "masc_debates";
    description = "List all debates (open and closed).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
