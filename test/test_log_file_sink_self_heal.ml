(* Regression: 2026-05-25 + 2026-05-29 [system_log_*.jsonl] silent-stop after
   a rotate failure. [Log.Ring]'s old [rotate_if_needed] did
   [close_sink (); open_sink ()]; if [open_out_gen] raised (or, on the
   write-side, [output_string] raised because the underlying file vanished
   or the kernel returned an I/O error), [file_channel] dropped to [None]
   and every later emit silently fell through the [None] arm of
   [write_to_sink]. The process stayed alive, [stderr] kept receiving
   records, but the structured JSON log just ended.

   2026-07-17 (#25003): the sink-identity check that detects external
   unlink/rename (a dev/ino stat pair inside [sink_matches_path]) used to
   run on every emit — three stat-family syscalls per record, measured as
   27% of main-thread samples. It is now throttled by
   [identity_recheck_interval_s] (default 5s). The contract changed from
   "external unlink detected on the next emit" to "external unlink detected
   within the interval": records emitted inside the window go to the
   unlinked inode and are lost with it. These tests pin both halves of that
   contract — within the window the check is skipped (no recreate), past
   the window the sink self-heals.

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

(* Removes [path] itself, not just its contents — [fresh_dir] follows with
   [Sys.mkdir], which raises [File exists] on leftovers from a prior run of
   this binary (the tmp root is shared across runs and worktrees). *)
let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Array.iter (fun n -> rm_rf (Filename.concat path n)) (Sys.readdir path);
      Sys.rmdir path
    end
    else Sys.remove path

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

(* Throttle half of the contract: with a long recheck interval, emits that
   land inside the window after an external unlink must NOT recreate the
   file — the identity stat pair is skipped, and the records go to the
   still-open unlinked inode. The absence of the file is the observable
   proof that no stat check ran. *)
let unlink_within_window_is_throttled () =
  let dir = fresh_dir "throttled" in
  R.init_file_sink ~identity_recheck_interval_s:60.0 dir;
  (* First emit consumes the initial identity check (armed at init). *)
  L.info "test_log_file_sink_self_heal:throttled:before";
  let path = log_path dir in
  check bool "file exists before unlink" true (Sys.file_exists path);
  Sys.remove path;
  check bool "file removed" false (Sys.file_exists path);
  L.info "test_log_file_sink_self_heal:throttled:inside_window_1";
  L.info "test_log_file_sink_self_heal:throttled:inside_window_2";
  check bool "file NOT recreated inside the throttle window" false
    (Sys.file_exists path)

(* Self-heal half of the contract: past the recheck interval, the next emit
   must detect the unlink through the identity check, reopen the sink at the
   correct path, and record its own message. *)
let unlink_after_window_recreates () =
  let dir = fresh_dir "unlinked" in
  R.init_file_sink ~identity_recheck_interval_s:0.05 dir;
  L.info "test_log_file_sink_self_heal:unlinked:before";
  let path = log_path dir in
  check bool "file exists before unlink" true (Sys.file_exists path);
  Sys.remove path;
  check bool "file removed" false (Sys.file_exists path);
  Unix.sleepf 0.12;
  L.info "test_log_file_sink_self_heal:unlinked:after_window";
  check bool "file re-created after the throttle window" true
    (Sys.file_exists path);
  let body = file_contents path in
  check bool "post-heal message recorded" true
    (contains body "test_log_file_sink_self_heal:unlinked:after_window")

let () =
  run "log_file_sink_self_heal"
    [ "normal", [ test_case "emit lands on disk" `Quick normal_emit_lands_on_disk ]
    ; "self-heal"
    , [ test_case "unlink inside window stays throttled" `Quick
          unlink_within_window_is_throttled
      ; test_case "unlink past window reopens" `Quick
          unlink_after_window_recreates
      ]
    ]
