open Fs_compat_base_io

let check_cancellation = function
  | Non_eio -> ()
  | Eio_fiber -> Eio.Fiber.check ()

let protect context f =
  match context with
  | Non_eio -> f ()
  | Eio_fiber -> Eio.Cancel.protect f

let worker context ~label f =
  match context with
  | Non_eio -> f ()
  | Eio_fiber -> Fs_compat_internal.Systhread_host.run ~label f

let with_open_result_impl ~before_close ~path ~open_input f =
  let context = execution_context () in
  let owned = ref None in
  let close_owned () =
    match !owned with
    | None -> ()
    | Some (key, input) ->
      owned := None;
      protect context (fun () ->
        worker context ~label:(labelled "fs-compat-input-close" path) (fun () ->
          with_captured_append_path_mutex key (fun () ->
            Fun.protect ~finally:(fun () -> close_in_noerr input)
              (fun () -> before_close input))))
  in
  let run () =
    check_cancellation context;
    let opened =
      protect context (fun () ->
        (* [on_systhread] checks cancellation after the worker returns, before
           ownership could be recorded. Register the channel within this
           protected handoff instead; the outer handler already owns cleanup. *)
        let result =
          worker context ~label:(labelled "fs-compat-input-open" path) (fun () ->
            let key = capture_append_path_mutex_key path in
            with_captured_append_path_mutex key (fun () ->
              Result.map (fun input -> key, input) (open_input path)))
        in
        match result with
        | Error _ as error -> error
        | Ok (key, input) -> owned := Some (key, input); Ok input)
    in
    check_cancellation context;
    match opened with
    | Error _ as error -> error
    | Ok input -> f input
  in
  match run () with
  | result ->
    close_owned ();
    check_cancellation context;
    result
  | exception primary ->
    let backtrace = Printexc.get_raw_backtrace () in
    (* close_in_noerr callers keep their primary failure. Once entered, cleanup
       closes the channel even if the test probe raises. A cleanup failure must
       not replace the callback's original exception/cancellation/backtrace. *)
    (match close_owned () with
     | () -> ()
     | exception _ -> ());
    Printexc.raise_with_backtrace primary backtrace
;;

type no_open_error = |

let with_open_impl ~before_close ~path ~open_input f =
  let open_result path : (in_channel, no_open_error) result = Ok (open_input path) in
  match with_open_result_impl ~before_close ~path ~open_input:open_result
    (fun input -> Ok (f input)) with
  | Ok value -> value
  | Error impossible -> .
;;

let with_open ~path ~open_input f =
  with_open_impl ~before_close:ignore ~path ~open_input f

let with_open_result ~path ~open_input f =
  with_open_result_impl ~before_close:ignore ~path ~open_input f

module For_testing = struct
  let with_open = with_open_impl
  let with_open_result = with_open_result_impl
  let path_mutex_available path =
    Option.is_some (try_with_append_path_mutex path (fun () -> ()))
end
