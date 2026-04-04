open Types

let schemas : tool_schema list = [
  (* masc_recall_search *)
  {
    name = "masc_recall_search";
    description = "Semantic memory search across the agent's episodic memories using relevance scoring. \
Use when you need to recall past experiences, decisions, or context from previous generations. \
Returns matched memories sorted by relevance. Pair with masc_episode_list for structured queries.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("query", `Assoc [
          ("type", `String "string");
          ("description", `String "Natural language query for semantic search");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max results to return (default: 5)");
        ]);
      ]);
      ("required", `List [`String "query"]);
    ];
  };
]
