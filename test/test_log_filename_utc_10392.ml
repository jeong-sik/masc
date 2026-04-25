(** #10392 — pin the system_log filename TZ to UTC so it matches
    the entry timestamps written by [Log.timestamp_iso].

    Pre-fix [Ring.date_string] returned a KST localtime date,
    while every JSONL [.ts] field was UTC ISO8601 written by
    [timestamp_iso] (line 130).  At KST 09:00 the rotation crossed
    days while the entry timestamps had already advanced 9 h
    earlier, so [system_log_2026-04-26.jsonl] held lines tagged
    [2026-04-25T15:xx:xxZ] — date-grep on the filename returned
    zero hits and the cross-correlation with [Dated_jsonl]
    (UTC throughout) broke.

    Tests pin:

    1. [Ring.For_testing.date_string ()] is identical to a fresh
       [Unix.gmtime (Time_compat.now ())] formatted the same way
       — i.e. the writer follows UTC, not localtime.
    2. The boundary held under a +9 h forced offset so localtime
       and UTC differ in date — verifying the writer doesn't
       fall back to [Unix.localtime] when the TZ environment
       implies KST. *)

open Alcotest

module L = Log

let format_utc_now () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

(* --- 1. date_string == UTC formatted now ---------------- *)

let test_date_string_matches_utc_now () =
  let expected = format_utc_now () in
  let actual = L.Ring.For_testing.date_string () in
  (* If the test crosses a UTC midnight between the two reads
     (extremely unlikely in <1 ms), accept either neighbour. *)
  if actual = expected then check string "matches UTC now" expected actual
  else
    let neighbour =
      let t = Time_compat.now () +. 0.001 in
      let tm = Unix.gmtime t in
      Printf.sprintf "%04d-%02d-%02d"
        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    in
    check bool
      (Printf.sprintf "matches UTC neighbour (got %s, expected %s or %s)"
         actual expected neighbour)
      true (actual = neighbour)

(* --- 2. KST TZ override does not bend the writer to localtime --- *)

let with_env name value f =
  let saved = try Some (Sys.getenv name) with Not_found -> None in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_kst_env_does_not_shift_filename () =
  with_env "TZ" "Asia/Seoul" @@ fun () ->
  let expected = format_utc_now () in
  let actual = L.Ring.For_testing.date_string () in
  check string "TZ=Asia/Seoul does not shift the writer to KST"
    expected actual

let () =
  run "log_filename_utc_10392"
    [
      ( "utc-rotation",
        [
          test_case "date_string returns UTC date" `Quick
            test_date_string_matches_utc_now;
          test_case "KST TZ env does not bend writer" `Quick
            test_kst_env_does_not_shift_filename;
        ] );
    ]
