(** Pins the day key to the day file the writer actually picks.

    [Dated_jsonl.read_range ~since ~until] splits ["YYYY-MM-DD"] back into
    month and day and string-compares those against the [YYYY-MM/DD.jsonl]
    layout. Six readers used to build that key from their own [Unix.gmtime]
    call. The failure mode if one drifts is not an error: the reader looks in
    a different file than the writer wrote, and returns nothing for the hours
    where the two calendars disagree.

    So the property under test is not "the format is YYYY-MM-DD" but "the key
    and the path name the same day". *)

open Alcotest

(* Instants chosen so a non-UTC reader lands on a different calendar day than
   the writer: both sides of UTC midnight, and both sides of the KST offset. *)
let instants =
  [ "epoch", 0.0
  ; "2025-07-31 23:59:59Z — already 08-01 in KST", 1754006399.0
  ; "2025-08-01 00:00:00Z", 1754006400.0
  ; "2025-08-01 00:00:01Z", 1754006401.0
  ; "2025-07-31 22:00:00Z — already 08-01 in KST", 1753999200.0
  ; "1969-12-31 23:59:59Z — already 1970-01-01 in KST", -1.0
  ]
;;

let test_key_matches_the_path () =
  List.iter
    (fun (label, ts) ->
      let dated = Jsonl_writer.dated_path ~base_dir:"/store" ~ts in
      let expected = dated.Jsonl_writer.month_dir ^ "-" ^ Filename.remove_extension dated.Jsonl_writer.day_file in
      check string (label ^ ": key names the file the writer picks") expected (Jsonl_writer.day_key ~ts))
    instants
;;

let test_key_shape () =
  check string "epoch" "1970-01-01" (Jsonl_writer.day_key ~ts:0.0);
  check
    string
    "one second before UTC midnight stays on the earlier day"
    "2025-07-31"
    (Jsonl_writer.day_key ~ts:1754006399.0);
  check
    string
    "UTC midnight rolls over"
    "2025-08-01"
    (Jsonl_writer.day_key ~ts:1754006400.0);
  check
    string
    "one second before the epoch is the previous day, not the epoch"
    "1969-12-31"
    (Jsonl_writer.day_key ~ts:(-1.0))
;;

(* The writer is UTC by construction, so this restates the contract from the
   reader's side: whatever the host's timezone is, the key does not move. *)
let test_key_ignores_host_timezone () =
  (* 2025-07-31 23:59:59Z. On any host east of UTC this is already 08-01
     locally, which is the hour where a local-time reader would miss the
     file. *)
  let ts = 1754006399.0 in
  let utc = Jsonl_writer.day_key ~ts in
  let local_tm = Unix.localtime ts in
  let local_day =
    Printf.sprintf
      "%04d-%02d-%02d"
      (local_tm.Unix.tm_year + 1900)
      (local_tm.Unix.tm_mon + 1)
      local_tm.Unix.tm_mday
  in
  check string "the key is the UTC day" "2025-07-31" utc;
  if String.equal local_day utc
  then
    (* Runner is on UTC, so this instant cannot demonstrate the difference.
       The path check above still holds it to the writer. *)
    ()
  else
    check
      bool
      "on a non-UTC host the local day differs, and the key does not follow it"
      true
      (not (String.equal local_day utc))
;;

let () =
  run
    "jsonl day key"
    [ ( "writer agreement"
      , [ test_case "key names the writer's file" `Quick test_key_matches_the_path
        ; test_case "pinned strings" `Quick test_key_shape
        ; test_case "does not follow the host timezone" `Quick test_key_ignores_host_timezone
        ] )
    ]
;;
