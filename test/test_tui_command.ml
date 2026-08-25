open Alcotest

module Command = Masc_tui_command
module Mcp = Masc_tui_mcp

let describe = function
  | Command.Say text -> "say:" ^ text
  | Command.Task_for_keeper { title; body } -> Printf.sprintf "task:%s|%s" title body
  | Command.Task_missing_title -> "task-missing-title"
  | Command.Help -> "help"
  | Command.Switch_keeper name -> "keeper:" ^ name
  | Command.Switch_keeper_missing_name -> "keeper-missing-name"
  | Command.Interrupt_turn -> "interrupt"
  | Command.Toggle_thinking -> "toggle-thinking"
  | Command.Toggle_memory -> "toggle-memory"
  (* [describe] is total on purpose: it is what makes a new command show up
     here as a compile error instead of silently going untested. #30234 added
     these two and the match was not swept, which is exactly the miss the
     totality is for. *)
  | Command.View_image path -> "image:" ^ path
  | Command.View_image_missing_path -> "image-missing-path"
  | Command.Unknown word -> "unknown:" ^ word

let test_plain_text_is_a_message () =
  check (list string) "text, blanks, and a slash that is not first are messages"
    [ "say:fix the caret"; "say: /task not a command"; "say:" ]
    (List.map
       (fun text -> describe (Command.parse text))
       [ "fix the caret"; " /task not a command"; "" ])

let test_task_takes_the_line_as_title_and_the_rest_as_body () =
  check string "title only" "task:Lanes surface|"
    (describe (Command.parse "/task Lanes surface"));
  check string "title and body"
    "task:Lanes surface|composite \xe2\x86\x92 table\nPTY test too"
    (describe
       (Command.parse "/task   Lanes surface  \ncomposite \xe2\x86\x92 table\nPTY test too"));
  check string "a bare /task is reported, not sent" "task-missing-title"
    (describe (Command.parse "/task"));
  check string "and so is /task with only blanks" "task-missing-title"
    (describe (Command.parse "/task   "))

let test_pane_commands_parse_by_word () =
  check (list string) "help, keeper, interrupt, thinking, memory and image"
    [ "help"
    ; "keeper:orbiter"
    ; "keeper-missing-name"
    ; "interrupt"
    ; "toggle-thinking"
    ; "toggle-memory"
    ; "image:shots/frame.png"
    ; "image-missing-path"
    ]
    (List.map
       (fun text -> describe (Command.parse text))
       [ "/help"
       ; "/keeper orbiter"
       ; "/keeper   "
       ; "/interrupt"
       ; "/thinking"
       ; "/memory"
       ; "/image shots/frame.png"
       ; "/image   "
       ])

let test_every_command_has_a_help_line () =
  (* /help itself and every slash word the parser knows appear in the list,
     so a new command cannot ship silently undocumented. *)
  List.iter
    (fun word ->
      check bool (Printf.sprintf "help mentions /%s" word) true
        (List.exists
           (fun line -> String.starts_with ~prefix:("/" ^ word) line)
           Command.help_lines))
    [ "task"; "keeper"; "interrupt"; "thinking"; "memory"; "help" ]

let test_keeper_names_resolve_by_unique_prefix () =
  let names = [ "orbiter"; "orbit"; "lantern"; "zephyr" ] in
  let describe_match = function
    | Command.Keeper_found name -> "found:" ^ name
    | Command.Keeper_ambiguous candidates ->
        "ambiguous:" ^ String.concat "," candidates
    | Command.Keeper_unknown -> "unknown"
  in
  check (list string)
    "exact wins over prefix, unique prefix resolves, ambiguity is reported"
    [ "found:orbit" (* exact, though it prefixes orbiter *)
    ; "found:lantern"
    ; "found:zephyr" (* unique prefix *)
    ; "ambiguous:orbiter,orbit" (* orb- prefixes two *)
    ; "unknown"
    ]
    (List.map
       (fun typed -> describe_match (Command.resolve_keeper_name ~names typed))
       [ "orbit"; "lantern"; "ze"; "orb"; "zzz" ])

let test_an_unknown_command_is_named_not_sent () =
  check (list string) "the word after the slash, nothing else"
    [ "unknown:tsak"; "unknown:wake"; "unknown:" ]
    (List.map
       (fun text -> describe (Command.parse text))
       [ "/tsak Lanes"; "/wake @alpha"; "/" ])

let test_the_keeper_message_carries_the_task_id_first () =
  check string "title only" "[task-500] Lanes surface"
    (Command.task_message ~task_id:"task-500" ~title:"Lanes surface" ~body:"");
  check string "with a body" "[task-500] Lanes surface\ncomposite \xe2\x86\x92 table"
    (Command.task_message ~task_id:"task-500" ~title:"Lanes surface"
       ~body:"composite \xe2\x86\x92 table")

(* The live server's answer to a tools/call, trimmed: SSE framing, the
   JSON-RPC object on one data line. *)
let live_answer ~id ~text ~is_error =
  Printf.sprintf
    "retry: 3000\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"resultType\":\"complete\",\"resultEnvelope\":{\"kind\":\"tool_call\",\"summary\":\"x\",\"status\":\"ok\",\"tool\":\"masc_add_task\"},\"content\":[{\"type\":\"text\",\"text\":%s}],\"isError\":%b,\"_meta\":{}}}\n\n"
    id (Yojson.Safe.to_string (`String text)) is_error

let test_a_tool_answer_is_read_off_the_sse_body () =
  match
    Mcp.outcome_of_body ~request_id:"tui-1"
      (live_answer ~id:"\"tui-1\""
         ~text:"{\"ok\":true,\"task_id\":\"task-500\",\"summary\":\"Added task-500\"}"
         ~is_error:false)
  with
  | Ok { Mcp.text; is_error } ->
      check bool "not an error" false is_error;
      check (result string string) "the task id comes out of the text" (Ok "task-500")
        (Mcp.task_id_of_add_task text)
  | Error detail -> failf "expected an outcome, got %s" detail

let test_a_tool_that_failed_is_an_outcome_not_a_transport_error () =
  match
    Mcp.outcome_of_body ~request_id:"tui-2"
      (live_answer ~id:"\"tui-2\"" ~text:"title must not be empty" ~is_error:true)
  with
  | Ok { Mcp.text; is_error } ->
      check bool "the tool's verdict" true is_error;
      check string "with its words" "title must not be empty" text
  | Error detail -> failf "expected an outcome, got %s" detail

let test_answers_this_cannot_use_say_why () =
  let reason body =
    match Mcp.outcome_of_body ~request_id:"tui-3" body with
    | Ok _ -> "ok"
    | Error detail -> detail
  in
  check bool "another request's answer" true
    (String.starts_with ~prefix:"tools/call answered request tui-9"
       (reason (live_answer ~id:"\"tui-9\"" ~text:"x" ~is_error:false)));
  check string "a JSON-RPC error"
    "tools/call refused: unknown tool"
    (reason
       "data: {\"jsonrpc\":\"2.0\",\"id\":\"tui-3\",\"error\":{\"code\":-32601,\"message\":\"unknown tool\"}}\n");
  check bool "not JSON at all" true
    (String.starts_with ~prefix:"tools/call answer was not JSON"
       (reason "<html>502</html>"));
  check string "a plain JSON object without SSE framing also reads" "ok"
    (reason
       "{\"jsonrpc\":\"2.0\",\"id\":\"tui-3\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"fine\"}],\"isError\":false}}");
  check bool "an add_task answer without an id" true
    (Result.is_error (Mcp.task_id_of_add_task "Added task: Lanes surface"))

let test_the_request_names_the_tool_and_its_arguments () =
  match
    Yojson.Safe.from_string
      (Mcp.request_body ~request_id:"tui-4" ~tool:"masc_add_task"
         ~arguments:[ ("title", `String "Lanes"); ("priority", `Int 2) ])
  with
  | `Assoc fields ->
      check (option string) "method" (Some "tools/call")
        (match List.assoc_opt "method" fields with Some (`String m) -> Some m | _ -> None);
      (match List.assoc_opt "params" fields with
       | Some (`Assoc params) ->
           check (option string) "tool name" (Some "masc_add_task")
             (match List.assoc_opt "name" params with
              | Some (`String n) -> Some n
              | _ -> None);
           check bool "arguments carried as given" true
             (List.assoc_opt "arguments" params
             = Some (`Assoc [ ("title", `String "Lanes"); ("priority", `Int 2) ]))
       | _ -> fail "params missing")
  | _ -> fail "request is not an object"

let () =
  run "tui command"
    [ ( "composer"
      , [ test_case "plain text is a message" `Quick test_plain_text_is_a_message
        ; test_case "keeper names resolve by unique prefix" `Quick
            test_keeper_names_resolve_by_unique_prefix
        ; test_case "pane commands parse by word" `Quick
            test_pane_commands_parse_by_word
        ; test_case "every command has a help line" `Quick
            test_every_command_has_a_help_line
        ; test_case "/task takes the line as title and the rest as body" `Quick
            test_task_takes_the_line_as_title_and_the_rest_as_body
        ; test_case "an unknown command is named, not sent" `Quick
            test_an_unknown_command_is_named_not_sent
        ; test_case "the keeper message carries the task id first" `Quick
            test_the_keeper_message_carries_the_task_id_first
        ] )
    ; ( "tools/call"
      , [ test_case "a tool answer is read off the SSE body" `Quick
            test_a_tool_answer_is_read_off_the_sse_body
        ; test_case "a tool that failed is an outcome, not a transport error" `Quick
            test_a_tool_that_failed_is_an_outcome_not_a_transport_error
        ; test_case "answers this cannot use say why" `Quick
            test_answers_this_cannot_use_say_why
        ; test_case "the request names the tool and its arguments" `Quick
            test_the_request_names_the_tool_and_its_arguments
        ] )
    ]
