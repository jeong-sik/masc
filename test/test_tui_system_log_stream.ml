(* The TUI reads the server log stream as SSE frames, however the bytes are
   cut, skips keepalive comments, and lands each frame on the page: a reset
   replaces it, any other frame goes on top and the page keeps the newest
   [limit]. *)

open Alcotest
module Stream = Masc_tui_system_log_stream

let module_name = "tui-log-stream-test"

(* Entries as the server writes them, from this process's ring. *)
let entries messages =
  List.iter (fun message -> Log.emit Log.Warn ~module_name message) messages;
  Log.Ring.recent ~limit:(List.length messages) ~module_filter:module_name ()
  |> List.map Log.Ring.entry_to_json

let frame_text ~reset entries =
  let latest =
    match entries with
    | [] -> `Null
    | entry :: _ -> Yojson.Safe.Util.member "seq" entry
  in
  "data: "
  ^ Yojson.Safe.to_string
      (`Assoc
        [ "reset", `Bool reset
        ; "entries", `List entries
        ; "total", `Int (List.length entries)
        ; "latest_seq", latest
        ])
  ^ "\n\n"

let messages (snapshot : Masc.Tui_decode.system_log_snapshot) =
  List.map (fun (entry : Masc.Tui_decode.system_log_entry) -> entry.sl_message) snapshot.sys_entries

let frames reader chunks =
  List.concat_map (Stream.feed reader) chunks
  |> List.map (function
    | Ok frame -> frame
    | Error detail -> fail detail)

let test_frames_survive_any_cut () =
  let text = frame_text ~reset:true (entries [ "first"; "second" ]) in
  let cut = String.length text / 2 in
  let reader = Stream.create () in
  match
    frames reader
      [ ": keepalive\n\n"; String.sub text 0 cut; String.sub text cut (String.length text - cut) ]
  with
  | [ frame ] ->
    check bool "the frame resets" true frame.reset;
    check (list string) "its entries, newest first" [ "second"; "first" ] (messages frame.snapshot)
  | other -> failf "expected one frame, got %d" (List.length other)

let test_frames_land_on_the_page () =
  let reader = Stream.create () in
  let page = ref None in
  let take text =
    List.iter (fun frame -> page := Some (Stream.apply ~limit:3 frame !page)) (frames reader [ text ])
  in
  take (frame_text ~reset:true (entries [ "a"; "b" ]));
  take (frame_text ~reset:false (entries [ "c"; "d" ]));
  (match !page with
   | Some snapshot ->
     check (list string) "new entries on top, the page keeps three" [ "d"; "c"; "b" ] (messages snapshot);
     check (option int) "the cursor is the newest entry" snapshot.sys_latest_seq (Stream.cursor !page)
   | None -> fail "no page");
  take (frame_text ~reset:true (entries [ "e" ]));
  match !page with
  | Some snapshot -> check (list string) "a reset replaces the page" [ "e" ] (messages snapshot)
  | None -> fail "no page"

let test_a_frame_that_does_not_decode_is_an_error () =
  let reader = Stream.create () in
  match Stream.feed reader "data: {\"entries\":[]}\n\n" with
  | [ Error _ ] -> ()
  | _ -> fail "a frame with no reset flag was accepted"

(* A dropped connection leaves its error on the page. A reconnect with nothing
   new to say sends only keepalives, so the page must lose that error when the
   server accepts the stream again, and nothing else. *)
let test_a_reconnect_without_entries_clears_the_error () =
  let module View = Masc_tui_system_logs in
  let reader = Stream.create () in
  let first =
    match frames reader [ frame_text ~reset:true (entries [ "kept" ]) ] with
    | [ frame ] -> frame
    | other -> failf "expected one frame, got %d" (List.length other)
  in
  let view = View.apply View.Server (Ok first.Stream.snapshot) View.empty in
  let view = View.apply View.Server (Error "log stream: connection closed") view in
  check (option string) "the drop is on the page"
    (Some "log stream: connection closed") (View.page View.Server view).View.lp_error;
  let view = View.stream_connected view in
  let page = View.page View.Server view in
  check (option string) "the reconnect clears the error" None page.View.lp_error;
  check (list string) "the held entries stay" [ "kept" ]
    (match page.View.lp_snapshot with Some snapshot -> messages snapshot | None -> [])

let () =
  run "tui_system_log_stream"
    [ ( "frames"
      , [ test_case "frames survive any cut" `Quick test_frames_survive_any_cut
        ; test_case "frames land on the page" `Quick test_frames_land_on_the_page
        ; test_case "a frame that does not decode is an error" `Quick
            test_a_frame_that_does_not_decode_is_an_error
        ; test_case "a reconnect without entries clears the error" `Quick
            test_a_reconnect_without_entries_clears_the_error
        ] )
    ]
