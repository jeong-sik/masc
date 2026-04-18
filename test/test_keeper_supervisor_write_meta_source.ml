(** Structural guard for issue #8391 HIGH #3.

    [lib/keeper/keeper_supervisor.ml] used [ignore (write_meta ...)] inside
    [supervise_keepalive]'s presence sync. A write failure silently dropped
    the error while the in-memory [Keeper_registry] entry still advertised
    the synced meta → registry/disk divergence with no log line.

    This test pins the fix:

    - (a) the raw [ignore (write_meta ...)] pattern must not reappear in
          [keeper_supervisor.ml]
    - (b) the file must keep a [match write_meta ...] with an [Error]
          arm (any observable handling), so the failure is not discarded
          again by refactors.

    Structural (source grep) rather than behavioural because the call
    site is inside [supervise_keepalive], which requires a full Coord /
    Keeper_registry fixture to exercise; the risk we guard against is
    exactly that someone collapses the handler back to [ignore] during
    cleanup.
*)

open Alcotest

let target_file = "lib/keeper/keeper_supervisor.ml"

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "source file not found: %s" path)
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic)

let contains_re haystack re =
  try
    let _ = Str.search_forward re haystack 0 in
    true
  with Not_found -> false

let test_no_ignore_write_meta () =
  let src = load_source target_file in
  let re = Str.regexp "ignore[ \t]*([ \t]*write_meta" in
  check bool
    "keeper_supervisor.ml must not call `ignore (write_meta ...)` (silent failure — issue #8391 HIGH #3)"
    false
    (contains_re src re)

let test_error_arm_present () =
  let src = load_source target_file in
  (* Fix must keep a match on write_meta with an Error arm, so a future
     refactor cannot re-silence the failure. *)
  let match_re = Str.regexp "match[ \t\n]+write_meta" in
  let error_re = Str.regexp "|[ \t]*Error" in
  check bool
    "keeper_supervisor.ml must retain `match write_meta ...` handling"
    true
    (contains_re src match_re);
  check bool
    "keeper_supervisor.ml must retain an `Error` arm near write_meta"
    true
    (contains_re src error_re)

let () =
  run "keeper_supervisor_write_meta_source" [
    "silent_failure_guard", [
      test_case "no `ignore (write_meta ...)`" `Quick test_no_ignore_write_meta;
      test_case "match write_meta + Error arm present" `Quick test_error_arm_present;
    ];
  ]
