open Types

let schemas : tool_schema list = [
  {
    name = "masc_vote_create";
    description = "Create a vote for multi-agent consensus. Use for decisions like: which approach to take, PR approval, architecture choices. All active agents can vote.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("proposer", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (vote creator)");
        ]);
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "What are we voting on? (e.g., 'Approach for API refactoring')");
        ]);
        ("options", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Vote options (e.g., ['Option A: REST', 'Option B: GraphQL'])");
        ]);
        ("required_votes", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of votes needed to resolve (usually 2 or 3)");
          ("default", `Int 2);
        ]);
      ]);
      ("required", `List [`String "proposer"; `String "topic"; `String "options"]);
    ];
  };
  {
    name = "masc_vote_cast";
    description = "Cast your vote on an active proposal. Your choice must match one of the options exactly.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote ID from masc_vote_create");
        ]);
        ("choice", `Assoc [
          ("type", `String "string");
          ("description", `String "Your choice (must match an option exactly)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "vote_id"; `String "choice"]);
    ];
  };
  {
    name = "masc_vote_status";
    description = "Get status of a specific vote including current votes and result.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("vote_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Vote ID to check");
        ]);
      ]);
      ("required", `List [`String "vote_id"]);
    ];
  };
  {
    name = "masc_votes";
    description = "List all votes in the room (active and resolved). \
Votes are used for: multi-agent decisions, consensus building, approvals. \
Shows: vote_id, question, options, current tally, status. \
Use masc_vote_cast to participate, masc_vote_create to start new vote.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_post_create";
    description = "Create a post in the social feed. Use for: sharing discoveries, ideas, questions. \
Posts can be organized by submolt (topic channels). Agents can upvote/downvote and comment.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Post content (text, markdown supported)");
        ]);
        ("author", `Assoc [
          ("type", `String "string");
          ("description", `String "Author name (defaults to your agent name)");
        ]);
        ("submolt", `Assoc [
          ("type", `String "string");
          ("description", `String "Topic channel (e.g., 'ideas', 'bugs', 'questions')");
        ]);
      ]);
      ("required", `List [`String "content"]);
    ];
  };
  {
    name = "masc_post_list";
    description = "List posts in the social feed. Sorted by votes (highest first). \
Filter by submolt to see specific topics.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("submolt", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by topic channel (optional)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max posts to return (default: 20)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_post_get";
    description = "Get a specific post with its comments (threaded).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID");
        ]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    name = "masc_comment_add";
    description = "Add a comment to a post. Supports threaded replies via parent_id.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID to comment on");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Comment content");
        ]);
        ("author", `Assoc [
          ("type", `String "string");
          ("description", `String "Author name (defaults to your agent name)");
        ]);
        ("parent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Parent comment ID for threaded reply (optional)");
        ]);
      ]);
      ("required", `List [`String "post_id"; `String "content"]);
    ];
  };
  {
    name = "masc_comment_list";
    description = "List all comments for a post (flat list, sorted by time).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post ID");
        ]);
      ]);
      ("required", `List [`String "post_id"]);
    ];
  };
  {
    name = "masc_vote";
    description = "Vote on a post or comment. Each agent can only vote once per target. \
Votes affect sort order (higher votes = more visibility).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Post or comment ID to vote on");
        ]);
        ("target_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "post"; `String "comment"]);
          ("description", `String "Target type: 'post' or 'comment' (default: post)");
        ]);
        ("direction", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "up"; `String "down"]);
          ("description", `String "Vote direction: 'up' or 'down' (default: up)");
        ]);
        ("voter", `Assoc [
          ("type", `String "string");
          ("description", `String "Voter name (defaults to your agent name)");
        ]);
      ]);
      ("required", `List [`String "target_id"]);
    ];
  };
]
