open Types

let schemas : tool_schema list = [
  (* masc_convo_start *)
  {
    name = "masc_convo_start";
    description = "Start a persistent conversation thread on a topic and return a thread_id for subsequent replies. \
Use when agents need structured multi-turn discussion on a decision or design question. \
Follow up with masc_convo_reply to add turns; end with masc_convo_conclude.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("topic", `Assoc [
          ("type", `String "string");
          ("description", `String "Conversation topic or question");
        ]);
        ("initiator", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name starting the conversation");
        ]);
        ("initial_content", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional opening message");
        ]);
        ("max_turns", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum turns allowed (default: 50)");
          ("default", `Int 50);
        ]);
        ("post_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Board post ID to link this thread to (bidirectional: thread.source_post_id ↔ post.thread_id)");
        ]);
      ]);
      ("required", `List [`String "topic"; `String "initiator"]);
    ];
  };

  (* masc_convo_reply *)
  {
    name = "masc_convo_reply";
    description = "Add a reply to an existing conversation thread with built-in loop prevention (blocks repeated messages and cooldown violations). \
Use when contributing to an ongoing multi-agent discussion. \
After masc_convo_start creates a thread; before masc_convo_conclude closes it.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("thread_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Thread ID from masc_convo_start");
        ]);
        ("speaker", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name adding the reply");
        ]);
        ("content", `Assoc [
          ("type", `String "string");
          ("description", `String "Reply message content");
        ]);
        ("confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Speaker's confidence level (0.0-1.0)");
        ]);
        ("reply_to", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional turn ID being replied to");
        ]);
        ("mentions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Agents @mentioned in this reply");
        ]);
      ]);
      ("required", `List [`String "thread_id"; `String "speaker"; `String "content"]);
    ];
  };

  (* masc_convo_conclude *)
  {
    name = "masc_convo_conclude";
    description = "Close a conversation thread with a final summary or decision, marking it as Concluded (no further replies allowed). \
Use when the discussion has reached consensus or a decision point. \
After masc_convo_reply turns are complete; pair with masc_convo_get to review the full thread.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("thread_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Thread ID to conclude");
        ]);
        ("concluder", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent writing the conclusion");
        ]);
        ("conclusion", `Assoc [
          ("type", `String "string");
          ("description", `String "Final summary or decision text");
        ]);
      ]);
      ("required", `List [`String "thread_id"; `String "concluder"; `String "conclusion"]);
    ];
  };

  (* masc_convo_get *)
  {
    name = "masc_convo_get";
    description = "Retrieve a conversation thread by ID with all turns, participants, and status. \
Use when reviewing discussion history or checking thread state before replying. \
Pair with masc_convo_list to find thread IDs.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("thread_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Thread ID to retrieve");
        ]);
      ]);
      ("required", `List [`String "thread_id"]);
    ];
  };

  (* masc_convo_list *)
  {
    name = "masc_convo_list";
    description = "List all active conversation threads in the current room. \
Use when looking for ongoing discussions to join or finding a thread_id. \
Pair with masc_convo_get to read a specific thread.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
]
