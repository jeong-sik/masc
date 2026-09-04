open Alcotest

module Command = Masc_tui_command
module Mcp = Masc_tui_mcp

let describe = function
  | Command.Say text -> "say:" ^ text
  | Command.Task_for_keeper { title; body } -> Printf.sprintf "task:%s|%s" title body
  | Command.Task_missing_title -> "task-missing-title"
  | Command.Help -> "help"
  | Command.Open_settings -> "open-settings"
  | Command.Switch_keeper name -> "keeper:" ^ name
  | Command.Switch_keeper_missing_name -> "keeper-missing-name"
  | Command.Interrupt_turn -> "interrupt"
  | Command.Steer_turn message -> "steer:" ^ message
  | Command.Steer_missing_message -> "steer-missing-message"
  | Command.Set_thinking mode ->
      "thinking:"
      ^ (match mode with
         | `Cycle -> "cycle"
         | `Hidden -> "hidden"
         | `Folded -> "folded"
         | `Full -> "full")
  | Command.Set_tools mode ->
      "tools:"
      ^ (match mode with
         | `Toggle -> "toggle"
         | `Compact -> "compact"
         | `Full -> "full")
  | Command.Cycle_memory -> "cycle-memory"
  | Command.Find_in_chat text -> "find:" ^ text
  | Command.Find_next -> "find-next"
  | Command.Inspect_context -> "inspect-context"
  (* [describe] is total on purpose: it is what makes a new command show up
     here as a compile error instead of silently going untested. #30234 added
     these two and the match was not swept, which is exactly the miss the
     totality is for. *)
  | Command.View_image path -> "image:" ^ path
  | Command.View_image_missing_path -> "image-missing-path"
  | Command.Attach_image path -> "attach:" ^ path
  | Command.Attach_image_missing_path -> "attach-missing-path"
  | Command.Preset_list -> "preset-list"
  | Command.Preset_save { name; description } ->
      Printf.sprintf "preset-save:%s|%s" name description
  | Command.Preset_save_missing_name -> "preset-save-missing-name"
  | Command.Preset_restore name -> "preset-restore:" ^ name
  | Command.Preset_restore_missing_name -> "preset-restore-missing-name"
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
  check (list string) "pane commands"
    [ "help"
    ; "open-settings"
    ; "keeper:orbiter"
    ; "keeper-missing-name"
    ; "interrupt"
    ; "steer:answer the correction\nwith this context"
    ; "steer-missing-message"
    ; "thinking:cycle"
    ; "thinking:hidden"
    ; "thinking:folded"
    ; "thinking:full"
    ; "tools:toggle"
    ; "tools:compact"
    ; "tools:full"
    ; "cycle-memory"
    ; "find:caret"
    ; "find:two words"
    ; "find-next"
    ; "find-next"
    ; "inspect-context"
    ; "image:shots/frame.png"
    ; "image-missing-path"
    ]
    (List.map
       (fun text -> describe (Command.parse text))
       [ "/help"
       ; "/settings"
       ; "/keeper orbiter"
       ; "/keeper   "
       ; "/interrupt"
       ; "/steer answer the correction\nwith this context"
       ; "/steer"
       ; "/thinking"
       ; "/thinking hidden"
       ; "/thinking folded"
       ; "/thinking full"
       ; "/tools"
       ; "/tools compact"
       ; "/tools full"
       ; "/memory"
       (* The text is the rest of the line, spaces and all: a search phrase is
          not one word, and quoting it would be a second grammar. *)
       ; "/find caret"
       ; "/find two words"
       (* Arg-less repeats rather than resetting, the same shape [/thinking]
          with no argument already has here. Blanks are not a query. *)
       ; "/find"
       ; "/find   "
       ; "/context"
       ; "/image shots/frame.png"
       ; "/image   "
       ])

let test_preset_commands_parse_verb_name_and_description () =
  check (list string) "preset commands"
    [ "preset-list"
    ; "preset-save:morning|"
    ; "preset-save:morning|state before the campaign"
    ; "preset-save:morning|first line\nand the rest"
    ; "preset-save:morning|only the body"
    ; "preset-save-missing-name"
    ; "preset-restore:morning"
    ; "preset-restore-missing-name"
    ; "unknown:preset drop"
    ]
    (List.map
       (fun text -> describe (Command.parse text))
       [ "/preset"
       ; "/preset save morning"
       ; "/preset save   morning  state before the campaign"
       ; "/preset save morning first line\nand the rest"
       ; "/preset save morning\nonly the body"
       ; "/preset save"
       ; "/preset restore morning"
       ; "/preset restore"
       ; "/preset drop morning"
       ])

let test_every_command_has_a_help_line () =
  (* Read from the catalog, so a command added there is checked without
     anyone remembering to extend a list here. The hand-written list this
     replaced had gone stale twice: it never gained image, attach or
     preset. *)
  check bool "the catalog is not empty" true (Command.catalog <> []);
  List.iter
    (fun (entry : Command.command_help) ->
      let word = entry.Command.word in
      check bool (Printf.sprintf "help mentions /%s" word) true
        (List.exists
           (fun line -> String.starts_with ~prefix:("/" ^ word) line)
           Command.help_lines))
    Command.catalog

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
    "retry: 3000\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":%s}],\"isError\":%b,\"_meta\":{\"com.github.yousleepwhen.masc/call\":{\"envelope\":{\"kind\":\"tool_call\",\"summary\":\"x\",\"status\":\"ok\",\"tool\":\"masc_add_task\"}}}}}\n\n"
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

let resources_answer ~id resources =
  Yojson.Safe.to_string
    (`Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", `String id)
      ; ("result", `Assoc [ ("resources", `List resources) ])
      ])

let test_resource_catalog_keeps_explanatory_metadata () =
  let body =
    resources_answer ~id:"res-1"
      [ `Assoc
          [ ("uri", `String "masc://status.json")
          ; ("name", `String "MASC Status JSON")
          ; ("title", `String "Project Status")
          ; ("description", `String "Current project status snapshot")
          ; ("mimeType", `String "application/json")
          ; ("size", `Int 4096)
          ]
      ; `Assoc [ ("uri", `String "masc://minimal") ]
      ]
  in
  match Mcp.resources_of_body ~request_id:"res-1" body with
  | Error detail -> failf "expected resources, got %s" detail
  | Ok [ full; minimal ] ->
      check string "uri" "masc://status.json" full.Mcp.uri;
      check string "name" "MASC Status JSON" full.name;
      check (option string) "title" (Some "Project Status") full.title;
      check (option string) "purpose" (Some "Current project status snapshot")
        full.description;
      check (option string) "format" (Some "application/json") full.mime_type;
      check (option int) "size" (Some 4096) full.size;
      check string "missing name falls back to uri" "masc://minimal" minimal.name;
      check (option string) "missing purpose stays absent" None minimal.description
  | Ok rows -> failf "expected two resources, got %d" (List.length rows)

let describe_hint = function
  | Command.No_command -> "none"
  | Command.Chosen entry -> "chosen:" ^ entry.Command.word
  | Command.Unknown_command word -> "unknown:" ^ word
  | Command.Candidates { entries; _ } ->
      "candidates:"
      ^ String.concat "," (List.map (fun e -> e.Command.word) entries)

let hint text = describe_hint (Command.hint text)

let test_plain_text_has_no_hint () =
  check string "a message" "none" (hint "please look at the log");
  check string "empty" "none" (hint "");
  check string "a slash mid-sentence" "none" (hint "look at a/b")

let test_a_lone_slash_lists_everything () =
  check int "one candidate per command" (List.length Command.catalog)
    (match Command.hint "/" with
     | Command.Candidates { entries; _ } -> List.length entries
     | Command.No_command | Command.Chosen _ | Command.Unknown_command _ -> 0)

let test_a_prefix_narrows_the_list () =
  check string "t narrows to three" "candidates:task,thinking,tools" (hint "/t");
  check string "th narrows to one" "candidates:thinking" (hint "/th")

(* [parse] does no prefix matching, so a half-typed word is not a command yet.
   A hint that described it would say the line was ready when sending it would
   be refused. *)
let test_a_half_typed_word_is_not_chosen () =
  check string "not chosen" "candidates:task" (hint "/ta");
  check bool "and the parser agrees" true
    (match Command.parse "/ta" with
     | Command.Unknown "ta" -> true
     | _ -> false)

let test_a_complete_word_is_described () =
  check string "bare" "chosen:task" (hint "/task");
  check string "with an argument" "chosen:task" (hint "/task write the runbook");
  check string "with a body below" "chosen:task" (hint "/task title\nbody");
  check string "an argument it knows" "chosen:thinking" (hint "/thinking folded")

let test_a_word_that_begins_nothing_is_named () =
  check string "named while it can be fixed" "unknown:zork" (hint "/zork");
  check string "and with an argument" "unknown:zork" (hint "/zork a b")

let test_the_hint_line_says_what_the_hint_holds () =
  check (option string) "no command" None (Command.hint_line Command.No_command);
  check bool "a chosen command carries its summary" true
    (match Command.hint_line (Command.hint "/memory") with
     | Some line ->
         String.length line > String.length "/memory"
         && String.starts_with ~prefix:"/memory" line
     | None -> false);
  check bool "candidates carry every usage" true
    (match Command.hint_line (Command.hint "/t") with
     | Some line ->
         List.for_all
           (fun word ->
              let needle = "/" ^ word in
              let rec appears at =
                at + String.length needle <= String.length line
                && (String.equal
                      (String.sub line at (String.length needle))
                      needle
                    || appears (at + 1))
              in
              appears 0)
           [ "task"; "thinking"; "tools" ]
     | None -> false);
  check bool "an unknown word names itself" true
    (match Command.hint_line (Command.hint "/zork") with
     | Some line -> String.starts_with ~prefix:"/zork is not a command" line
     | None -> false);
  check (option string) "one candidate still shows its argument"
    (Some "/thinking [hidden|folded|full]")
    (Command.hint_line (Command.hint "/th"));
  (* The bare slash is the one an operator types knowing nothing, so it is
     the row that must not run off the pane. *)
  check bool "the bare slash fits a narrow pane" true
    (match Command.hint_line (Command.hint "/") with
     | Some line -> String.length line <= 80
     | None -> false)

(* The catalog is what the help and the composer both read. A command listed
   there that the parser does not know would be documented and then refused. *)
let test_every_catalogued_command_parses () =
  List.iter
    (fun (entry : Command.command_help) ->
      check bool
        (Printf.sprintf "/%s parses" entry.Command.word)
        true
        (match Command.parse ("/" ^ entry.Command.word) with
         | Command.Unknown _ -> false
         | _ -> true))
    Command.catalog

let test_help_lines_come_from_the_catalog () =
  check int "one line per command" (List.length Command.catalog)
    (List.length Command.help_lines);
  List.iter2
    (fun (entry : Command.command_help) line ->
      check bool
        (Printf.sprintf "/%s keeps its summary" entry.Command.word)
        true
        (String.starts_with ~prefix:(Command.usage entry) line
         && String.length line > String.length (Command.usage entry)))
    Command.catalog Command.help_lines

let describe_span = function
  | Command.Typed text -> "T[" ^ text ^ "]"
  | Command.Untyped text -> "U[" ^ text ^ "]"
  | Command.Detail text -> "D[" ^ text ^ "]"
  | Command.Wrong text -> "W[" ^ text ^ "]"

let spans text =
  String.concat ""
    (List.map describe_span (Command.hint_spans (Command.hint text)))

let test_the_typed_run_is_what_was_pressed () =
  (* One candidate left, so the argument comes along with it. *)
  check string "a prefix highlights through the slash"
    "T[/ta]U[sk]D[ <title>]" (spans "/ta");
  (* Three left, so names only -- and each carries the same typed run. The
     separator is one space. *)
  check string "one glyph, three candidates"
    "T[/t]U[ask]D[ ]T[/t]U[hinking]D[ ]T[/t]U[ools]" (spans "/t");
  (* The bare slash draws its shared prefix once, then what fits. The catalog
     outgrew an 80-column composer, so the row says how many words it could
     not carry and points at the list that is complete by definition. *)
  check string "the bare slash highlights only itself"
    "T[/]U[task keeper settings interrupt steer thinking tools memory find]D[ +5 more (/help)]"
    (spans "/")

(* The row an operator types knowing nothing is the one that must not run off
   the pane, and it used to be sized by how many commands happened to exist:
   compacted once when /settings joined the catalog, over again at /find. The
   contract is the width, not the wording -- so this asserts the bound and
   that an elided row says it elided, rather than pinning a word list that
   every new command would have to come back and edit. *)
let test_the_bare_slash_row_is_bounded_by_its_width () =
  match Command.hint_line (Command.hint "/") with
  | None -> fail "the bare slash must offer a hint"
  | Some line ->
      check bool
        (Printf.sprintf "the row fits 80 columns (it is %d)" (String.length line))
        true
        (String.length line <= 80);
      check bool "it leads with the slash" true
        (String.starts_with ~prefix:"/" line);
      let pieces = String.split_on_char ' ' line in
      let words = List.map (fun (e : Command.command_help) -> e.word) Command.catalog in
      let carried =
        List.filter (fun word -> List.exists (String.equal word) pieces) words
      in
      check bool "it carries at least one command" true (carried <> []);
      if List.length carried < List.length words then
        check bool "an elided row says so and names where the rest are" true
          (List.exists (String.equal "more") pieces
           && List.exists (String.equal "(/help)") pieces)

(* Splitting the word for colour must not lose or duplicate a glyph. *)
let test_colour_boundaries_keep_every_glyph () =
  List.iter
    (fun (typed, word) ->
      match Command.hint_spans (Command.hint typed) with
      | Command.Typed head :: Command.Untyped tail :: _ ->
          check string
            (Printf.sprintf "%s spells /%s" typed word)
            ("/" ^ word) (head ^ tail)
      | _ -> failf "%s did not open with a typed run" typed)
    (* [/i] is left out on purpose: it opens both [interrupt] and [image], and
       the first span then spells whichever the catalog lists first. Each pair
       here names a prefix only one command answers. *)
    [ ("/ta", "task")
    ; ("/th", "thinking")
    ; ("/im", "image")
    ; ("/k", "keeper")
    ; ("/interrup", "interrupt")
    ]

let test_a_complete_word_needs_no_untyped_run () =
  check string "nothing left to type"
    "T[/memory]D[ \xe2\x80\x94 cycle Librarian/Memory journal rows: summary, \
     full, hidden]"
    (spans "/memory");
  check bool "an argument stays a detail" true
    (match Command.hint_spans (Command.hint "/thinking") with
     | Command.Typed "/thinking" :: Command.Detail args :: _ ->
         String.equal args " [hidden|folded|full]"
     | _ -> false)

let test_an_unknown_word_is_marked_wrong () =
  check bool "the word carries the wrong span" true
    (match Command.hint_spans (Command.hint "/zork") with
     | Command.Wrong "/zork" :: Command.Detail rest :: [] ->
         String.starts_with ~prefix:" is not a command" rest
     | _ -> false)

(* The row the renderer paints and the row the tests read have to be the same
   row, or one of them is describing a footer nobody sees. *)
let test_the_line_is_the_spans_joined () =
  List.iter
    (fun text ->
      let joined =
        match Command.hint_spans (Command.hint text) with
        | [] -> None
        | spans ->
            Some
              (String.concat ""
                 (List.map Command.hint_span_text spans))
      in
      check (option string)
        (Printf.sprintf "%S joins to its line" text)
        (Command.hint_line (Command.hint text))
        joined)
    [ ""; "hello"; "/"; "/t"; "/th"; "/thinking"; "/task a b"; "/zork" ]

(* The cancel contract: exit-class on masc_transition, so the one typed
   reason must arrive as both [reason] and the required non-empty
   [handoff_context.summary]. A builder that dropped the summary would pass
   the transport and be refused by the server's schema on every cancel. *)
let test_cancel_arguments_carry_reason_as_summary () =
  let arguments =
    Masc_tui_mcp.task_cancel_arguments ~task_id:"task-9" ~reason:"wrong scope"
  in
  let assoc key = List.assoc_opt key arguments in
  Alcotest.(check bool) "task id" true (assoc "task_id" = Some (`String "task-9"));
  Alcotest.(check bool) "action is cancel" true
    (assoc "action" = Some (`String "cancel"));
  Alcotest.(check bool) "reason rides" true
    (assoc "reason" = Some (`String "wrong scope"));
  Alcotest.(check bool) "summary equals the reason" true
    (assoc "handoff_context"
    = Some (`Assoc [ ("summary", `String "wrong scope") ]))

let test_resource_read_keeps_each_part_type () =
  let body =
    {|{"jsonrpc":"2.0","id":"resource-2","result":{"contents":[{"uri":"masc://events.json","mimeType":"application/json","text":"{\"ok\":true}"},{"uri":"masc://proof.bin","mimeType":"application/octet-stream","blob":"QUJDRA=="}]}}|}
  in
  match Mcp.resource_contents_of_body ~request_id:"resource-2" body with
  | Error detail -> Alcotest.fail detail
  | Ok
      [ { rc_uri = Some "masc://events.json"
        ; rc_mime_type = Some "application/json"
        ; rc_kind = Mcp.Resource_text "{\"ok\":true}"
        }
      ; { rc_uri = Some "masc://proof.bin"
        ; rc_mime_type = Some "application/octet-stream"
        ; rc_kind = Mcp.Resource_blob { base64_bytes = 8 }
        }
      ] ->
      ()
  | Ok contents ->
      Alcotest.failf "unexpected resource contents (%d parts)"
        (List.length contents)

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
        ; test_case "preset commands parse verb, name and description" `Quick
            test_preset_commands_parse_verb_name_and_description
        ; test_case "/task takes the line as title and the rest as body" `Quick
            test_task_takes_the_line_as_title_and_the_rest_as_body
        ; test_case "an unknown command is named, not sent" `Quick
            test_an_unknown_command_is_named_not_sent
        ; test_case "the keeper message carries the task id first" `Quick
            test_the_keeper_message_carries_the_task_id_first
        ; test_case "plain text has no hint" `Quick test_plain_text_has_no_hint
        ; test_case "a lone slash lists everything" `Quick
            test_a_lone_slash_lists_everything
        ; test_case "a prefix narrows the list" `Quick
            test_a_prefix_narrows_the_list
        ; test_case "a half-typed word is not chosen" `Quick
            test_a_half_typed_word_is_not_chosen
        ; test_case "a complete word is described" `Quick
            test_a_complete_word_is_described
        ; test_case "a word that begins nothing is named" `Quick
            test_a_word_that_begins_nothing_is_named
        ; test_case "the hint line says what the hint holds" `Quick
            test_the_hint_line_says_what_the_hint_holds
        ; test_case "every catalogued command parses" `Quick
            test_every_catalogued_command_parses
        ; test_case "help lines come from the catalog" `Quick
            test_help_lines_come_from_the_catalog
        ; test_case "the typed run is what was pressed" `Quick
            test_the_typed_run_is_what_was_pressed
        ; test_case "colour boundaries keep every glyph" `Quick
            test_colour_boundaries_keep_every_glyph
        ; test_case "a complete word needs no untyped run" `Quick
            test_a_complete_word_needs_no_untyped_run
        ; test_case "an unknown word is marked wrong" `Quick
            test_an_unknown_word_is_marked_wrong
        ; test_case "the bare slash row is bounded by its width" `Quick
            test_the_bare_slash_row_is_bounded_by_its_width
        ; test_case "the line is the spans joined" `Quick
            test_the_line_is_the_spans_joined
        ] )
    ; ( "tools/call"
      , [ test_case "cancel arguments carry the reason as summary" `Quick
            test_cancel_arguments_carry_reason_as_summary
        ; test_case "a tool answer is read off the SSE body" `Quick
            test_a_tool_answer_is_read_off_the_sse_body
        ; test_case "a tool that failed is an outcome, not a transport error" `Quick
            test_a_tool_that_failed_is_an_outcome_not_a_transport_error
        ; test_case "answers this cannot use say why" `Quick
            test_answers_this_cannot_use_say_why
        ; test_case "the request names the tool and its arguments" `Quick
            test_the_request_names_the_tool_and_its_arguments
        ] )
    ; ( "resources"
      , [ test_case "catalog keeps explanatory metadata" `Quick
            test_resource_catalog_keeps_explanatory_metadata
        ; test_case "read keeps each part type" `Quick
            test_resource_read_keeps_each_part_type
        ] )
    ]
