module Remote = Keeper_sandbox_remote
module Request = Remote.Stdio_request
module Stderr = Keeper_sandbox_remote_stderr

type 'e failure =
  | Refused of Request.refusal
  | Dispatch_declined of 'e
  | Process_unavailable of Process_eio.stdio_refusal
  | Guest_unavailable of Keeper_guest_socket.stdio_error
  | Runtime_unavailable of string
  | Host_timeout

let with_stdio prepared ~on_dispatch ~on_receipt ~on_stderr_chunk
    ~on_stdout_tail use =
  let observation = ref (Remote.Execution_unavailable Remote.Request_not_sent) in
  let notify () =
    match Fs_compat.execution_context () with
    | Fs_compat.Eio_fiber -> Eio.Cancel.protect (fun () -> on_receipt !observation)
    | Fs_compat.Non_eio -> on_receipt !observation
  in
  let run_launch runtime (launch : Request.launch) =
    let request_written = ref false in
    let on_request_write () =
      request_written := true;
      (* A failed first write can still have delivered a prefix. *)
      observation := Remote.Execution_unavailable
        (Remote.Transport_unavailable
          (if launch.acceptance_frame then Remote.Acceptance_not_read
           else Remote.Acceptance_not_asked))
    in
    let stderr = Stderr.create ~callback:on_stderr_chunk
        ~acceptance_frame:launch.acceptance_frame
        ~on_accepted:(fun () ->
          observation := Remote.Execution_unavailable
            (Remote.Transport_unavailable Remote.Acceptance_read)) ()
    in
    let finish value terminal =
      Stderr.settle_head stderr;
      let raw_stderr = Stderr.tail stderr in
      let completion = Request.complete prepared ~terminal ~raw_stderr ~prior:!observation in
      observation := completion.execution;
      let payload = match Stderr.split_final_trailer raw_stderr with
        | Ok (payload, _) -> payload
        | Error _ -> raw_stderr
      in
      Stderr.flush_payload stderr payload;
      Ok (value, completion)
    in
    match runtime, launch.carrier with
    | `Process clock, Request.Process { argv; env } ->
      (
         match on_dispatch () with
         | Error refusal -> Error (Dispatch_declined refusal)
         | Ok () ->
           let run () =
             match Process_eio.with_stdio ~env
                 ~on_stderr_chunk:(Stderr.stream_chunk stderr) ~on_stdout_tail
                 argv (fun ~input ~output ->
                   on_request_write ();
                   Eio.Flow.copy_string launch.frame output;
                   use ~input ~output)
             with
             | Error refusal -> Error (Process_unavailable refusal)
             | Ok (value, status) -> finish value (Request.Local_status status)
           in
           match Eio.Time.with_timeout clock launch.budget_sec (fun () -> Ok (run ())) with
           | Ok result -> result
           | Error `Timeout ->
             Request.record_incomplete prepared ~failure:Remote.Local_timeout
               ~detail:"interactive carrier exceeded its host wall-clock budget";
             Error Host_timeout)
    | `Guest (net, clock), Request.Guest { socket; expected; connect_budget_sec } ->
      (
         match Keeper_guest_socket.with_stdio ~net ~clock ~expected ~socket
             ~connect_budget_sec ~budget_sec:launch.budget_sec ~frame:launch.frame
             ~on_dispatch ~on_request_write
             ~on_stderr_chunk:(Stderr.stream_chunk stderr) ~on_stdout_tail use with
         | Ok (value, status) -> finish value (Request.Guest_exit status)
         | Error (Keeper_guest_socket.Dispatch_declined refusal) ->
           Error (Dispatch_declined refusal)
         | Error (Keeper_guest_socket.Transport_failed failure) ->
           if !request_written then
             Request.record_incomplete prepared ~failure:Remote.Transport_failed
               ~detail:(Keeper_guest_socket.stdio_error_to_string failure);
           Error (Guest_unavailable failure))
    | `Process _, Request.Guest _ | `Guest _, Request.Process _ ->
      Error (Runtime_unavailable "prepared carrier and acquired runtime disagree")
  in
  let run () =
    match Fs_compat.execution_context () with
    | Fs_compat.Non_eio ->
      Error (Runtime_unavailable "remote stdio requires an active Eio fiber")
    | Fs_compat.Eio_fiber ->
      let runtime = match Request.runtime prepared with
        | Request.Process_runtime ->
          (match Process_eio.get_clock () with
           | Ok clock -> Ok (`Process clock)
           | Error detail -> Error detail)
        | Request.Guest_runtime ->
          (match Eio_context.get_net_opt (), Eio_context.get_clock_opt () with
           | Some net, Some clock -> Ok (`Guest (net, clock))
           | None, (Some _ | None) | Some _, None ->
             Error "guest stdio requires an initialized Eio network and clock")
      in
      match runtime with
      | Error detail -> Error (Runtime_unavailable detail)
      | Ok runtime ->
        match Request.with_lease prepared (run_launch runtime) with
        | Error refusal -> Error (Refused refusal)
        | Ok result -> result
  in
  match run () with
  | result -> notify (); result
  | exception primary ->
    let backtrace = Printexc.get_raw_backtrace () in
    (match notify () with
     | () -> ()
     | exception secondary ->
       let secondary_backtrace = Printexc.get_raw_backtrace () in
       (match Log.Misc.warn
           "[remote stdio] receipt notification failed during exception cleanup: %s\n%s"
           (Printexc.to_string secondary)
           (Printexc.raw_backtrace_to_string secondary_backtrace) with
        | () -> ()
        | exception _reporter_failure -> ()));
    Printexc.raise_with_backtrace primary backtrace
