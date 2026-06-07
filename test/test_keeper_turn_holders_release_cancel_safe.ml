(* test/test_keeper_turn_holders_release_cancel_safe.ml

   Regression guard for the 2026-05-05 fleet-stuck cycle:
   [release_turn_holder] called bookkeeping functions
   (drop_autonomous_waiter / drop_holder / record_autonomous_completion)
   directly. These functions use [Eio.Mutex.use_rw ~protect:true],
   which can raise [Eio.Cancel.Cancelled] when the fiber is being
   torn down. Because the call sat in a [Fun.protect ~finally]
   block, the admission-token release line was never reached and
   the slot leaked permanently — turn_available pinned at 0 while
   the entire 14-keeper fleet skipped turns with "wait > 180s".

   The current fix makes [Keeper_turn_admission.token] the single ownership
   object: normal finalization releases that token, force-release releases the
   same token by keeper name, and fleet stop resolves the token cancellation
   promise so the surrounding switch fails instead of waiting for a natural
   return. This test asserts the structural pattern by anchored substring
   search, so a future refactor that removes the guard fails CI before it
   deadlocks production.

   Why structural rather than behavioural: deterministically
   raising Cancelled inside a sub-mutex during fiber teardown
   requires a non-trivial Eio.Switch + Cancel.protect harness.
   The fix mirrors the prior-art pattern in
   [lib/keeper/keeper_unified_turn.ml] (issue #9747), so the
   regression risk we guard against is "someone removes the
   wrap", which a substring assertion catches cheaply. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let assert_contains ~label haystack needle =
  if not (String.length haystack >= String.length needle) then
    failwith (Printf.sprintf "[%s] file too short to contain %S" label needle);
  (* naive substring search; OCaml stdlib has no built-in *)
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else scan (i + 1)
  in
  if not (scan 0) then
    failwith
      (Printf.sprintf
         "[%s] expected source to contain %S — fix \
          regression: central admission must own token release, see 2026-05-05 \
          fleet-stuck cycle"
         label needle)

let assert_not_contains ~label haystack needle =
  let n = String.length needle in
  let h = String.length haystack in
  let rec scan i =
    i + n <= h && (String.sub haystack i n = needle || scan (i + 1))
  in
  if n = 0 || scan 0 then
    failwith (Printf.sprintf "[%s] source must not contain %S" label needle)

let () =
  (* Resolve the source via the test exe location.  dune places
     the binary at:
       <project>/_build/default/test/<name>.exe
     so [parent x4] = the build/default subdir of the project.
     This is robust regardless of CWD or sandbox layout. *)
  (* exe is at <root>/_build/default/test/<name>.exe — climb 4
     levels to reach <root>, then descend into the source tree. *)
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let read_source rel_path =
    let candidates =
      [ Filename.concat project_root rel_path
      ; rel_path
      ; Filename.concat ".." rel_path
      ; Filename.concat "../.." rel_path
      ]
    in
    match List.find_opt Sys.file_exists candidates with
    | Some p -> read_file p
    | None ->
      failwith
        (Printf.sprintf
           "none of the candidate source paths resolved \
            (cwd=%s, exe=%s): %s"
           (Sys.getcwd ()) exe (String.concat ", " candidates))
  in
  let admission_src = read_source "lib/keeper/keeper_turn_admission.ml" in
  (* Central admission owns normal release, forced release, and fleet-stop
     cancellation. Holder diagnostics are intentionally not required for
     token release. *)
  let must_contain =
    [ "normal token release",
      {|let cleanup () = release_turn token|}
    ; "switch finalizer cleanup",
      {|Eio.Switch.on_release turn_sw cleanup|}
    ; "stop watcher is daemon",
      {|Eio.Fiber.fork_daemon ~sw:turn_sw|}
    ; "fleet stop cancellation promise",
      {|Eio.Promise.await token.cancel_p|}
    ; "fleet stop switch failure",
      {|Eio.Switch.fail turn_sw Fleet_stopped_by_operator|}
    ; "force release entry",
      {|let force_release_keeper ~keeper_name =|}
    ; "force release releases capacity",
      {|release_global_capacity ()|}
    ; "force release cancels token",
      {|request_cancel_token token|}
    ; "idempotent release guard",
      {|Atomic.compare_and_set token.released false true|}
    ]
  in
  List.iter
    (fun (label, needle) -> assert_contains ~label admission_src needle)
    must_contain;
  let supervisor_src = read_source "lib/keeper/keeper_supervisor.ml" in
  assert_contains
    ~label:"supervisor force releases central admission"
    supervisor_src
    {|Keeper_turn_admission.force_release_keeper ~keeper_name:entry.name|};
  let heartbeat_src = read_source "lib/keeper/keeper_heartbeat_loop.ml" in
  assert_contains
    ~label:"heartbeat records holder diagnostics through facade"
    heartbeat_src
    "Keeper_turn_holders.with_recorded_turn_admission";
  assert_not_contains
    ~label:"central admission stop watcher must not depend only on Eio_guard"
    admission_src
    "if Eio_guard.is_ready ()";
  assert_contains
    ~label:"fleet stop expected heartbeat path"
    heartbeat_src
    "| Keeper_turn_admission.Fleet_stopped_by_operator ->";
  assert_contains
    ~label:"fleet stop heartbeat log"
    heartbeat_src
    "keeper cycle cancelled because fleet admission was stopped";
  print_endline "test_keeper_turn_holders_release_cancel_safe: OK"
