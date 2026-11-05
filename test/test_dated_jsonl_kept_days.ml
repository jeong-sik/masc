(* A kept day range reads a day file whole once and afterwards only the bytes
   it gained, re-reads a rotated file without counting it twice, and drops the
   files of days it is no longer asked for. *)

open Alcotest
open Masc
module Kept = Dated_jsonl_kept_days

(* Noon UTC, so the day before is a different day file whatever the clock. *)
let fixed_now = 1_789_992_000.0

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then (
    mkdir_p (Filename.dirname dir);
    Unix.mkdir dir 0o755)

let with_store f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "dated-jsonl-kept-days-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () ->
      let config = Workspace.default_config base in
      let location =
        Dated_jsonl.Store.at (Workspace_utils.dated_store_root config) Provider_usage_history
      in
      f location (Dated_jsonl.open_store location))

let write_line location ~ts line =
  let dated = Dated_jsonl.Store.dated_path location ~ts in
  mkdir_p (Filename.dirname dated.path);
  Out_channel.with_open_gen [ Open_append; Open_creat; Open_binary ] 0o644 dated.path (fun oc ->
    output_string oc line;
    output_char oc '\n')

(* Each file's rows, newest first, as [f] saw them. *)
let collect rows = function
  | Dated_jsonl.Parsed json -> Yojson.Safe.to_string json :: rows
  | Dated_jsonl.Malformed_json _ -> "malformed" :: rows

let refresh store ~days kept =
  match Kept.refresh store ~days ~init:[] ~f:collect kept with
  | Ok kept -> kept
  | Error error -> fail (Dated_jsonl.read_error_to_string error)

let rows kept = Kept.fold kept ~init:[] ~f:(fun acc _day rows -> acc @ List.rev rows)

let test_days_between () =
  let today = Kept.day_of fixed_now in
  let yesterday = Kept.day_of (fixed_now -. Kept.seconds_per_day) in
  check (float 0.) "a day starts on its UTC midnight" (fixed_now -. (Kept.seconds_per_day /. 2.0))
    today.starts_at;
  check (list string) "a day back and today" [ yesterday.date; today.date ]
    (List.map
       (fun (day : Kept.day) -> day.date)
       (Kept.days_between ~since:(fixed_now -. Kept.seconds_per_day) ~until:fixed_now));
  check int "a start after the end is no day" 0
    (List.length (Kept.days_between ~since:(fixed_now +. 1.0) ~until:fixed_now))

let test_a_file_is_read_whole_once_then_only_what_it_gained () =
  with_store (fun location store ->
    let days = [ Kept.day_of fixed_now ] in
    check (list string) "a store that does not exist is empty" [] (rows (refresh store ~days Kept.empty));
    write_line location ~ts:fixed_now {|{"n":1}|};
    write_line location ~ts:fixed_now "{broken";
    let first = refresh store ~days Kept.empty in
    check (list string) "the first read takes every row, a malformed one included"
      [ {|{"n":1}|}; "malformed" ] (rows first);
    (* Rewriting the first row in place and growing the file: a read of the
       whole file would see the rewrite, a read of what it gained does not. *)
    let path = (Dated_jsonl.Store.dated_path location ~ts:fixed_now).path in
    Out_channel.with_open_gen [ Open_wronly; Open_binary ] 0o644 path (fun oc ->
      output_string oc {|{"n":7}|});
    write_line location ~ts:fixed_now {|{"n":2}|};
    let second = refresh store ~days first in
    check (list string) "the next read folds only the appended row"
      [ {|{"n":1}|}; "malformed"; {|{"n":2}|} ] (rows second);
    check (list string) "the value it was given is left as it was"
      [ {|{"n":1}|}; "malformed" ] (rows first))

let test_a_rotated_file_is_not_counted_twice () =
  with_store (fun _location store ->
    let days = [ Kept.day_of (Unix.gettimeofday ()) ] in
    let append n =
      match
        Dated_jsonl.append_rotating store ~max_current_file_bytes:1 (`Assoc [ "n", `Int n ])
      with
      | Dated_jsonl.Appended_to_current | Dated_jsonl.Appended_after_rotation _ -> ()
      | Dated_jsonl.Skipped_by_append_guard | Dated_jsonl.Skipped_rotation_exhausted _ ->
        fail "the append did not land"
    in
    append 1;
    let first = refresh store ~days Kept.empty in
    append 2;
    let second = refresh store ~days first in
    check (list string) "the rotated rows and the new current row, each once"
      [ {|{"n":1}|}; {|{"n":2}|} ]
      (List.sort String.compare (rows second)))

let test_days_left_out_are_dropped () =
  with_store (fun location store ->
    let yesterday = fixed_now -. Kept.seconds_per_day in
    write_line location ~ts:yesterday {|{"day":"yesterday"}|};
    write_line location ~ts:fixed_now {|{"day":"today"}|};
    let both =
      refresh store ~days:(Kept.days_between ~since:yesterday ~until:fixed_now) Kept.empty
    in
    check (list string) "both days, oldest first"
      [ {|{"day":"yesterday"}|}; {|{"day":"today"}|} ] (rows both);
    let today = refresh store ~days:[ Kept.day_of fixed_now ] both in
    check (list string) "a day no longer asked for is dropped" [ {|{"day":"today"}|} ] (rows today))

let () =
  run "dated_jsonl_kept_days"
    [ ( "kept days"
      , [ test_case "days between" `Quick test_days_between
        ; test_case "a file is read whole once, then only what it gained" `Quick
            test_a_file_is_read_whole_once_then_only_what_it_gained
        ; test_case "a rotated file is not counted twice" `Quick
            test_a_rotated_file_is_not_counted_twice
        ; test_case "days left out are dropped" `Quick test_days_left_out_are_dropped
        ] )
    ]
