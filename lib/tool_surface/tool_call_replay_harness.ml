module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

type tool_call = {
  name : string;
  arguments : Yojson.Safe.t;
}

type response_format =
  | Openai_chat_completions
  | Anthropic_messages
  | Gemini_generate_content
  | Dashscope_output_choices

type snapshot = {
  id : string;
  provider : string;
  model : string option;
  response_format : response_format;
  goal : string;
  tools : string list;
  response : Yojson.Safe.t;
  expected_tool_calls : tool_call list;
}

let ( let* ) = Result.bind

let errorf fmt =
  Printf.ksprintf (fun msg -> Error msg) fmt

let response_format_of_string = function
  | "openai_chat_completions" -> Ok Openai_chat_completions
  | "anthropic_messages" -> Ok Anthropic_messages
  | "gemini_generate_content" -> Ok Gemini_generate_content
  | "dashscope_output_choices" -> Ok Dashscope_output_choices
  | value -> errorf "response_format: unsupported value %S" value

let assoc label = function
  | `Assoc fields -> Ok fields
  | _ -> errorf "%s: expected object" label

let string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> errorf "%s: expected string" key
  | None -> errorf "%s: missing required field" key

let string_opt_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when not (String.equal (String.trim value) "") -> Ok (Some value)
  | Some `Null | None -> Ok None
  | Some (`String _) -> Ok None
  | Some _ -> errorf "%s: expected string or null" key

let list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List items) -> Ok items
  | Some _ -> errorf "%s: expected array" key
  | None -> errorf "%s: missing required field" key

let json_field fields key =
  match List.assoc_opt key fields with
  | Some json -> Ok json
  | None -> errorf "%s: missing required field" key

let string_list_field fields key =
  let* items = list_field fields key in
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | (`String value) :: rest -> collect (value :: acc) rest
    | _ -> errorf "%s: expected string array" key
  in
  collect [] items

let tool_call_of_json json =
  let* fields = assoc "tool_call" json in
  let* name = string_field fields "name" in
  let* arguments = json_field fields "arguments" in
  Ok { name; arguments }

let snapshot_of_json json =
  let* fields = assoc "snapshot" json in
  let* id = string_field fields "id" in
  let* provider = string_field fields "provider" in
  let* model = string_opt_field fields "model" in
  let* response_format_text = string_field fields "response_format" in
  let* response_format = response_format_of_string response_format_text in
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
  Ok
    {
      id;
      provider;
      model;
      response_format;
      goal;
      tools;
      response;
      expected_tool_calls;
    }

let load_snapshots_from_jsonl path =
  if not (Fs_compat.file_exists path) then
    errorf "snapshot file not found: %s" path
  else
    let rows, malformed = Fs_compat.load_jsonl_diagnostics path in
    if malformed > 0 then
      errorf "snapshot file contains %d malformed JSONL line(s): %s" malformed path
    else
      let rec parse idx acc = function
        | [] -> Ok (List.rev acc)
        | row :: rest ->
            (match snapshot_of_json row with
             | Ok snapshot -> parse (idx + 1) (snapshot :: acc) rest
             | Error msg -> errorf "snapshot[%d]: %s" idx msg)
      in
      parse 0 [] rows

let json_of_string label text =
  match Yojson.Safe.from_string text with
  | json -> Ok json
  | exception Yojson.Json_error msg ->
      errorf "%s: invalid JSON (%s)" label msg

let function_tool_call_of_json label json =
  let* call_fields = assoc label json in
  let* fn_json = json_field call_fields "function" in
  let* fn_fields = assoc (label ^ ".function") fn_json in
  let* name = string_field fn_fields "name" in
  let* arguments_text = string_field fn_fields "arguments" in
  let* arguments = json_of_string (label ^ ".function.arguments") arguments_text in
  Ok { name; arguments }

let function_tool_calls_of_json_list label items =
  let rec parse idx acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let item_label = Printf.sprintf "%s[%d]" label idx in
        let* parsed = function_tool_call_of_json item_label item in
        parse (idx + 1) (parsed :: acc) rest
  in
  parse 0 [] items

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
      function_tool_calls_of_json_list
        "response.choices[0].message.tool_calls"
        tool_call_items

let extract_dashscope_tool_calls response =
  let* fields = assoc "response" response in
  let* output = json_field fields "output" in
  let* output_fields = assoc "response.output" output in
  let* choices = list_field output_fields "choices" in
  match choices with
  | [] -> errorf "response.output.choices: must not be empty"
  | first :: _ ->
      let* choice_fields = assoc "response.output.choices[0]" first in
      let* message = json_field choice_fields "message" in
      let* message_fields = assoc "response.output.choices[0].message" message in
      let* tool_call_items =
        match List.assoc_opt "tool_calls" message_fields with
        | Some (`List items) -> Ok items
        | Some `Null | None -> Ok []
        | Some _ ->
            errorf "response.output.choices[0].message.tool_calls: expected array"
      in
      function_tool_calls_of_json_list
        "response.output.choices[0].message.tool_calls"
        tool_call_items

let extract_anthropic_tool_calls response =
  let* fields = assoc "response" response in
  let* content = list_field fields "content" in
  let rec parse idx acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let label = Printf.sprintf "response.content[%d]" idx in
        let* item_fields = assoc label item in
        (match List.assoc_opt "type" item_fields with
         | Some (`String "tool_use") ->
             let* name = string_field item_fields "name" in
             let* arguments = json_field item_fields "input" in
             parse (idx + 1) ({ name; arguments } :: acc) rest
         | Some (`String "text") -> parse (idx + 1) acc rest
         | Some (`String value) ->
             errorf "%s.type: unsupported content block %S" label value
         | Some _ -> errorf "%s.type: expected string" label
         | None -> errorf "%s.type: missing required field" label)
  in
  parse 0 [] content

let extract_gemini_tool_calls response =
  let* fields = assoc "response" response in
  let* candidates = list_field fields "candidates" in
  match candidates with
  | [] -> errorf "response.candidates: must not be empty"
  | first :: _ ->
      let* candidate_fields = assoc "response.candidates[0]" first in
      let* content = json_field candidate_fields "content" in
      let* content_fields = assoc "response.candidates[0].content" content in
      let* parts = list_field content_fields "parts" in
      let rec parse idx acc = function
        | [] -> Ok (List.rev acc)
        | part :: rest ->
            let label = Printf.sprintf "response.candidates[0].content.parts[%d]" idx in
            let* part_fields = assoc label part in
            (match
               (List.assoc_opt "functionCall" part_fields, List.assoc_opt "text" part_fields)
             with
             | Some function_call, _ ->
                 let* call_fields = assoc (label ^ ".functionCall") function_call in
                 let* name = string_field call_fields "name" in
                 let* arguments = json_field call_fields "args" in
                 parse (idx + 1) ({ name; arguments } :: acc) rest
             | None, Some (`String _) -> parse (idx + 1) acc rest
             | None, Some _ -> errorf "%s.text: expected string" label
             | None, None -> errorf "%s: expected text or functionCall" label)
      in
      parse 0 [] parts

let extract_tool_calls response_format response =
  match response_format with
  | Openai_chat_completions -> extract_openai_tool_calls response
  | Anthropic_messages -> extract_anthropic_tool_calls response
  | Gemini_generate_content -> extract_gemini_tool_calls response
  | Dashscope_output_choices -> extract_dashscope_tool_calls response

let validate_snapshot (snapshot : snapshot) =
  let errors = ref [] in
  let push fmt =
    Printf.ksprintf (fun msg -> errors := msg :: !errors) fmt
  in
  let tool_declared name = List.mem name snapshot.tools in
  List.iter
    (fun (expected : tool_call) ->
      if not (tool_declared expected.name) then
        push "expected tool '%s' is not declared in snapshot.tools" expected.name)
    snapshot.expected_tool_calls;
  if String.trim snapshot.provider = "" then
    push "snapshot provider must be non-empty";
  (match extract_tool_calls snapshot.response_format snapshot.response with
   | Error msg -> push "%s" msg
   | Ok actual_tool_calls ->
       List.iter
         (fun (actual : tool_call) ->
           if not (tool_declared actual.name) then
             push "response tool '%s' is not declared in snapshot.tools" actual.name)
         actual_tool_calls;
       if List.length actual_tool_calls <> List.length snapshot.expected_tool_calls then
         push
           "response emitted %d tool call(s) but snapshot expects %d"
           (List.length actual_tool_calls)
           (List.length snapshot.expected_tool_calls)
       else
         List.iter2
           (fun (expected : tool_call) (actual : tool_call) ->
             if not (String.equal expected.name actual.name) then
               push
                 "expected tool '%s' but response emitted '%s'"
                 expected.name actual.name;
             if not (Yojson.Safe.equal expected.arguments actual.arguments) then
               push
                 "arguments mismatch for tool '%s'"
                 expected.name)
           snapshot.expected_tool_calls actual_tool_calls);
  match List.rev !errors with
  | [] -> Ok ()
  | errs -> Error errs
