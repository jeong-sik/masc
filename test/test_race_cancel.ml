(** Tests for race node fiber cancellation (issue #2219).
    Verifies that non-winning fibers are cancelled after a winner is found. *)

open Alcotest
open Masc_mcp

let make_ctx () =
  Chain_executor_helpers.make_context
    ~start_time:(Unix.gettimeofday ())
    ~trace_enabled:false ~timeout:60 ~chain_id:"test-race" ()

let make_node id =
  Chain_types.{
    id;
    node_type = Model { model = "test"; system = None; prompt = "test";
                        timeout = None; tools = None; prompt_ref = None;
                        prompt_vars = []; thinking = false };
    input_mapping = [];
    output_key = None;
    depends_on = None;
  }

let dummy_exec_fn ~model:_ ?system:_ ~prompt:_ ?tools:_ ?thinking:_ () =
  Ok "unused"

let dummy_tool_exec ~name:_ ~args:_ = Ok "unused"

(** Verify that non-winning fibers are cancelled after first success.
    We track how many execute_node calls actually complete (not cancelled). *)
let test_race_cancels_losers () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let completed_count = Atomic.make 0 in
  let ctx = make_ctx () in
  let nodes = List.init 3 (fun i -> make_node (Printf.sprintf "racer_%d" i)) in

  (* Slow execute_node: racer_0 finishes instantly, others sleep *)
  let execute_node _ctx ~sw:_ ~clock:_ ~exec_fn:_ ~tool_exec:_ (node : Chain_types.node) =
    if node.id = "racer_0" then begin
      Atomic.incr completed_count;
      Ok "winner-output"
    end else begin
      (* Sleep long enough that they'd run if not cancelled *)
      (try Eio.Time.sleep clock 10.0
       with Eio.Cancel.Cancelled _ -> ());
      Atomic.incr completed_count;
      Ok "loser-output"
    end
  in

  let parent = make_node "race_parent" in
  Eio.Switch.run (fun sw ->
    let result =
      Chain_executor_resilience.execute_race ctx ~sw ~clock
        ~exec_fn:dummy_exec_fn ~execute_node ~tool_exec:dummy_tool_exec
        parent ~nodes ~timeout:(Some 30.0)
    in
    match result with
    | Ok output ->
        check string "winner output" "winner-output" output;
        (* Only racer_0 should have completed; losers should be cancelled *)
        check int "only winner completed" 1 (Atomic.get completed_count)
    | Error msg ->
        failf "race should succeed, got error: %s" msg)

(** Verify race returns error when all racers fail. *)
let test_race_all_fail () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let ctx = make_ctx () in
  let nodes = List.init 2 (fun i -> make_node (Printf.sprintf "fail_%d" i)) in

  let execute_node _ctx ~sw:_ ~clock:_ ~exec_fn:_ ~tool_exec:_ (node : Chain_types.node) =
    Error (Printf.sprintf "%s failed" node.id)
  in

  let parent = make_node "race_parent" in
  Eio.Switch.run (fun sw ->
    match Chain_executor_resilience.execute_race ctx ~sw ~clock
            ~exec_fn:dummy_exec_fn ~execute_node ~tool_exec:dummy_tool_exec
            parent ~nodes ~timeout:(Some 5.0) with
    | Ok _ -> fail "expected all-fail race to return Error"
    | Error msg ->
        check bool "contains fail_0" true (String.length msg > 0);
        check bool "error message present" true
          (try ignore (Str.search_forward (Str.regexp_string "failed") msg 0); true
           with Not_found -> false))

(** Verify race handles timeout when no racer finishes in time. *)
let test_race_timeout () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let ctx = make_ctx () in
  let nodes = [make_node "slow_0"] in

  let execute_node _ctx ~sw:_ ~clock ~exec_fn:_ ~tool_exec:_ (_node : Chain_types.node) =
    (try Eio.Time.sleep clock 60.0
     with Eio.Cancel.Cancelled _ -> ());
    Ok "too-late"
  in

  let parent = make_node "race_parent" in
  Eio.Switch.run (fun sw ->
    match Chain_executor_resilience.execute_race ctx ~sw ~clock
            ~exec_fn:dummy_exec_fn ~execute_node ~tool_exec:dummy_tool_exec
            parent ~nodes ~timeout:(Some 0.5) with
    | Ok _ -> fail "expected timeout"
    | Error msg ->
        check bool "timeout message" true
          (try ignore (Str.search_forward (Str.regexp_string "timeout") msg 0); true
           with Not_found -> false))

let () =
  run "race-cancel" [
    "cancellation", [
      test_case "non-winning fibers cancelled" `Quick test_race_cancels_losers;
      test_case "all-fail returns error" `Quick test_race_all_fail;
      test_case "timeout returns error" `Quick test_race_timeout;
    ];
  ]
