(** Tool_compact — Standalone MCP tool for context compaction.

    Exposes the OAS-backed compaction pipeline as a general-purpose
    MCP tool. Any agent can send text + strategy and receive compacted
    text back with token savings statistics.

    Tool: masc_compact_context
    - Input:  messages (JSON array of {role, content}), strategy (string)
    - Output: compacted messages + token statistics

    @since 2.95.0 — Issue #1441 *)

(* ================================================================ *)
(* Tool Schema                                                      *)
(* ================================================================ *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_compact_context";
    description = "Apply context compaction strategies to a message list. \
Returns compacted messages with token savings statistics. \
Strategies: 'prune_tool_outputs' (truncate verbose tool results), \
'merge_contiguous' (merge consecutive same-role messages), \
'drop_low_importance' (remove low-scored messages), \
 'summarize_old' (summarize old text and mask old tool outputs with structured stubs), \
'all' (apply all strategies in order).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("messages", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("role", `Assoc [
                ("type", `String "string");
                ("enum", `List [`String "system"; `String "user";
                                `String "assistant"; `String "tool"]);
              ]);
              ("content", `Assoc [
                ("type", `String "string");
              ]);
            ]);
            ("required", `List [`String "role"; `String "content"]);
          ]);
          ("description", `String "Array of messages to compact. \
Each message has 'role' (system/user/assistant/tool) and 'content' (string).");
        ]);
        ("strategy", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "prune_tool_outputs";
            `String "merge_contiguous";
            `String "drop_low_importance";
            `String "summarize_old";
            `String "all";
          ]);
          ("description", `String "Compaction strategy to apply. \
'all' applies all strategies in order of increasing aggressiveness.");
        ]);
        ("max_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max context window size for ratio calculation (default: 128000)");
        ]);
        ("system_prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "System prompt to include in token counting (default: empty)");
        ]);
      ]);
      ("required", `List [`String "messages"; `String "strategy"]);
    ];
  };
]

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type result = bool * string

(* ================================================================ *)
(* Helpers                                                          *)
(* ================================================================ *)

let role_of_string = function
  | "system" -> Agent_sdk.Types.System
  | "user" -> Agent_sdk.Types.User
  | "assistant" -> Agent_sdk.Types.Assistant
  | "tool" -> Agent_sdk.Types.Tool
  | unknown ->
    Log.Misc.warn "tool_compact: unknown role %S, defaulting to User" unknown;
    Agent_sdk.Types.User

let string_of_role = function
  | Agent_sdk.Types.System -> "system"
  | Agent_sdk.Types.User -> "user"
  | Agent_sdk.Types.Assistant -> "assistant"
  | Agent_sdk.Types.Tool -> "tool"

let strategies_of_string = function
  | "prune_tool_outputs" -> Ok [Context_compact_oas.PruneToolOutputs]
  | "merge_contiguous" -> Ok [Context_compact_oas.MergeContiguous]
  | "drop_low_importance" -> Ok [Context_compact_oas.DropLowImportance]
  | "summarize_old" -> Ok [Context_compact_oas.SummarizeOld]
  | "all" -> Ok [
      Context_compact_oas.PruneToolOutputs;
      Context_compact_oas.MergeContiguous;
      Context_compact_oas.DropLowImportance;
      Context_compact_oas.SummarizeOld;
    ]
  | s -> Error (Printf.sprintf "Unknown strategy: %s. Valid: prune_tool_outputs, merge_contiguous, drop_low_importance, summarize_old, all" s)

(** Parse a JSON message object into an Agent_sdk.Types.message. *)
let parse_message (json : Yojson.Safe.t) : Agent_sdk.Types.message =
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string |> role_of_string in
  let content = json |> member "content" |> to_string in
  match role with
  | Agent_sdk.Types.Tool ->
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.ToolResult { tool_use_id = "compact"; content; is_error = false; json = None }]; name = None; tool_call_id = None }
  | _ ->
    { Agent_sdk.Types.role; content = [Agent_sdk.Types.Text content]; name = None; tool_call_id = None }

(** Serialize an Agent_sdk.Types.message back to JSON. *)
let message_to_json (m : Agent_sdk.Types.message) : Yojson.Safe.t =
  `Assoc [
    ("role", `String (string_of_role m.role));
    ("content", `String (Agent_sdk.Types.text_of_message m));
  ]

(* ================================================================ *)
(* Handler                                                          *)
(* ================================================================ *)

let handle_compact args : result =
  try
    let open Yojson.Safe.Util in
    let messages_json = args |> member "messages" |> to_list in
    let strategy_str = args |> member "strategy" |> to_string in
    let max_tokens =
      (try args |> member "max_tokens" |> to_int
       with Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "handle_compact: max_tokens parse failed (%s), using 128000"
           (Printexc.to_string exn);
         128_000) in
    let system_prompt =
      (try args |> member "system_prompt" |> to_string
       with Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "handle_compact: system_prompt parse failed (%s), using empty"
           (Printexc.to_string exn);
         "") in
    let strategies = match strategies_of_string strategy_str with
      | Ok s -> s
      | Error msg -> raise (Invalid_argument msg)
    in
    let messages = List.map parse_message messages_json in
    (* Build a working_context from the input *)
    let ctx = Keeper_exec_context.create ~system_prompt ~max_tokens in
    let ctx = Keeper_exec_context.append_many ctx messages in
    let tokens_before = Keeper_exec_context.token_count ctx in
    let msg_count_before = List.length ctx.messages in
    (* Apply compaction *)
    let messages =
      Context_compact_oas.compact
        ~system_prompt:ctx.system_prompt
        ~messages:ctx.messages
        ~strategies
        ()
    in
    let compacted = Keeper_exec_context.sync_oas_context { ctx with messages } in
    let tokens_after = Keeper_exec_context.token_count compacted in
    let msg_count_after = List.length compacted.messages in
    let result_json = `Assoc [
      ("success", `Bool true);
      ("tokens_before", `Int tokens_before);
      ("tokens_after", `Int tokens_after);
      ("tokens_saved", `Int (tokens_before - tokens_after));
      ("messages_before", `Int msg_count_before);
      ("messages_after", `Int msg_count_after);
      ("context_ratio", `Float (Keeper_exec_context.context_ratio compacted));
      ("strategy", `String strategy_str);
      ("messages", `List (List.map message_to_json compacted.messages));
    ] in
    (true, Yojson.Safe.to_string result_json)
  with
  | Failure msg ->
    (false, Yojson.Safe.to_string (`Assoc [
      ("error", `String msg);
    ]))
  | exn ->
    (false, Yojson.Safe.to_string (`Assoc [
      ("error", `String (Printexc.to_string exn));
    ]))

(* ================================================================ *)
(* Dispatcher                                                       *)
(* ================================================================ *)

let dispatch ~name ~args : result option =
  match name with
  | "masc_compact_context" -> Some (handle_compact args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_compact
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~visibility:Tool_catalog.Hidden
           ~allow_direct_call_when_hidden:true
           ()))
    schemas
