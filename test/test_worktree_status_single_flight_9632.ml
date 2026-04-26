(** #9632 root cause: [Worktree_live_context.current_status_lines] held
    a TTL cache but no single-flight gate, so N keepers + dashboard
    fibers hitting an expired cache simultaneously each fork+exec
    [git status --porcelain].  The resulting I/O contention pushed
    individual git invocations past the 15s timeout budget on a large
    local workspace with many worktrees.

    These tests pin the per-repo single-flight contract:

    1. [N] concurrent cache-miss callers collapse into a single git
       invocation (the winner; followers double-check the cache).
    2. Distinct [repo_root] values do NOT serialise — each repo has its
       own gate, so a slow capture for repo A never blocks repo B.

    The test deliberately stalls the captured git invocation to widen
    the race window; without the single-flight gate the pre-#9632 code
    invokes the hook once per domain. *)

open Alcotest
module Wlc = Masc_mcp.Worktree_live_context

(* Helpers ---------------------------------------------------------- *)

let run_concurrent ~workers (f : int -> unit) =
  let ready = Atomic.make 0 in
  let go = Atomic.make false in
  let domains =
    List.init workers (fun idx ->
      Domain.spawn (fun () ->
        ignore (Atomic.fetch_and_add ready 1);
        while not (Atomic.get go) do
          Domain.cpu_relax ()
        done;
        f idx))
  in
  while Atomic.get ready < workers do
    Domain.cpu_relax ()
  done;
  Atomic.set go true;
  List.iter Domain.join domains
;;

let with_hook ~hook k =
  Wlc.set_git_capture_hook_for_tests hook;
  Fun.protect
    ~finally:(fun () ->
      Wlc.clear_git_capture_hook_for_tests ();
      Wlc.clear_status_cache_for_tests ();
      Wlc.clear_single_flight_for_tests ())
    k
;;

(* Reset between tests so cache/single-flight state from one case
   does not silently mask the next. *)
let reset () =
  Wlc.clear_status_cache_for_tests ();
  Wlc.clear_single_flight_for_tests ()
;;

(* 1. Concurrent miss for the same repo -> single git call ---------- *)

let test_concurrent_misses_same_repo_collapse_to_one_git_call () =
  reset ();
  let calls = Atomic.make 0 in
  let hook ~workdir:_ _args =
    Atomic.incr calls;
    (* Stall briefly so concurrent callers DEFINITELY race the gate.
       Without a single-flight gate, every caller fires git in this
       window and this counter climbs to [workers]. *)
    Unix.sleepf 0.05;
    Some [ " M sample.ml" ]
  in
  with_hook ~hook (fun () ->
    let workers = 12 in
    let observed = Array.make workers [] in
    run_concurrent ~workers (fun i ->
      observed.(i) <- Wlc.current_status_lines ~repo_root:"/tmp/repo-A");
    check
      int
      "single-flight collapses N concurrent misses to 1 git call"
      1
      (Atomic.get calls);
    Array.iteri
      (fun i lines ->
         check
           (list string)
           (Printf.sprintf "worker %d sees the captured status" i)
           [ "M sample.ml" ]
           lines)
      observed)
;;

(* 2. Distinct repos run in parallel — no cross-repo serialisation -- *)

let test_distinct_repos_do_not_serialise () =
  reset ();
  (* Each repo's hook records its own call count and overlap. A correct
     per-repo gate lets repo A and repo B execute concurrently; a single
     global gate would keep [max_active] at 1. *)
  let calls_a = Atomic.make 0 in
  let calls_b = Atomic.make 0 in
  let active = Atomic.make 0 in
  let max_active = Atomic.make 0 in
  let enter_capture () =
    let now_active = Atomic.fetch_and_add active 1 + 1 in
    let rec update_max () =
      let current = Atomic.get max_active in
      if now_active > current
      then
        if not (Atomic.compare_and_set max_active current now_active) then update_max ()
    in
    update_max ()
  in
  let leave_capture () = ignore (Atomic.fetch_and_add active (-1)) in
  let hook ~workdir args =
    let _ = args in
    enter_capture ();
    Fun.protect ~finally:leave_capture (fun () ->
      if String.equal workdir "/tmp/repo-A"
      then (
        Atomic.incr calls_a;
        Unix.sleepf 0.02;
        Some [ " M a.ml" ])
      else (
        Atomic.incr calls_b;
        Unix.sleepf 0.02;
        Some [ " M b.ml" ]))
  in
  with_hook ~hook (fun () ->
    let workers = 8 in
    run_concurrent ~workers (fun i ->
      let repo = if i mod 2 = 0 then "/tmp/repo-A" else "/tmp/repo-B" in
      let _ = Wlc.current_status_lines ~repo_root:repo in
      ());
    check int "repo A captured once" 1 (Atomic.get calls_a);
    check int "repo B captured once" 1 (Atomic.get calls_b);
    check int "distinct repos captured concurrently" 2 (Atomic.get max_active))
;;

(* 3. Cache TTL still respected after single-flight returns --------- *)

let test_followers_reuse_cache_not_re_capture () =
  reset ();
  let calls = Atomic.make 0 in
  let hook ~workdir:_ _args =
    Atomic.incr calls;
    Some [ " M sample.ml" ]
  in
  with_hook ~hook (fun () ->
    (* Prime the cache. *)
    let _ = Wlc.current_status_lines ~repo_root:"/tmp/repo-C" in
    check int "primed once" 1 (Atomic.get calls);
    (* Subsequent direct calls within TTL must not invoke the hook,
       even though they pass through the single-flight gate. *)
    for _ = 1 to 10 do
      let _ = Wlc.current_status_lines ~repo_root:"/tmp/repo-C" in
      ()
    done;
    check int "TTL cache reuse after single-flight returns" 1 (Atomic.get calls))
;;

let () =
  run
    "Worktree_status_single_flight_9632"
    [ ( "single-flight"
      , [ test_case
            "concurrent misses same repo collapse to one"
            `Quick
            test_concurrent_misses_same_repo_collapse_to_one_git_call
        ; test_case
            "distinct repos do not serialise"
            `Quick
            test_distinct_repos_do_not_serialise
        ; test_case
            "followers reuse cache"
            `Quick
            test_followers_reuse_cache_not_re_capture
        ] )
    ]
;;
