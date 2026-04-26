type tool_call =
  { name : string
  ; arguments : Yojson.Safe.t
  }

type snapshot =
  { id : string
  ; provider : string
  ; model : string option
  ; goal : string
  ; tools : string list
  ; response : Yojson.Safe.t
  ; expected_tool_calls : tool_call list
  }

let ( let* ) = Result.bind
let errorf fmt = Printf.ksprintf (fun msg -> Error msg) fmt

type response_format = Openai_chat_completions

let assoc label = function
  | `Assoc fields -> Ok fields
  | _ -> errorf "%s: expected object" label
;;

let string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> errorf "%s: expected string" key
  | None -> errorf "%s: missing required field" key
;;

let string_opt_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some `Null | None -> Ok None
  | Some (`String _) -> Ok None
  | Some _ -> errorf "%s: expected string or null" key
;;

let list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List items) -> Ok items
  | Some _ -> errorf "%s: expected array" key
  | None -> errorf "%s: missing required field" key
;;

let json_field fields key =
  match List.assoc_opt key fields with
  | Some json -> Ok json
  | None -> errorf "%s: missing required field" key
;;

let string_list_field fields key =
  let* items = list_field fields key in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | `String value :: rest -> collect (value :: acc) rest
    | _ -> errorf "%s: expected string array" key
  in
  collect [] items
;;

let tool_call_of_json json =
  let* fields = assoc "tool_call" json in
  let* name = string_field fields "name" in
  let* arguments = json_field fields "arguments" in
  Ok { name; arguments }
;;

let snapshot_of_json json =
  let* fields = assoc "snapshot" json in
  let* id = string_field fields "id" in
  let* provider = string_field fields "provider" in
  let* model = string_opt_field fields "model" in
  let* goal = string_field fields "goal" in
  let* tools = string_list_field fields "tools" in
  let* response = json_field fields "response" in
  let* expected_items = list_field fields "expected_tool_calls" in
  let rec parse_expected acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* parsed = tool_call_of_json item in
      parse_expected (parsed :: acc) rest
  in
  let* expected_tool_calls = parse_expected [] expected_items in
  Ok { id; provider; model; goal; tools; response; expected_tool_calls }
;;

let load_snapshots_from_jsonl path =
  if not (Fs_compat.file_exists path)
  then errorf "snapshot file not found: %s" path
  else (
    let rows, malformed = Fs_compat.load_jsonl_diagnostics path in
    if malformed > 0
    then errorf "snapshot file contains %d malformed JSONL line(s): %s" malformed path
    else (
      let rec parse idx acc = function
        | [] -> Ok (List.rev acc)
        | row :: rest ->
          (match snapshot_of_json row with
           | Ok snapshot -> parse (idx + 1) (snapshot :: acc) rest
           | Error msg -> errorf "snapshot[%d]: %s" idx msg)
      in
      parse 0 [] rows))
;;

let response_format_of_provider provider =
  let canonical =
    match Provider_adapter.resolve_direct_canonical_name provider with
    | Some name -> name
    | None -> String.lowercase_ascii (String.trim provider)
  in
  (* The seed harness only knows the OpenAI-compatible chat-completions
     tool-call envelope; unsupported providers must add an explicit extractor
     instead of silently reusing this parser. *)
  match canonical with
  | "codex-api"
  | "glm-api"
  | "glm-coding-plan"
  | "kimi-api"
  | "openrouter"
  | "ollama"
  | "llama" -> Ok Openai_chat_completions
  | _ ->
    errorf
      "snapshot provider '%s' (canonical '%s') is not supported by replay harness yet"
      provider
      canonical
;;

let extract_openai_tool_calls response =
  let* fields = assoc "response" response in
  let* choices = list_field fields "choices" in
  match choices with
  | [] -> errorf "response: choices must not be empty"
  | first :: _ ->
    let* choice_fields = assoc "response.choices[0]" first in
    let* message = json_field choice_fields "message" in
    let* message_fields = assoc "response.choices[0].message" message in
    let* tool_call_items =
      match List.assoc_opt "tool_calls" message_fields with
      | Some (`List items) -> Ok items
      | Some `Null | None -> Ok []
      | Some _ -> errorf "response.choices[0].message.tool_calls: expected array"
    in
    let rec parse idx acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* call_fields = assoc (Printf.sprintf "response.tool_calls[%d]" idx) item in
        let* fn_json = json_field call_fields "function" in
        let* fn_fields =
          assoc (Printf.sprintf "response.tool_calls[%d].function" idx) fn_json
        in
        let* name = string_field fn_fields "name" in
        let* arguments_text = string_field fn_fields "arguments" in
        let* arguments =
          match Yojson.Safe.from_string arguments_text with
          | json -> Ok json
          | exception Yojson.Json_error msg ->
            errorf "response.tool_calls[%d].function.arguments: invalid JSON (%s)" idx msg
        in
        parse (idx + 1) ({ name; arguments } :: acc) rest
    in
    parse 0 [] tool_call_items
;;

let validate_snapshot (snapshot : snapshot) =
  let errors = ref [] in
  let push fmt = Printf.ksprintf (fun msg -> errors := msg :: !errors) fmt in
  let tool_declared name = List.mem name snapshot.tools in
  List.iter
    (fun (expected : tool_call) ->
       if not (tool_declared expected.name)
       then push "expected tool '%s' is not declared in snapshot.tools" expected.name)
    snapshot.expected_tool_calls;
  (match response_format_of_provider snapshot.provider with
   | Error msg -> push "%s" msg
   | Ok Openai_chat_completions ->
     (match extract_openai_tool_calls snapshot.response with
      | Error msg -> push "%s" msg
      | Ok actual_tool_calls ->
        List.iter
          (fun (actual : tool_call) ->
             if not (tool_declared actual.name)
             then push "response tool '%s' is not declared in snapshot.tools" actual.name)
          actual_tool_calls;
        if List.length actual_tool_calls <> List.length snapshot.expected_tool_calls
        then
          push
            "response emitted %d tool call(s) but snapshot expects %d"
            (List.length actual_tool_calls)
            (List.length snapshot.expected_tool_calls)
        else
          List.iter2
            (fun (expected : tool_call) (actual : tool_call) ->
               if not (String.equal expected.name actual.name)
               then
                 push
                   "expected tool '%s' but response emitted '%s'"
                   expected.name
                   actual.name;
               if not (Yojson.Safe.equal expected.arguments actual.arguments)
               then push "arguments mismatch for tool '%s'" expected.name)
            snapshot.expected_tool_calls
            actual_tool_calls));
  match List.rev !errors with
  | [] -> Ok ()
  | errs -> Error errs
;;
