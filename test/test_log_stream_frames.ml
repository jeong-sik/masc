(* The log stream sends a client the entries its query selects that are newer
   than its cursor, resets the client's list when it has no cursor, when the
   ring evicted what it never got, or when more matched than the page holds,
   and waits on the ring for the next entry. *)

open Alcotest
open Masc

module Stream = Server_routes_http_routes_log_stream

let module_name = "log-stream-test"
let other_module = "log-stream-other"

let query ?(limit = 3) () : Server_logs_query.t =
  { limit
  ; level_filter = "WARN"
  ; applied_level = Log.Warn
  ; min_level = Log.level_to_int Log.Warn
  ; module_filter = module_name
  ; since_seq = None
  ; before_seq = None
  ; category_filter = None
  ; exclude_category = None
  }

let push ?(module_name = module_name) message = Log.emit Log.Warn ~module_name message

let messages (frame : Stream.frame) =
  List.map (fun (entry : Log.Ring.entry) -> entry.message) frame.entries

let test_frames_follow_the_cursor () =
  push "one";
  let first = Stream.next_frame (query ()) ~after:None in
  check bool "no cursor resets" true first.reset;
  check int "the cursor is the last sequence handed out" ((Log.Ring.bounds ()).total - 1)
    first.after;
  push "two";
  push "three";
  let second = Stream.next_frame (query ()) ~after:(Some first.after) in
  check bool "entries after the cursor do not reset" false second.reset;
  check (list string) "only the new entries, newest first" [ "three"; "two" ] (messages second);
  push ~module_name:other_module "elsewhere";
  let third = Stream.next_frame (query ()) ~after:(Some second.after) in
  check (list string) "an entry the query leaves out sends nothing" [] (messages third);
  check bool "and resets nothing" false third.reset;
  check bool "the cursor still moves past it" true (third.after > second.after)

let test_an_exact_page_appends () =
  let start = (Log.Ring.bounds ()).total - 1 in
  List.iter push [ "a"; "b"; "c" ];
  let frame = Stream.next_frame (query ~limit:3 ()) ~after:(Some start) in
  check bool "an exact page does not discard prior history" false frame.reset;
  check (list string) "all exact-page entries arrive newest first" [ "c"; "b"; "a" ] (messages frame)

let test_more_than_a_page_resets () =
  let start = (Log.Ring.bounds ()).total - 1 in
  List.iter push [ "a"; "b"; "c"; "d" ];
  let frame = Stream.next_frame (query ~limit:3 ()) ~after:(Some start) in
  check bool "more matches than the page resets" true frame.reset;
  check (list string) "to the newest page" [ "d"; "c"; "b" ] (messages frame)

let test_a_cursor_older_than_the_ring_resets () =
  push "kept";
  let frame = Stream.next_frame (query ()) ~after:(Some ((Log.Ring.bounds ()).start_seq - 2)) in
  check bool "entries the client never got were evicted" true frame.reset

let test_the_wait_ends_on_the_next_entry () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let last = (Log.Ring.bounds ()).total - 1 in
  Log.Ring.await_newer_than (last - 1);
  let woke = ref false in
  Eio.Fiber.both
    (fun () ->
      match Eio.Time.with_timeout clock 5.0 (fun () -> Ok (Log.Ring.await_newer_than last)) with
      | Ok () -> woke := true
      | Error `Timeout -> ())
    (fun () ->
      Eio.Fiber.yield ();
      push "wake");
  check bool "an entry pushed while waiting ends the wait" true !woke

let () =
  run "log_stream_frames"
    [ ( "frames"
      , [ test_case "frames follow the cursor" `Quick test_frames_follow_the_cursor
        ; test_case "an exact page appends" `Quick test_an_exact_page_appends
        ; test_case "more than a page resets" `Quick test_more_than_a_page_resets
        ; test_case "a cursor older than the ring resets" `Quick
            test_a_cursor_older_than_the_ring_resets
        ; test_case "the wait ends on the next entry" `Quick test_the_wait_ends_on_the_next_entry
        ] )
    ]
