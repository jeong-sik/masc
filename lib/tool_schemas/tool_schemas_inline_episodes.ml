open Types

let schemas : tool_schema list = [
  (* masc_episode_flush *)
  {
    name = "masc_episode_flush";
    description = "Flush locally queued episodes to Neo4j (graph) and PostgreSQL (relational) persistent storage. \
Use when episodes have been queued during agent handoff and need to be persisted. \
Returns flushed/failed/pending counts. Pair with masc_episode_list to verify stored episodes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max episodes to flush per call (default: 10)");
        ]);
        ("dry_run", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Preview without saving to DB (default: false)");
        ]);
      ]);
    ];
  };

  (* masc_episode_list *)
  {
    name = "masc_episode_list";
    description = "List recent agent episodes from PostgreSQL with optional filters by agent_name and generation. \
Use when debugging agent lineage, reviewing past actions, or understanding generational history. \
Pair with masc_episode_flush to ensure episodes are persisted before querying.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("generation", `Assoc [
          ("type", `String "integer");
          ("description", `String "Filter by generation number (optional)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max results (default: 20)");
        ]);
      ]);
    ];
  };

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
