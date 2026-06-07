(* test/test_keeper_turn_slot_release_cancel_safe.ml

   Regression guard for the 2026-05-05 fleet-stuck cycle:
   [release_keeper_turn_slot] called bookkeeping functions
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
          regression: release_keeper_turn_slot must wrap \
          bookkeeping in safe_bookkeeping, see 2026-05-05 \
          fleet-stuck cycle"
         label needle)

let () =
  (* Resolve the source via the test exe location.  dune places
     the binary at:
       <project>/_build/default/test/<name>.exe
     so [parent x4] = the build/default subdir of the project,
     and the source is at [.../lib/keeper/keeper_turn_slot.ml].
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
  let src = read_source "lib/keeper/keeper_turn_slot.ml" in
  (* The cancel-safe release path has two cleanup shapes:
     recorded-holder release catches [consume_force_release] failures, while
     token release is wired through the switch finalizer and force-release
     path. Ordering is not asserted; the source contract only pins each
     ownership path. *)
  let must_contain =
    [ "token field",
      {|admission_token : Keeper_turn_admission.token option ref|}
    ; "normal token release",
      {|Keeper_turn_admission.release_turn token|}
    ; "force release token",
      {|Keeper_turn_admission.force_release_keeper ~keeper_name|}
    ; "switch finalizer cleanup",
      {|Eio.Switch.on_release turn_sw cleanup|}
    ; "fleet stop cancellation promise",
      {|Keeper_turn_admission.token_cancel_p admission_token|}
    ; "fleet stop switch failure",
      {|Eio.Switch.fail turn_sw Keeper_turn_admission.Fleet_stopped_by_operator|}
    ; "drop_holder cancellation catch",
      {|release_keeper_turn_slot: drop_holder skipped (Cancelled)|}
    ]
  in
  List.iter
    (fun (label, needle) -> assert_contains ~label src needle)
    must_contain;
  (* The cleanup helpers must catch Cancelled — assert the catch arm exists
     so a future refactor can't silently widen cleanup to swallow only generic
     [exn]. *)
  assert_contains
    ~label:"cleanup catches Cancelled"
    src
    "Eio.Cancel.Cancelled _ ->";
  assert_contains
    ~label:"drop_holder metrics cancelled"
    src
    {|observe_bookkeeping_failure ~op:"drop_holder" ~kind:Keeper_bookkeeping_failure_kind.Cancelled|};
  assert_contains
    ~label:"drop_holder metrics exception"
    src
    {|observe_bookkeeping_failure ~op:"drop_holder" ~kind:Keeper_bookkeeping_failure_kind.Exception|};
  assert_contains
    ~label:"bookkeeping metric name"
    src
    "Keeper_metrics.(to_string TurnSlotBookkeepingFailures)";
  let heartbeat_src = read_source "lib/keeper/keeper_heartbeat_loop.ml" in
  assert_contains
    ~label:"fleet stop expected heartbeat path"
    heartbeat_src
    "| Keeper_turn_admission.Fleet_stopped_by_operator ->";
  assert_contains
    ~label:"fleet stop heartbeat log"
    heartbeat_src
    "keeper cycle cancelled because fleet admission was stopped";
  print_endline "test_keeper_turn_slot_release_cancel_safe: OK"
