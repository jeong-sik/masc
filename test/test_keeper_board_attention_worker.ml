(** Tests for Keeper_board_attention_worker: the bounded dispatcher that
    replaces the pre-redesign unbounded-fork path (issue #24886, root
    #21960). *)

module Candidate = Masc.Keeper_board_attention_candidate
module Judgment = Masc.Keeper_board_attention_judgment
module Worker = Masc.Keeper_board_attention_worker

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_base name f =
  let base_path = Filename.temp_dir name "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let meta keeper_name =
  let json =
    `Assoc
      [ "name", `String keeper_name
      ; "agent_name", `String ("keeper-" ^ keeper_name ^ "-agent")
      ; "trace_id", `String ("trace-" ^ keeper_name)
      ; "instructions", `String "Use the lane context and complete the task"
      ; "sandbox_profile", `String "local"
      ; "network_mode", `String "inherit"
      ; "mention_targets", `List [ `String keeper_name ]
      ]
  in
  match Masc.Keeper_meta_json_parse.meta_of_json json with
  | Ok meta -> meta
  | Error detail -> Alcotest.failf "keeper meta fixture invalid: %s" detail
;;

let board_id parse label value =
  match parse value with
  | Ok id -> id
  | Error error -> Alcotest.failf "%s fixture id invalid: %s" label (Masc.Board.show_board_error error)
;;

let post_id value = board_id Masc.Board.Post_id.of_string "post" value
let agent_id value = board_id Masc.Board.Agent_id.of_string "agent" value

let post ~id : Masc.Board.post =
  { id = post_id id
  ; author = agent_id "external-author"
  ; title = "Board update"
  ; body = "Full persisted body"
  ; content = "A new Board observation"
  ; post_kind = Masc.Board.Human_post
  ; meta_json = None
  ; visibility = Masc.Board.Public
  ; created_at = 1.0
  ; updated_at = 2.0
  ; expires_at = 0.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; pinned = false
  ; hearth = None
  ; thread_id = None
  ; origin = None
  }
;;

(* Each fixture candidate needs a distinct [post_id] (it feeds the identity
   hash) so many candidates in one keeper/test do not collide. *)
let candidate ~keeper_name ~post_id ~recorded_at : Candidate.candidate =
  let signal : Masc.Board_dispatch.board_signal =
    { kind = Masc.Board_dispatch.Board_post_created
    ; post_id
    ; author = "external-author"
    ; title = "Board update"
    ; content = "A new Board observation"
    ; hearth = None
    ; updated_at = Some 2.0
    }
  in
  match
    Candidate.of_board_evidence
      ~meta:(meta keeper_name)
      ~recorded_at
      ~signal
      ~post:(post ~id:post_id)
      ~comments:[]
  with
  | Ok candidate -> candidate
  | Error detail -> Alcotest.failf "candidate fixture invalid: %s" detail
;;

let judgment decision : Candidate.judgment =
  { verdict = { Judgment.decision; rationale = "typed structured verdict" }
  ; runtime_id = "configured-structured-judge"
  ; judged_at = 3.0
  }
;;

let with_root_eio_context f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () -> f env clock)
;;

(* Bounded poll: the dispatcher/worker pool run on fibers of the *same*
   domain as the caller only if the caller yields; [Eio.Time.sleep] is the
   yield point that lets them make progress between checks. Fails loudly
   instead of hanging forever on a stuck assertion. *)
let poll_until ~clock ~timeout_s label predicate =
  let step = 0.02 in
  let deadline = Eio.Time.now clock +. timeout_s in
  let rec loop () =
    if predicate ()
    then ()
    else if Eio.Time.now clock >= deadline
    then Alcotest.failf "timed out waiting for: %s" label
    else (
      Eio.Time.sleep clock step;
      loop ())
  in
  loop ()
;;

let load_only ~base_path ~keeper_name =
  match Candidate.load_candidates ~base_path ~keeper_name with
  | Ok candidates -> candidates
  | Error detail -> Alcotest.failf "load_candidates failed: %s" detail
;;

let find_by_id candidates candidate_id =
  List.find_opt (fun (c : Candidate.candidate) -> String.equal c.candidate_id candidate_id) candidates
;;

let test_effective_max_concurrency_respects_runtime_binding () =
  Alcotest.(check int)
    "runtime binding narrows the subsystem cap"
    1
    (Worker.For_testing.effective_max_concurrency ~configured:4 ~runtime_limit:(Some 1));
  Alcotest.(check int)
    "subsystem cap remains when the runtime omits a limit"
    4
    (Worker.For_testing.effective_max_concurrency ~configured:4 ~runtime_limit:None)
;;

let test_boot_scan_expires_stale_rows_and_drains_fresh_rows_bounded () =
  with_temp_base "board-attention-worker-boot" @@ fun base_path ->
  with_root_eio_context @@ fun _env clock ->
  let keeper_name = "boot-keeper" in
  let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "board_attention_candidates" in
  Fs_compat.mkdir_p dir;
  let path = Filename.concat dir (keeper_name ^ ".jsonl") in
  (* recorded_at far enough in the past to exceed the default
     max_pending_age_sec (259200s = 3 days) regardless of wall-clock skew. *)
  let stale_recorded_at = Time_compat.now () -. (400_000.0) in
  let stale_candidates =
    List.init 3 (fun i -> candidate ~keeper_name ~post_id:(Printf.sprintf "stale-%d" i) ~recorded_at:stale_recorded_at)
  in
  let fresh_candidates =
    List.init 5 (fun i -> candidate ~keeper_name ~post_id:(Printf.sprintf "fresh-%d" i) ~recorded_at:(Time_compat.now ()))
  in
  let oc = open_out_bin path in
  List.iter
    (fun c -> output_string oc (Yojson.Safe.to_string (Candidate.candidate_to_json c) ^ "\n"))
    (stale_candidates @ fresh_candidates);
  close_out oc;
  let judge_calls = ref 0 in
  let in_flight = ref 0 in
  let max_in_flight = ref 0 in
  let judge (_ : Candidate.candidate) =
    incr judge_calls;
    incr in_flight;
    if !in_flight > !max_in_flight then max_in_flight := !in_flight;
    Eio.Time.sleep clock 0.03;
    decr in_flight;
    Ok (judgment Judgment.Not_relevant)
  in
  Eio.Switch.run
  @@ fun sw ->
  Worker.For_testing.start_with_judge ~sw ~clock ~base_path ~max_concurrency:2 ~judge ();
  poll_until ~clock ~timeout_s:5.0 "boot backlog fully drained" (fun () ->
    let loaded = load_only ~base_path ~keeper_name in
    List.for_all
      (fun (c : Candidate.candidate) ->
         match c.status with
         | Candidate.Terminal_failed _ | Candidate.Consumed _ -> true
         | Candidate.Pending _ | Candidate.Judged _ | Candidate.Deferred _ -> false)
      loaded);
  let loaded = load_only ~base_path ~keeper_name in
  List.iter
    (fun (stale : Candidate.candidate) ->
       match find_by_id loaded stale.candidate_id with
       | Some { status = Candidate.Terminal_failed { reason = Candidate.Expired_backlog _; _ }; _ } -> ()
       | _ -> Alcotest.failf "stale boot row %s did not expire" stale.candidate_id)
    stale_candidates;
  List.iter
    (fun (fresh : Candidate.candidate) ->
       match find_by_id loaded fresh.candidate_id with
       | Some { status = Candidate.Consumed { delivery = Candidate.Not_relevant; _ }; _ } -> ()
       | _ -> Alcotest.failf "fresh boot row %s was not judged" fresh.candidate_id)
    fresh_candidates;
  Alcotest.(check int) "judge invoked only for the fresh rows" 5 !judge_calls;
  Alcotest.(check bool) "fresh drain stayed within max_concurrency=2" true (!max_in_flight <= 2)
;;

let test_storm_bounded_concurrency_each_candidate_judged_once () =
  with_temp_base "board-attention-worker-storm" @@ fun base_path ->
  with_root_eio_context @@ fun _env clock ->
  let keeper_names = [ "storm-a"; "storm-b"; "storm-c" ] in
  let candidates =
    List.concat_map
      (fun keeper_name ->
         List.init 17 (fun i ->
           candidate ~keeper_name ~post_id:(Printf.sprintf "%s-post-%d" keeper_name i) ~recorded_at:(Time_compat.now ())))
      keeper_names
    (* 3 keepers x 17 = 51, comfortably over the max_concurrency=4 bound. *)
  in
  let in_flight = ref 0 in
  let max_in_flight = ref 0 in
  let judged = Hashtbl.create 64 in
  let judge (c : Candidate.candidate) =
    incr in_flight;
    if !in_flight > !max_in_flight then max_in_flight := !in_flight;
    Eio.Time.sleep clock 0.03;
    Hashtbl.replace judged c.candidate_id (1 + (Option.value ~default:0 (Hashtbl.find_opt judged c.candidate_id)));
    decr in_flight;
    Ok (judgment Judgment.Not_relevant)
  in
  Eio.Switch.run
  @@ fun sw ->
  Worker.For_testing.start_with_judge ~sw ~clock ~base_path ~max_concurrency:4 ~judge ();
  List.iter
    (fun c ->
       match Worker.record_and_notify ~base_path c with
       | Ok _ -> ()
       | Error detail -> Alcotest.failf "record_and_notify failed: %s" detail)
    candidates;
  poll_until ~clock ~timeout_s:10.0 "storm fully drained" (fun () ->
    List.for_all
      (fun keeper_name ->
         load_only ~base_path ~keeper_name
         |> List.for_all (fun (c : Candidate.candidate) ->
           match c.status with
           | Candidate.Consumed _ -> true
           | Candidate.Pending _ | Candidate.Judged _ | Candidate.Deferred _ | Candidate.Terminal_failed _ ->
             false))
      keeper_names);
  Alcotest.(check bool) "observed concurrency never exceeded max_concurrency=4" true (!max_in_flight <= 4);
  Alcotest.(check bool) "observed concurrency actually used more than one worker" true (!max_in_flight > 1);
  Alcotest.(check int) "every distinct candidate was judged exactly once" (List.length candidates) (Hashtbl.length judged);
  Hashtbl.iter
    (fun candidate_id count ->
       Alcotest.(check int) (Printf.sprintf "candidate %s judged exactly once" candidate_id) 1 count)
    judged
;;

let test_deferred_candidates_do_not_rejudge_before_due () =
  with_temp_base "board-attention-worker-rate-limited" @@ fun base_path ->
  with_root_eio_context @@ fun _env clock ->
  let keeper_name = "rate-limited-keeper" in
  let fixture = candidate ~keeper_name ~post_id:"rate-limited-post" ~recorded_at:(Time_compat.now ()) in
  let judge_calls = ref 0 in
  let judge (_ : Candidate.candidate) =
    incr judge_calls;
    Error
      (Candidate.Judge_retryable
         { failure = { kind = Candidate.Provider_unavailable; detail = "rate limited"; failed_at = Time_compat.now () }
         ; retry_after = Some 60.0
         })
  in
  Eio.Switch.run
  @@ fun sw ->
  Worker.For_testing.start_with_judge ~sw ~clock ~base_path ~max_concurrency:2 ~judge ();
  (match Worker.record_and_notify ~base_path fixture with
   | Ok _ -> ()
   | Error detail -> Alcotest.failf "record_and_notify failed: %s" detail);
  poll_until ~clock ~timeout_s:5.0 "first retryable judge attempt lands as Deferred" (fun () ->
    match find_by_id (load_only ~base_path ~keeper_name) fixture.candidate_id with
    | Some { status = Candidate.Deferred _; _ } -> true
    | _ -> false);
  Alcotest.(check int) "exactly one judge call before the retry-after window" 1 !judge_calls;
  (* Re-notify well before the 60s retry-after window elapses. If the
     dispatcher ignored [not_before] this would fire a second judge call. *)
  Worker.notify ~base_path ~keeper_name;
  Eio.Time.sleep clock 0.5;
  Alcotest.(check int) "no re-judge before the retry-after window elapses" 1 !judge_calls
;;

let test_notify_from_domain_spawn_neither_raises_nor_loses_work () =
  with_temp_base "board-attention-worker-domain-spawn" @@ fun base_path ->
  with_root_eio_context @@ fun env clock ->
  let keeper_name = "domain-spawn-keeper" in
  let fixture = candidate ~keeper_name ~post_id:"domain-spawn-post" ~recorded_at:(Time_compat.now ()) in
  let judge (_ : Candidate.candidate) = Ok (judgment Judgment.Not_relevant) in
  Eio.Switch.run
  @@ fun sw ->
  Worker.For_testing.start_with_judge ~sw ~clock ~base_path ~max_concurrency:2 ~judge ();
  (match Candidate.record ~base_path fixture with
   | Candidate.Recorded _ -> ()
   | Candidate.Duplicate _ | Candidate.Record_error _ -> Alcotest.fail "fixture record failed");
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  (* [notify] must be safe to call from a domain that never ran [Eio_main],
     never held [sw], and is not part of this fiber's cancellation context —
     exactly the #21960 hazard the old [start_async]/[Fiber.fork ~sw] path
     hit when called from an Executor_pool domain. *)
  Eio.Domain_manager.run domain_mgr (fun () -> Worker.notify ~base_path ~keeper_name);
  poll_until ~clock ~timeout_s:5.0 "candidate notified from another domain was processed" (fun () ->
    match find_by_id (load_only ~base_path ~keeper_name) fixture.candidate_id with
    | Some { status = Candidate.Consumed { delivery = Candidate.Not_relevant; _ }; _ } -> true
    | _ -> false)
;;

let () =
  Alcotest.run
    "keeper_board_attention_worker"
    [ ( "bounded dispatch"
      , [ Alcotest.test_case
            "effective_max_concurrency respects runtime binding"
            `Quick
            test_effective_max_concurrency_respects_runtime_binding
        ; Alcotest.test_case
            "boot scan expires stale rows and drains fresh rows bounded"
            `Quick
            test_boot_scan_expires_stale_rows_and_drains_fresh_rows_bounded
        ; Alcotest.test_case
            "storm: bounded concurrency, each candidate judged exactly once"
            `Quick
            test_storm_bounded_concurrency_each_candidate_judged_once
        ; Alcotest.test_case
            "deferred candidates do not re-judge before due"
            `Quick
            test_deferred_candidates_do_not_rejudge_before_due
        ; Alcotest.test_case
            "notify from Domain.spawn neither raises nor loses work"
            `Quick
            test_notify_from_domain_spawn_neither_raises_nor_loses_work
        ] )
    ]
;;
