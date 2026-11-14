(* Prints the first prompt a new Claude Code session would receive for the
   replayed-result-age eval (RFC replayed-tool-results-carry-their-time §6.1).

   The input is a fixture whose times are already absolute
   (scripts/eval-replayed-result-age.py resolves them). The history goes
   through the runtime's own Start projection and envelope, so a change to
   the codec or the envelope reaches the eval without touching this file.

   The first prompt the runtime sends is the composed start context followed
   by the envelope, separated by a blank line (Keeper_official_client_host
   .start_prompt). The start context here is one System_context message,
   labelled the way the host labels it. *)

open Masc

let usage = "replayed_result_age_seed.exe --fixture RESOLVED_FIXTURE_JSON"

let fail fmt = Printf.ksprintf (fun detail -> prerr_endline detail; exit 2) fmt

let member name json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> fail "fixture: missing field %s" name)
  | _ -> fail "fixture: %s is read from a non-object" name

let optional name json =
  match json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> fail "fixture: %s is read from a non-object" name

let string_of name json =
  match member name json with
  | `String value -> value
  | _ -> fail "fixture: %s must be a string" name

let bool_of name json =
  match member name json with
  | `Bool value -> value
  | _ -> fail "fixture: %s must be a boolean" name

let assistant_blocks entry =
  let thinking = match optional "thinking" entry with
    | Some (`String content) -> [ Agent_core.Types.Thinking { content; signature = None } ]
    | Some _ -> fail "fixture: thinking must be a string"
    | None -> [] in
  let text = match optional "text" entry with
    | Some (`String text) -> [ Agent_core.Types.Text text ]
    | Some _ -> fail "fixture: text must be a string"
    | None -> [] in
  let tool_use = match optional "tool_use" entry with
    | Some use ->
      [ Agent_core.Types.ToolUse
          { id = string_of "id" use; name = string_of "name" use; input = member "input" use } ]
    | None -> [] in
  thinking @ text @ tool_use

let tool_result entry =
  let result = member "tool_result" entry in
  let content = string_of "content" result in
  let outcome =
    if bool_of "is_error" result
    then Agent_core.Types.Tool_failed
        { failure_kind = Agent_core.Types.Reported_tool_error; error_class = None }
    else Agent_core.Types.Tool_succeeded in
  (* The 2026-11-14 replayed result carried no structured_content: the
     Agent Core turn stored it without a parsed payload. *)
  Agent_core.Types.ToolResult
    { tool_use_id = string_of "tool_use_id" result; content; outcome
    ; json = None; content_blocks = None }

let message_of entry =
  match string_of "role" entry with
  | "preamble" -> Runtime_model_input_tail_window.preamble_message
  | "assistant" -> Agent_core.Types.make_message ~role:Assistant (assistant_blocks entry)
  | "tool" -> Agent_core.Types.make_message ~role:Tool [ tool_result entry ]
  | other -> fail "fixture: role %s is not one the eval uses" other

let () =
  let fixture = ref "" in
  Arg.parse [ "--fixture", Arg.Set_string fixture, "resolved fixture JSON" ]
    (fun extra -> fail "unexpected argument %s\n%s" extra usage) usage;
  if !fixture = "" then fail "%s" usage;
  let json = Yojson.Safe.from_file !fixture in
  let history = match member "history" json with
    | `List entries -> List.map message_of entries
    | _ -> fail "fixture: history must be a list" in
  let context =
    Agent_core.Types.make_message ~role:System ~origin:System_context
      [ Agent_core.Types.Text (string_of "system_context" json) ] in
  match Keeper_claude_code_runtime.project_messages history with
  | Error _ -> fail "the Start projection refused the fixture history"
  | Ok (_ :: _, _) -> fail "fixture history must not hold System messages"
  | Ok ([], projected) ->
    let envelope =
      Keeper_claude_code_runtime.initial_turn_prompt ~history:projected
        ~goal:(string_of "goal" json) in
    print_string
      (Keeper_official_client_host.history_role_label Agent_core.Types.System
       ^ Keeper_official_client_host.encode_history_message context
       ^ "\n\n" ^ envelope)
