let role_to_string (r : Agent_sdk.Types.role) =
  match r with
  | System -> "system"
  | User -> "user"
  | Assistant -> "assistant"
  | Tool -> "tool"

(* Issue #8623: returns [Some] only for the 4 wire-format names.
   Callers must handle [None] explicitly — the previous Variant
   shape silently routed unknowns to [User], which misattributes
   checkpoint messages: a "system" / "assistant" / "tool" decoded as
   "user" causes the LLM to treat tool output as user instructions,
   echo prior assistant replies as user input, or downgrade system
   prompt privileges. Same anti-pattern class as #8605/#8615. *)
let role_of_string_opt = function
  | "system" -> Some Agent_sdk.Types.System
  | "user" -> Some Agent_sdk.Types.User
  | "assistant" -> Some Agent_sdk.Types.Assistant
  | "tool" -> Some Agent_sdk.Types.Tool
  | _ -> None

(* Backwards-compatible wrapper. [Tool] is the safest fallback for an
   unrecognised role: tool messages are interpretive context, not
   instructions, so misclassifying System/Assistant/User as Tool hides
   the message rather than letting the LLM act on it. The warn log
   preserves operator visibility. *)
let role_of_string s =
  match role_of_string_opt s with
  | Some role -> role
  | None ->
      Log.Misc.warn
        "keeper_context_core: unknown role %S, defaulting to Tool (#8623)" s;
      Agent_sdk.Types.Tool

let content_blocks_to_json
    (blocks : Agent_sdk.Types.content_block list) : Yojson.Safe.t =
  `List (List.map Agent_sdk.Api.content_block_to_json blocks)

let content_blocks_of_json
    (json : Yojson.Safe.t) : Agent_sdk.Types.content_block list option =
  let open Yojson.Safe.Util in
  let parse_block_list = function
    | `List blocks ->
        let parsed = List.filter_map Agent_sdk.Api.content_block_of_json blocks in
        if List.length parsed = List.length blocks then Some parsed else None
    | _ -> None
  in
  match parse_block_list (json |> member "content_blocks") with
  | Some _ as blocks -> blocks
  | None ->
      (* Some OAS/OpenAI-style checkpoints use a structured [content] array
         instead of MASC's [content_blocks] field. Treat that as the same
         block source rather than forcing the legacy flat-string path. *)
      parse_block_list (json |> member "content")

let legacy_content_text_of_json (json : Yojson.Safe.t) : string =
  let open Yojson.Safe.Util in
  match json |> member "content" with
  | `String value -> Inference_utils.sanitize_text_utf8 value
  | `Null -> ""
  | `List blocks ->
      let parsed = List.filter_map Agent_sdk.Api.content_block_of_json blocks in
      let msg : Agent_sdk.Types.message =
        {
          Agent_sdk.Types.role = Agent_sdk.Types.User;
          content = parsed;
          name = None;
          tool_call_id = None;
          metadata = [];
        }
      in
      Inference_utils.sanitize_text_utf8 (Agent_sdk.Types.text_of_message msg)
  | _ -> ""

let string_field_opt key value =
  match value with
  | Some text -> [ (key, `String text) ]
  | None -> []

let metadata_of_json (json : Yojson.Safe.t) : (string * Yojson.Safe.t) list =
  match Yojson.Safe.Util.member "metadata" json with
  | `Assoc fields -> fields
  | _ -> []

let message_to_json (m : Agent_sdk.Types.message) : Yojson.Safe.t =
  let m = Inference_utils.sanitize_message_utf8 m in
  let tool_call_id =
    match m.tool_call_id with
    | Some _ as explicit -> explicit
    | None -> (
        match m.role with
        | Agent_sdk.Types.Tool ->
            List.find_map
              (function
                | Agent_sdk.Types.ToolResult { tool_use_id; _ } ->
                    Some tool_use_id
                (* Other content_block variants do not carry a tool_use_id. *)
                | Agent_sdk.Types.Text _
                | Agent_sdk.Types.Thinking _
                | Agent_sdk.Types.RedactedThinking _
                | Agent_sdk.Types.ToolUse _
                | Agent_sdk.Types.Image _
                | Agent_sdk.Types.Document _
                | Agent_sdk.Types.Audio _ -> None)
              m.content
        (* Non-Tool roles never own a tool_call_id. *)
        | Agent_sdk.Types.System
        | Agent_sdk.Types.User
        | Agent_sdk.Types.Assistant -> None)
  in
  (* SSOT: structured [content_blocks] only. The previous flat [content]
     field was a duplicate of [text_of_message m] used by legacy
     checkpoint readers; new readers reconstruct text from
     [content_blocks] via [text_of_history_jsonl_line] (see below).
     Old checkpoints written with both fields still load fine because
     [message_of_json] keeps the legacy [content] fallback. *)
  let base =
    [
      ("role", `String (role_to_string m.role));
      ("content_blocks", content_blocks_to_json m.content);
    ]
  in
  `Assoc
    (base
     @ string_field_opt "name" m.name
     @ string_field_opt "tool_call_id" tool_call_id
     @ if m.metadata = [] then [] else [ ("metadata", `Assoc m.metadata) ])

let message_of_json (json : Yojson.Safe.t) : Agent_sdk.Types.message =
  let open Yojson.Safe.Util in
  let role = json |> member "role" |> to_string |> role_of_string in
  let text = legacy_content_text_of_json json in
  let content =
    match content_blocks_of_json json with
    | Some blocks ->
        if blocks <> [] then blocks
        else
          (* Legacy checkpoints stored only flattened text + role. For Tool
             messages that means the original assistant ToolUse block is gone,
             so rebuilding a structured ToolResult here creates an invalid
             orphaned pair on the next Anthropic request. Fall back to plain
             text so old checkpoints remain readable without breaking turns. *)
          [ Agent_sdk.Types.Text text ]
    | None -> [ Agent_sdk.Types.Text text ]
  in
  Inference_utils.sanitize_message_utf8
    {
      Agent_sdk.Types.role;
      content;
      name =
        (json |> member "name" |> to_string_option
         |> Option.map Inference_utils.sanitize_text_utf8);
      tool_call_id =
        (json |> member "tool_call_id" |> to_string_option
         |> Option.map Inference_utils.sanitize_text_utf8);
      metadata = [];
    }

(** Extract human-readable text from a single history.jsonl line that was
    produced by [message_to_json].  Reads structured [content_blocks]
    first (current SSOT), falls back to the legacy flat [content] field
    for lines written before that field was retired.  Returns [""] when
    neither shape is parseable. *)
let text_of_history_jsonl_json (json : Yojson.Safe.t) : string =
  match content_blocks_of_json json with
  | Some blocks when blocks <> [] ->
      let msg : Agent_sdk.Types.message =
        {
          Agent_sdk.Types.role = Agent_sdk.Types.User;
          content = blocks;
          name = None;
          tool_call_id = None;
          metadata = [];
        }
      in
      Inference_utils.sanitize_text_utf8 (Agent_sdk.Types.text_of_message msg)
  | _ -> legacy_content_text_of_json json
