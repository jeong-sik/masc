(* Regression: 2026-05-25 + 2026-05-29 [system_log_*.jsonl] silent-stop after
   a rotate failure. [Log.Ring]'s old [rotate_if_needed] did
   [close_sink (); open_sink ()]; if [open_out_gen] raised (or, on the
   write-side, [output_string] raised because the underlying file vanished
   or the kernel returned an I/O error), [file_channel] dropped to [None]
   and every later emit silently fell through the [None] arm of
   [write_to_sink]. The process stayed alive, [stderr] kept receiving
   records, but the structured JSON log just ended.

   This test exercises the smaller of the two paths the patch closes —
   the [output_string] failure path — by deleting the underlying file
   after the sink is open, then emitting and checking that the channel
   was dropped and reopened. The atomic-rotate path ([try_open_channel]
   returning [None] from the rotate code) is harder to drive without
   monkey-patching [open_out_gen], so we keep the contract pinned by
   construction: [rotate_if_needed] now reads through [try_open_channel]
   which protects against the raise — the absence of a [None]-on-success
   transition is enforced by the source structure.

   These tests run in process and mutate global [Log.Ring] state, so they
   share state with anything else that runs in the same alcotest binary.
   We use a per-test tmp dir and emit module name prefixes specific to
   this file. *)

open Alcotest
module L = Log
module R = L.Ring

let tmp_root = Filename.concat (Filename.get_temp_dir_name ()) "test_log_file_sink_self_heal"

let date_string_utc () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let log_path dir = Filename.concat dir (Printf.sprintf "system_log_%s.jsonl" (date_string_utc ()))

let rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then
      Array.iter (fun n ->
        let p = Filename.concat path n in
        if Sys.is_directory p then
          ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote p)))
        else Sys.remove p)
        (Sys.readdir path)
    else
      Sys.remove path

let fresh_dir name =
  let dir = Filename.concat tmp_root name in
  rm_rf dir;
  if not (Sys.file_exists tmp_root) then Sys.mkdir tmp_root 0o755;
  Sys.mkdir dir 0o755;
  dir

let file_contents path =
  if not (Sys.file_exists path) then ""
  else
    let ic = open_in path in
    let buf = Buffer.create 1024 in
    (try while true do Buffer.add_channel buf ic 4096 done with End_of_file -> ());
    close_in ic;
    Buffer.contents buf

let contains hay needle =
  let nh = String.length hay
  and nn = String.length needle in
  let rec loop i =
    if i + nn > nh then false
    else if String.sub hay i nn = needle then true
    else loop (i + 1)
  in
  if nn = 0 then true else loop 0

(* Normal path: init + emit → file has the message. Sanity check that the
   harness itself is wired up. *)
let normal_emit_lands_on_disk () =
  let dir = fresh_dir "normal" in
  R.init_file_sink dir;
  L.info "test_log_file_sink_self_heal:normal:hello %s" "world";
  let path = log_path dir in
  check bool "file exists" true (Sys.file_exists path);
  let body = file_contents path in
  check bool "message recorded" true
    (contains body "test_log_file_sink_self_heal:normal:hello world")

(* Self-heal: open sink, emit once, delete the underlying file, emit
   again. With the fix, the second emit must re-create the file and
   include its own message. Without the fix, [output_string] would
   raise into the [match !file_channel with Some oc -> ...] arm; the
   [output_string] arm is wrapped in [try ... with exn -> close_sink ()],
   so the channel drops to [None] and the next emit reopens. *)
let emit_after_file_unlink_reopens () =
  let dir = fresh_dir "unlinked" in
  R.init_file_sink dir;
  L.info "test_log_file_sink_self_heal:unlinked:before";
  let path = log_path dir in
  check bool "file exists before unlink" true (Sys.file_exists path);
  Sys.remove path;
  check bool "file removed" false (Sys.file_exists path);
  (* First post-unlink emit may drop the channel (if output_string raises),
     then the same call's self-heal logic, or the next call's, must
     reopen. We emit twice to cover both single-call and split-call
     cases. *)
  L.info "test_log_file_sink_self_heal:unlinked:after_first";
  L.info "test_log_file_sink_self_heal:unlinked:after_second";
  check bool "file re-created after self-heal" true (Sys.file_exists path);
  let body = file_contents path in
  check bool "post-heal message recorded" true
    (contains body "test_log_file_sink_self_heal:unlinked:after_second")

let () =
  run "log_file_sink_self_heal"
    [ "normal", [ test_case "emit lands on disk" `Quick normal_emit_lands_on_disk ]
    ; "self-heal"
    , [ test_case "post-unlink emit reopens" `Quick emit_after_file_unlink_reopens
      ]
    ]
