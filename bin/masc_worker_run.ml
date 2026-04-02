module Lib = Masc_mcp

let read_stdin_all () =
  In_channel.input_all In_channel.stdin

let emit_json json =
  Yojson.Safe.to_string json |> print_endline;
  flush stdout

let has_spec_stdin_flag () =
  Array.exists (String.equal "--spec-stdin") Sys.argv

let main () =
  if not (has_spec_stdin_flag ()) then (
    emit_json
      (Lib.Worker_runtime_helper_protocol.error_json
         {
            message = "masc-worker-run requires --spec-stdin";
            kind = Lib.Worker_runtime_helper_protocol.Spec_parse;
         });
    exit 2);
  let stdin_text = read_stdin_all () in
  match Yojson.Safe.from_string stdin_text |> Lib.Worker_execution_spec.of_yojson with
  | exception Yojson.Json_error msg ->
      emit_json
        (Lib.Worker_runtime_helper_protocol.error_json
           { message = "invalid worker spec JSON: " ^ msg; kind = Lib.Worker_runtime_helper_protocol.Spec_parse })
  | Error msg ->
      emit_json
        (Lib.Worker_runtime_helper_protocol.error_json
           { message = msg; kind = Lib.Worker_runtime_helper_protocol.Spec_parse })
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
              match Lib.Worker_run_once.execute_spec ~sw ~room_config:None spec with
              | Ok run_result ->
                  emit_json
                    (Lib.Worker_runtime_helper_protocol.success_json run_result)
              | Error msg ->
                  emit_json
                    (Lib.Worker_runtime_helper_protocol.error_json
                       { message = msg; kind = Lib.Worker_runtime_helper_protocol.Runtime })))

let () =
  try main ()
  with exn ->
    emit_json
      (Lib.Worker_runtime_helper_protocol.error_json
         { message = Printexc.to_string exn; kind = Lib.Worker_runtime_helper_protocol.Internal })
