(** The two readers of a Keeper's newest execution receipt,
    [Keeper_execution_receipt.latest_json] and [read_latest_receipt], take the
    receipt store's kept fact ([Dated_jsonl.newest_parsed_row]).

    This executable stands for the server: it says it is the one process that
    writes the stores before any test runs.

    What is pinned:

    1. Once read, the newest receipt comes from memory. Both readers answer
       with the day files gone, until the store is told of the removal.
    2. [Keeper_execution_receipt.append] moves the kept receipt.
    3. A last row that is not JSON is passed over by both readers.
    4. A store the strict read refuses: [read_latest_receipt] says it cannot
       be read, and [latest_json] reads it leniently, as it did before there
       was a fact.
    5. A [.jsonl] file whose name begins with a dot is not the store's. The
       lenient read took its rows; both readers now pass the file over.
    6. A kept receipt is answered without the fiber giving up its turn. *)

open Alcotest
open Masc
module Receipt = Keeper_execution_receipt

let keeper_name = "receipt-kept"

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper_receipt_kept_" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_path)
    (fun () -> f (Workspace.default_config base_path))
;;

let receipt ~ended_at : Receipt.t =
  { Receipt.keeper_name
  ; trace_id = "trace-receipt-kept"
  ; turn_count = Some 7
  ; agent_core_turn_count = None
  ; current_task_id = None
  ; outcome = `Ok
  ; terminal_reason = Keeper_terminal_reason.Completed
  ; response_text_present = true
  ; completion_contract_result = Receipt.Completion_observation_unknown
  ; actionable_signal = None
  ; tool_surface = { Receipt.turn_lane = Keeper_agent_tool_surface.Lane_tool_optional }
  ; sandbox_kind = Keeper_types_profile_sandbox.Remote_ssh
  ; sandbox_root = None
  ; network_mode = Keeper_types_profile_sandbox.Network_none
  ; runtime_id = "runtime-1"
  ; runtime_selected_model = None
  ; runtime_attempt_count = 1
  ; runtime_lane_attempt_count = 1
  ; runtime_lane_evidence = None
  ; runtime_fallback_applied = false
  ; runtime_outcome = Receipt.Runtime_completed
  ; agent_core_internal_runtime_allowed = true
  ; degraded_retry_applied = None
  ; degraded_retry_deferred = None
  ; stop_reason = None
  ; error_kind = None
  ; error_message = None
  ; started_at = "2026-11-19T00:00:00Z"
  ; ended_at
  ; extra_system_context_digest = None
  ; extra_system_context_injected_size = None
  ; extra_system_context_computed_size = None
  }
;;

let first = "2026-11-19T00:00:01Z"
let second = "2026-11-19T00:00:02Z"
let store config = Keeper_types_support.keeper_execution_receipt_store config keeper_name

(* When the newest receipt ended, as each reader tells it. *)
let latest_json_ended_at config =
  Option.bind (Receipt.latest_json config keeper_name) (Json_util.assoc_string_opt "ended_at")
;;

let read_latest_ended_at config =
  match Receipt.read_latest_receipt config keeper_name with
  | Receipt.No_receipt -> Ok None
  | Receipt.Latest_receipt summary -> Ok (Some summary.Receipt.latest_ended_at)
  | Receipt.Latest_receipt_undecodable { field } -> Error ("undecodable field " ^ field)
  | Receipt.Receipt_store_unreadable error -> Error (Dated_jsonl.read_error_to_string error)
;;

let check_both_readers config label expected =
  check (option string) (label ^ " (latest_json)") expected (latest_json_ended_at config);
  check
    (result (option string) string)
    (label ^ " (read_latest_receipt)")
    (Ok expected)
    (read_latest_ended_at config)
;;

let remove_day_files config =
  let store = store config in
  Dated_jsonl.close store;
  let base_dir = Dated_jsonl.base_dir store in
  Array.iter
    (fun month ->
       let month_path = Filename.concat base_dir month in
       Array.iter
         (fun day -> Sys.remove (Filename.concat month_path day))
         (Sys.readdir month_path))
    (Sys.readdir base_dir)
;;

(* The second answers have to come from memory: the files they would read
   are gone. Once the store is told of a removal the readers read the files
   again and find no receipt. *)
let test_a_kept_receipt_is_read_without_the_files () =
  with_workspace (fun config ->
    Receipt.append config (receipt ~ended_at:first);
    check_both_readers config "the receipt" (Some first);
    remove_day_files config;
    check_both_readers config "again with the files gone" (Some first);
    Dated_jsonl.directories_removed ();
    check_both_readers config "once the removal is told" None)
;;

(* How many turns a fiber that is ready to run gets while [read] is called
   fifty times. Fibers of one domain take turns only where one of them
   waits, so a read that never waits gives the fiber beside it none. A read
   that asks the file system through Eio waits for a worker thread, and the
   fiber beside it runs. *)
let turns_of_a_fiber_beside read =
  Eio.Switch.run
  @@ fun sw ->
  let turns = ref 0 in
  let stop = ref false in
  Eio.Fiber.fork ~sw (fun () ->
    while not !stop do
      incr turns;
      Eio.Fiber.yield ()
    done);
  Eio.Fiber.yield ();
  let before = !turns in
  for _ = 1 to 50 do
    read ()
  done;
  let during = !turns - before in
  stop := true;
  during
;;

(* The server turns the Eio mutex guards on ([bin/main_eio.ml]), and then a
   store's handle is fetched under an [Eio.Mutex]. The reads below go the way
   the server's do. *)
let with_the_servers_guards f =
  Eio_guard.enable ();
  Fun.protect ~finally:Eio_guard.disable f
;;

(* Opening the store used to look whether the keepers directory was there,
   through Eio, on every read. *)
let test_a_kept_receipt_is_answered_without_waiting () =
  with_workspace (fun config ->
    with_the_servers_guards
    @@ fun () ->
    Receipt.append config (receipt ~ended_at:first);
    check_both_readers config "read and kept" (Some first);
    check
      int
      "the fiber beside got no turn"
      0
      (turns_of_a_fiber_beside (fun () -> check_both_readers config "held" (Some first))))
;;

(* The append of a receipt moves the kept one, with no read of the files in
   between. *)
let test_an_appended_receipt_replaces_the_kept_one () =
  with_workspace (fun config ->
    Receipt.append config (receipt ~ended_at:first);
    check_both_readers config "the first receipt" (Some first);
    Receipt.append config (receipt ~ended_at:second);
    remove_day_files config;
    check_both_readers config "the appended receipt, with the files gone" (Some second))
;;

(* A row cut short after the newest receipt. Both readers pass it over and
   give the receipt before it, and that receipt is then kept. *)
let test_a_last_row_that_is_not_json_is_passed_over () =
  with_workspace (fun config ->
    Receipt.append config (receipt ~ended_at:first);
    let location =
      Keeper_types_support.keeper_store_location
        config
        keeper_name
        Dated_jsonl.Store.Keeper.Execution_receipts
    in
    Out_channel.with_open_gen
      [ Open_wronly; Open_append; Open_binary ]
      0o644
      (Dated_jsonl.Store.dated_path_now location).Dated_jsonl.Store.path
      (fun channel -> output_string channel "{\"outcome\": \n");
    check_both_readers config "the receipt before the cut row" (Some first);
    remove_day_files config;
    check_both_readers config "kept, with the files gone" (Some first))
;;

(* A name beside the months that the layout does not make. The strict read
   refuses the store, so nothing is kept: the two readers answer as they did
   before there was a fact, and read the store once the name is gone. *)
let test_a_store_the_strict_read_refuses () =
  with_workspace (fun config ->
    Receipt.append config (receipt ~ended_at:first);
    let foreign = Filename.concat (Dated_jsonl.base_dir (store config)) "notes.txt" in
    Out_channel.with_open_text foreign (fun channel -> output_string channel "not a month");
    (match Receipt.read_latest_receipt config keeper_name with
     | Receipt.Receipt_store_unreadable _ -> ()
     | Receipt.No_receipt | Receipt.Latest_receipt _ | Receipt.Latest_receipt_undecodable _ ->
       fail "read_latest_receipt read a store the strict read refuses");
    check
      (option string)
      "latest_json reads it leniently"
      (Some first)
      (latest_json_ended_at config);
    Sys.remove foreign;
    check_both_readers config "once the name is gone" (Some first))
;;

(* A later month holding one file, [._01.jsonl], with a receipt row in it. The
   store's layout makes no such name. *)
let test_a_dot_file_is_not_the_stores () =
  with_workspace (fun config ->
    Receipt.append config (receipt ~ended_at:first);
    let later_month = Filename.concat (Dated_jsonl.base_dir (store config)) "2099-01" in
    Unix.mkdir later_month 0o755;
    Out_channel.with_open_text (Filename.concat later_month "._01.jsonl") (fun channel ->
      output_string
        channel
        (Yojson.Safe.to_string (Receipt.to_json (receipt ~ended_at:second)) ^ "\n"));
    check_both_readers config "the store's own receipt" (Some first))
;;

let () =
  Fact_cell.keep_in_this_process ();
  run
    "keeper_execution_receipt_kept"
    [ ( "the newest receipt is the store's kept fact"
      , [ test_case
            "a kept receipt is read without the files"
            `Quick
            test_a_kept_receipt_is_read_without_the_files
        ; test_case
            "an appended receipt replaces the kept one"
            `Quick
            test_an_appended_receipt_replaces_the_kept_one
        ; test_case
            "a last row that is not JSON is passed over"
            `Quick
            test_a_last_row_that_is_not_json_is_passed_over
        ; test_case
            "a store the strict read refuses"
            `Quick
            test_a_store_the_strict_read_refuses
        ; test_case "a dot file is not the store's" `Quick test_a_dot_file_is_not_the_stores
        ; test_case
            "a kept receipt is answered without waiting"
            `Quick
            test_a_kept_receipt_is_answered_without_waiting
        ] )
    ]
;;
