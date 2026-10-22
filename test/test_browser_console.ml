open Alcotest
module Console = Masc.Browser_console
let obj fields = `Assoc fields
let entry ?(context = "tab-a") ?(kind = "console") ?(level = "info") ?(timestamp = 1) text =
  obj [ "type", `String kind; "level", `String level; "text", `String text; "method", `String "log"
      ; "timestamp", `Int timestamp; "source", obj [ "context", `String context; "realm", `String "r" ]
      ; "args", `List [] ]
let record log params = match Console.event log params with Ok () -> () | Error detail -> fail detail
let member key json = Yojson.Safe.Util.member key json
let entries log ~context = Yojson.Safe.Util.to_list (member "entries" (Console.to_json log ~context))
let texts log ~context = List.map (fun row -> Yojson.Safe.Util.to_string (member "text" row)) (entries log ~context)

let test_entries_are_kept_in_order_per_tab () =
  let log = Console.create () in
  record log (entry ~context:"tab-a" "first");
  record log (entry ~context:"tab-b" "other tab");
  record log (entry ~context:"tab-a" ~kind:"javascript" ~level:"error" "Error: uncaught");
  check (list string) "tab a, oldest first" [ "first"; "Error: uncaught" ] (texts log ~context:"tab-a");
  check (list string) "tab b is separate" [ "other tab" ] (texts log ~context:"tab-b");
  check (list string) "a tab that logged nothing has no entries" [] (texts log ~context:"tab-c");
  let row = List.nth (entries log ~context:"tab-a") 1 in
  check string "the kind is kept" "javascript" (Yojson.Safe.Util.to_string (member "type" row));
  check string "the level is kept" "error" (Yojson.Safe.Util.to_string (member "level" row));
  check bool "a short text is not cut" true (member "textCut" row = `Bool false)

let test_the_oldest_entries_drop_and_are_counted () =
  let log = Console.create () in
  let total = Console.entries_per_context + 7 in
  for index = 1 to total do record log (entry (string_of_int index)) done;
  let kept = texts log ~context:"tab-a" in
  check int "no more than the limit are kept" Console.entries_per_context (List.length kept);
  check string "the oldest kept is the first one that fit" "8" (List.hd kept);
  check string "the newest is last" (string_of_int total) (List.nth kept (List.length kept - 1));
  check int "the reply says how many were dropped" 7
    (Yojson.Safe.Util.to_int (member "dropped" (Console.to_json log ~context:"tab-a")));
  check int "another tab drops nothing" 0
    (Yojson.Safe.Util.to_int (member "dropped" (Console.to_json log ~context:"tab-b")))

let test_a_long_text_is_cut_on_a_character_boundary_and_says_so () =
  let log = Console.create () in
  (* Each U+AC00 is three bytes, so the limit falls inside a character. *)
  let text = String.concat "" (List.init (Console.text_bytes_limit / 3 + 5) (fun _ -> "\xea\xb0\x80")) in
  record log (entry text);
  let row = List.hd (entries log ~context:"tab-a") in
  let kept = Yojson.Safe.Util.to_string (member "text" row) in
  check bool "the text is cut" true (String.length kept <= Console.text_bytes_limit && String.length kept < String.length text);
  check bool "the cut text is valid UTF-8" true (String.is_valid_utf_8 kept);
  check bool "the entry says it was cut" true (member "textCut" row = `Bool true)

let test_a_malformed_event_is_an_error_not_a_dropped_entry () =
  let log = Console.create () in
  let without key = match entry "x" with
    | `Assoc fields -> `Assoc (List.remove_assoc key fields) | other -> other in
  List.iter (fun key ->
    check bool ("missing " ^ key ^ " is refused") true (Result.is_error (Console.event log (without key))))
    [ "type"; "level"; "text"; "timestamp"; "source" ];
  check bool "a source without a context is refused" true
    (Result.is_error (Console.event log (match entry "x" with
       | `Assoc fields -> `Assoc (("source", obj []) :: List.remove_assoc "source" fields) | other -> other)));
  check bool "a non-integer timestamp is refused" true
    (Result.is_error (Console.event log (match entry "x" with
       | `Assoc fields -> `Assoc (("timestamp", `String "1") :: List.remove_assoc "timestamp" fields) | other -> other)));
  check (list string) "nothing was recorded by the refused events" [] (texts log ~context:"tab-a")

let test_the_verb_round_trips_and_is_automation_only () =
  let verb = Browser_lane.Page_console { tab_id = 3 } in
  check string "wire name" "page.console" (Browser_lane.verb_to_string verb);
  check bool "the wire carries the tab" true
    (Browser_lane.verb_json verb = obj [ "verb", `String "page.console"; "args", obj [ "tabId", `Int 3 ] ]);
  check bool "a read" true (Browser_lane.verb_is_read verb);
  check bool "automation serves it" true (Browser_lane.verb_allowed_on_automation verb);
  check bool "Stagehand does not" false (Browser_lane.verb_allowed_on_stagehand verb);
  check bool "a connected browser does not" false (Browser_lane.verb_allowed_on_live verb);
  match Masc.Browser_addon_wire.verb_of_json ~route:Browser_lane.Automation_route (Browser_lane.verb_json verb) with
  | Ok parsed -> check bool "the Add-on wire parses it back" true (parsed = verb)
  | Error detail -> fail detail

let test_the_capability_table () =
  let module Cap = Masc.Browser_capabilities in
  let reaches backend = match Cap.support backend Cap.Read_console with
    | Cap.Available _ | Cap.Conditional _ -> true | Cap.Unsupported _ -> false in
  check bool "the owned Firefox reads the console" true (reaches Cap.Owned_gecko);
  List.iter (fun (label, backend) -> check bool (label ^ " does not") false (reaches backend))
    [ "live BiDi", Cap.Connected Browser_lane.Webdriver_bidi; "the extension", Cap.Connected Browser_lane.Web_extension
    ; "Stagehand", Cap.Owned_chromium; "Safari", Cap.Safari_unavailable ]

let () = run "browser console" [ "console", [
  test_case "entries are kept in order per tab" `Quick test_entries_are_kept_in_order_per_tab;
  test_case "the oldest drop and are counted" `Quick test_the_oldest_entries_drop_and_are_counted;
  test_case "a long text is cut on a character boundary" `Quick test_a_long_text_is_cut_on_a_character_boundary_and_says_so;
  test_case "a malformed event is an error" `Quick test_a_malformed_event_is_an_error_not_a_dropped_entry;
  test_case "the verb is automation only" `Quick test_the_verb_round_trips_and_is_automation_only;
  test_case "the capability table" `Quick test_the_capability_table ] ]
