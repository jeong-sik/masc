open Alcotest

module Internal = Agent_core__
module Runtime = Internal.Execution_runtime
module Codec = Internal.Execution_codec_executor
module Event = Internal.Execution_event
module Journal = Internal.Execution_journal
module Writer = Internal.Execution_lane_writer
module Tx = Journal.Transaction

exception Service_failed

let require show = function
  | Ok value -> value
  | Error error -> fail (show error)
;;

let with_writer open_writer ~codec ~dir f =
  require Writer.scope_failure_to_string (open_writer ~codec ~dir f)
;;

let test_final_journal_save ~service_fails () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun cleanup_sw ->
  let path = Filename.temp_file "server-execution-shutdown-" ".dir" in
  Sys.remove path;
  let dir = Eio.Path.(env#fs / path) in
  Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
  Eio.Switch.on_release cleanup_sw (fun () -> Eio.Path.rmtree dir);
  let escaped_codec = ref None in
  let run_id = ref None in
  let saved = ref false in
  (match
     Server_session_switch.run (fun ~runtime_sw sw ->
       let runtime =
         require Runtime.create_error_to_string
           (Runtime.create ~sw:runtime_sw ~domain_mgr:env#domain_mgr ~domain_count:1)
       in
       let codec = Codec.of_runtime runtime in
       escaped_codec := Some codec;
       let run =
         with_writer (Writer.run ?correlation_id:None) ~codec ~dir (fun ~sw:_ writer ->
           let ticket = require Writer.submit_error_to_string
               (Writer.submit writer (Tx.start_run ~agent_name:"shutdown-test" ())) in
           let receipt = require Writer.ticket_error_to_string (Writer.await ticket) in
           fst receipt.value)
       in
       run_id := Some (Journal.run_id run);
       (* Release handlers run after every session fiber, including daemons,
          has stopped. This tests the last cleanup save without a sleep or
          depending on which cancelled fiber the scheduler wakes first. *)
       Eio.Switch.on_release sw (fun () ->
         with_writer Writer.resume ~codec ~dir (fun ~sw:_ writer ->
           let ticket = require Writer.submit_error_to_string
               (Writer.submit writer
                  (Tx.abort_run ~run
                     (Event.Cancelled { reason = Some "session shutdown"; data = None }))) in
           ignore (require Writer.ticket_error_to_string (Writer.await ticket)));
         saved := true);
       if service_fails then raise Service_failed)
   with
   | () -> check bool "normal session returned" false service_fails
   | exception Service_failed -> check bool "original failure preserved" true service_fails);
  check bool "last journal save completed" true !saved;
  (match Codec.encode_events (Option.get !escaped_codec) [] with
   | Error (Codec.Executor_unavailable { operation = Codec.Encode_events; _ }) -> ()
   | Error failure -> fail (Codec.failure_to_string failure)
   | Ok _ -> fail "session runtime still accepts jobs after shutdown");
  (* Reopen the disposable journal with a new runtime, after the session and
     its codec have both gone away. Inspect the stored terminal fact. *)
  let runtime = require Runtime.create_error_to_string
      (Runtime.create ~sw:cleanup_sw ~domain_mgr:env#domain_mgr ~domain_count:1) in
  let codec = Codec.of_runtime runtime in
  with_writer Writer.resume ~codec ~dir (fun ~sw:_ writer ->
    require Writer.scope_failure_to_string (Writer.await_ready writer);
    match require Writer.read_error_to_string (Writer.find_run writer (Option.get !run_id)) with
    | Some { status = Journal.Finished { value = Event.Cancelled _; _ }; _ } -> ()
    | Some _ -> fail "reopened run lost its terminal cancellation"
    | None -> fail "reopened journal lost its run")
;;

let () =
  run "server execution shutdown"
    [ "journal cleanup",
      [ test_case "normal session end saves the final cancellation" `Quick
          (test_final_journal_save ~service_fails:false)
      ; test_case "session failure saves before releasing its codec" `Quick
          (test_final_journal_save ~service_fails:true)
      ]
    ]
