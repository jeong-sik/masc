module Lib = Masc_mcp

let read_stdin_all () =
  In_channel.input_all In_channel.stdin

let emit_json json =
  Yojson.Safe.to_string json |> print_endline;
  flush stdout

let has_spec_stdin_flag () =
  Array.exists (String.equal "--spec-stdin") Sys.argv

let main_result () =
  if not (has_spec_stdin_flag ()) then
    ( Lib.Worker_runtime_helper_protocol.error_json
        {
          message = "masc-worker-run requires --spec-stdin";
          kind = Lib.Worker_runtime_helper_protocol.Spec_parse;
        },
      2 )
  else
    let stdin_text = read_stdin_all () in
    match
      Yojson.Safe.from_string stdin_text |> Lib.Worker_execution_spec.of_yojson
    with
    | exception Yojson.Json_error msg ->
        ( Lib.Worker_runtime_helper_protocol.error_json
            {
              message = "invalid worker spec JSON: " ^ msg;
              kind = Lib.Worker_runtime_helper_protocol.Spec_parse;
            },
          1 )
    | Error msg ->
        ( Lib.Worker_runtime_helper_protocol.error_json
            {
              message = msg;
              kind = Lib.Worker_runtime_helper_protocol.Spec_parse;
            },
          1 )
    | Ok spec ->
        Eio_main.run @@ fun env ->
        Eio_guard.enable ();
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Time_compat.set_clock (Eio.Stdenv.clock env);
        Process_eio.reset_for_testing ();
        Process_eio.init
          ~cwd_default:(Eio.Stdenv.fs env)
          ~proc_mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env);
        Exec_tap.install_from_env ();
        Eio.Switch.run @@ fun sw ->
        Eio_context.with_test_env
          ~net:(Eio.Stdenv.net env)
          ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
          ~sw
          (fun () ->
            Fun.protect
              ~finally:(fun () ->
                Process_eio.reset_for_testing ();
                Time_compat.clear_clock ();
                Eio_guard.disable ())
              (fun () ->
                match
                  (* Worker_run_once removed *)
                  ignore (sw, spec);
                  (Error "Worker_run_once removed (team session layer)" : (Lib.Worker_container.run_result, string) result)
                with
                | Ok run_result ->
                    ( Lib.Worker_runtime_helper_protocol.success_json run_result,
                      0 )
                | Error msg ->
                    ( Lib.Worker_runtime_helper_protocol.error_json
                        {
                          message = msg;
                          kind = Lib.Worker_runtime_helper_protocol.Runtime;
                        },
                      1 )))

let () =
  try
    let json, exit_code = main_result () in
    emit_json json;
    exit exit_code
  with exn ->
    emit_json
      (Lib.Worker_runtime_helper_protocol.error_json
         { message = Printexc.to_string exn; kind = Lib.Worker_runtime_helper_protocol.Internal });
    exit 1
