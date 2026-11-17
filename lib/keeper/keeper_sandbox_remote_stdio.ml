module Remote = Keeper_sandbox_remote
module Request = Remote.Stdio_request
module Stderr = Keeper_sandbox_remote_stderr

type 'e failure =
  | Refused of Request.refusal
  | Dispatch_declined of 'e
  | Process_unavailable of Process_eio.stdio_refusal
  | Host_timeout

let with_stdio prepared ~on_dispatch ~on_receipt ~on_stderr_chunk
    ~on_stdout_tail use =
  let observation = ref (Remote.Execution_unavailable Remote.Request_not_sent) in
  let notify () =
    match Fs_compat.execution_context () with
    | Fs_compat.Eio_fiber -> Eio.Cancel.protect (fun () -> on_receipt !observation)
    | Fs_compat.Non_eio -> on_receipt !observation
  in
  let run () =
    match Fs_compat.execution_context () with
    | Fs_compat.Non_eio ->
      Error (Process_unavailable
        (Process_eio.Runtime_unavailable "remote stdio requires an active Eio fiber"))
    | Fs_compat.Eio_fiber ->
      match Process_eio.get_clock () with
      | Error detail -> Error (Process_unavailable (Process_eio.Runtime_unavailable detail))
      | Ok clock ->
        match Request.with_lease prepared (fun launch ->
          match on_dispatch () with
          | Error refusal -> Error (Dispatch_declined refusal)
          | Ok () ->
            let stderr = Stderr.create ~callback:on_stderr_chunk
                ~acceptance_frame:launch.acceptance_frame
                ~on_accepted:(fun () ->
                  observation := Remote.Execution_unavailable
                    (Remote.Transport_unavailable Remote.Acceptance_read)) ()
            in
            let run () =
              match Process_eio.with_stdio ~env:launch.env
                  ~on_stderr_chunk:(Stderr.stream_chunk stderr) ~on_stdout_tail
                  launch.argv (fun ~input ~output ->
                    (* Even a failed write can have delivered a prefix. No
                       transport exception proves that prefix was unsent. *)
                    observation := Remote.Execution_unavailable
                      (Remote.Transport_unavailable
                        (if launch.acceptance_frame then Remote.Acceptance_not_read
                         else Remote.Acceptance_not_asked));
                    Eio.Flow.copy_string launch.frame output;
                    use ~input ~output)
              with
              | Error refusal -> Error (Process_unavailable refusal)
              | Ok (value, status) ->
                Stderr.settle_head stderr;
                let raw_stderr = Stderr.tail stderr in
                let completion = Request.complete prepared ~status ~raw_stderr ~prior:!observation in
                observation := completion.execution;
                let payload =
                  match Stderr.split_final_trailer raw_stderr with
                  | Ok (payload, _) -> payload
                  | Error _ -> raw_stderr
                in
                Stderr.flush_payload stderr payload;
                Ok (value, completion)
            in
            match Eio.Time.with_timeout clock launch.budget_sec (fun () -> Ok (run ())) with
            | Ok result -> result
            | Error `Timeout ->
              Request.record_incomplete prepared ~failure:Remote.Local_timeout
                ~detail:"interactive carrier exceeded its host wall-clock budget";
              Error Host_timeout)
        with
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
