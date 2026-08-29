(** The attached-service tool index (RFC-attached-service-tool-scoping §4.5 step 2).

    The index stands in for schemas that are no longer sent, so what is pinned
    here is what a Keeper can still find out: every carried tool has a row, a
    row names the tool exactly, and asking for a name the index does not hold
    is an error rather than a nearest match. *)

open Alcotest

module Index = Masc.Keeper_deferred_tool_index

let stub_handler (_ : Yojson.Safe.t) : Agent_core.Types.tool_result =
  Ok { Agent_core.Types.content = "stub"; _meta = None }
;;

let tool ~name ~description =
  Agent_core.Tool.create ~name ~description ~parameters:[] stub_handler
;;

let row ~name ~description =
  ( Agent_core.Types.tool_schema_of_params
      ~name
      ~description
      ~parameters:[]
      ()
  , tool ~name ~description )
;;

let sample () =
  Index.create
    [ row ~name:"slack_send_message" ~description:"Send a Slack message."
    ; row ~name:"atlassian_search" ~description:"Search Jira and Confluence."
    ]
;;

(* ── the index itself ────────────────────────────────── *)

let test_every_carried_tool_has_a_row () =
  let index = sample () in
  check bool "not empty" false (Index.is_empty index);
  check int "one row per carried tool" 2 (Index.count index);
  let text = Index.index_text index in
  List.iter
    (fun name ->
       check
         bool
         (Printf.sprintf "%s is named in the index" name)
         true
         (Astring.String.is_infix ~affix:name text))
    [ "slack_send_message"; "atlassian_search" ]
;;

let test_summary_is_the_first_line_only () =
  let index =
    Index.create
      [ row
          ~name:"wordy"
          ~description:"First line.\nSecond line the model does not need."
      ]
  in
  let text = Index.index_text index in
  check bool "keeps the first line" true (Astring.String.is_infix ~affix:"First line." text);
  check
    bool
    "drops what follows it"
    false
    (Astring.String.is_infix ~affix:"Second line" text)
;;

(* A service writes its own descriptions, so a long one is not a bug to
   reject. Cutting it on a byte boundary is: the row stops decoding as UTF-8
   and the whole request body carries a broken character. *)
let test_a_long_multibyte_summary_stays_utf8 () =
  let long = String.concat "" (List.init 200 (fun _ -> "설명")) in
  let index = Index.create [ row ~name:"korean" ~description:long ] in
  let text = Index.index_text index in
  check bool "index text is valid UTF-8" true (String_util.is_valid_utf8 text);
  check bool "the summary was cut" true (String.length text < String.length long)
;;

let test_an_empty_index_renders_nothing () =
  let index = Index.create [] in
  check bool "empty" true (Index.is_empty index);
  check int "no rows" 0 (Index.count index);
  check string "no text" "" (Index.index_text index)
;;

(* ── select ──────────────────────────────────────────── *)

let test_select_resolves_exact_names () =
  match Index.select (sample ()) ~names:[ "atlassian_search" ] with
  | Error message -> fail message
  | Ok tools ->
    check int "one tool" 1 (List.length tools);
    (match tools with
     | [ tool ] ->
       check
         string
         "the named tool"
         "atlassian_search"
         tool.Agent_core.Tool.schema.name
     | _ -> fail "select returned the wrong shape")
;;

let test_an_unknown_name_is_an_error_naming_it () =
  match Index.select (sample ()) ~names:[ "slack_send_messages" ] with
  | Ok _ -> fail "a name the index does not hold resolved to a tool"
  | Error message ->
    check
      bool
      "the error names what was asked for"
      true
      (Astring.String.is_infix ~affix:"slack_send_messages" message)
;;

let test_no_names_is_an_error () =
  match Index.select (sample ()) ~names:[] with
  | Ok _ -> fail "an empty request resolved to tools"
  | Error _ -> ()
;;

(* ── the search tool ─────────────────────────────────── *)

let call tool input = Agent_core.Tool.execute tool input

let test_the_search_tool_widens_the_agent () =
  let widened = ref [] in
  let extend tools = widened := !widened @ tools; Ok () in
  let search = Index.search_tool (sample ()) ~extend in
  match
    call search (`Assoc [ "names", `List [ `String "slack_send_message" ] ])
  with
  | Error { Agent_core.Types.message; _ } -> fail message
  | Ok { Agent_core.Types.content; _ } ->
    check int "the agent was widened by one tool" 1 (List.length !widened);
    check
      bool
      "the result carries the schema"
      true
      (Astring.String.is_infix ~affix:"slack_send_message" content)
;;

(* A request that names one tool it holds and one it does not must widen by
   neither. Widening by the half it recognised would leave the Keeper holding
   a tool it never learned it had, and the error it reads would not say so. *)
let test_one_unknown_name_widens_nothing () =
  let widened = ref [] in
  let extend tools = widened := !widened @ tools; Ok () in
  let search = Index.search_tool (sample ()) ~extend in
  match
    call
      search
      (`Assoc
        [ "names", `List [ `String "slack_send_message"; `String "not_carried" ] ])
  with
  | Ok _ -> fail "a request naming an unknown tool succeeded"
  | Error _ -> check int "nothing was widened" 0 (List.length !widened)
;;

let test_a_malformed_request_widens_nothing () =
  let widened = ref [] in
  let extend tools = widened := !widened @ tools; Ok () in
  let search = Index.search_tool (sample ()) ~extend in
  List.iter
    (fun (label, input) ->
       match call search input with
       | Ok _ -> fail (Printf.sprintf "%s was accepted" label)
       | Error _ -> ())
    [ "a bare string", `String "slack_send_message"
    ; "names missing", `Assoc []
    ; "names not an array", `Assoc [ "names", `String "slack_send_message" ]
    ; "a non-string entry", `Assoc [ "names", `List [ `Int 1 ] ]
    ; "a blank entry", `Assoc [ "names", `List [ `String "  " ] ]
    ];
  check int "nothing was widened" 0 (List.length !widened)
;;

(* [extend] is wired to a cell the turn setup fills. A call that reaches the
   tool before it is filled has found a wiring defect, and answering with the
   schema anyway would hand the model a tool whose calls are then dropped
   before history with nothing it can read. *)
let test_an_unwired_extend_fails_the_call () =
  let search =
    Index.search_tool (sample ()) ~extend:(fun _ -> Error "no agent for this turn")
  in
  match call search (`Assoc [ "names", `List [ `String "atlassian_search" ] ]) with
  | Ok _ -> fail "a call that could not widen the agent reported success"
  | Error { Agent_core.Types.message; _ } ->
    check
      bool
      "the error says why"
      true
      (Astring.String.is_infix ~affix:"no agent" message)
;;

(* The index rides in the search tool's own description. That is what keeps a
   lane that is not handed the search tool from being handed the index either,
   so no caller has to know which lane it is on. *)
let test_the_index_rides_in_the_tool_description () =
  let search = Index.search_tool (sample ()) ~extend:(fun _ -> Ok ()) in
  let description = search.Agent_core.Tool.schema.description in
  List.iter
    (fun name ->
       check
         bool
         (Printf.sprintf "%s reaches the model through the description" name)
         true
         (Astring.String.is_infix ~affix:name description))
    [ "slack_send_message"; "atlassian_search" ]
;;

let () =
  run
    "keeper deferred tool index"
    [ ( "index"
      , [ test_case "every carried tool has a row" `Quick test_every_carried_tool_has_a_row
        ; test_case "summary is the first line only" `Quick test_summary_is_the_first_line_only
        ; test_case
            "a long multibyte summary stays utf8"
            `Quick
            test_a_long_multibyte_summary_stays_utf8
        ; test_case "an empty index renders nothing" `Quick test_an_empty_index_renders_nothing
        ] )
    ; ( "select"
      , [ test_case "resolves exact names" `Quick test_select_resolves_exact_names
        ; test_case
            "an unknown name is an error naming it"
            `Quick
            test_an_unknown_name_is_an_error_naming_it
        ; test_case "no names is an error" `Quick test_no_names_is_an_error
        ] )
    ; ( "search tool"
      , [ test_case "widens the agent" `Quick test_the_search_tool_widens_the_agent
        ; test_case "one unknown name widens nothing" `Quick test_one_unknown_name_widens_nothing
        ; test_case
            "a malformed request widens nothing"
            `Quick
            test_a_malformed_request_widens_nothing
        ; test_case
            "an unwired extend fails the call"
            `Quick
            test_an_unwired_extend_fails_the_call
        ; test_case
            "the index rides in the tool description"
            `Quick
            test_the_index_rides_in_the_tool_description
        ] )
    ]
;;
