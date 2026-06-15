module Types = Masc_domain

module Cases = Test_keeper_tool_matrix_cases

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "keeper_tool_matrix_runtime_" ".toml" in
  let oc = open_out path in
  output_string oc {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|};
  close_out oc;
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> failwith ("Runtime.init_default failed: " ^ e)
;;

let () =
  Mirage_crypto_rng_unix.use_default ();
  init_runtime_default_for_tests ()
;;


let result_prefix = "__KEEPER_TOOL_MATRIX_RESULT__"

let emit_result ~base_path name = function
  | Ok () ->
      Printf.printf "%s%s\n" result_prefix
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("name", `String name);
               ("ok", `Bool true);
               ("base_path", `String base_path);
             ]))
  | Error message ->
      Printf.printf "%s%s\n" result_prefix
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("name", `String name);
               ("ok", `Bool false);
               ("base_path", `String base_path);
               ("message", `String message);
             ]))

let find_schema name =
  Cases.all_keeper_tool_schemas ()
  |> List.find_opt (fun (schema : Masc_domain.tool_schema) ->
         String.equal schema.name name)

let () =
  Mirage_crypto_rng_unix.use_default ();
  Printexc.record_backtrace true;
  if Array.length Sys.argv <> 2 then begin
    prerr_endline "usage: keeper_tool_matrix_case_runner.exe <tool-name>";
    flush stderr;
    Unix._exit 2
  end;
  let tool_name = Sys.argv.(1) in
  match find_schema tool_name with
  | None ->
      emit_result ~base_path:"" tool_name
        (Error ("unknown keeper tool: " ^ tool_name));
      flush stdout;
      Unix._exit 2
  | Some schema ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Masc.Mcp_server_eio.set_net (Eio.Stdenv.net env);
      Masc.Mcp_server_eio.set_clock (Eio.Stdenv.clock env);
      let clock = Eio.Stdenv.clock env in
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let fs = Eio.Stdenv.fs env in
      let net = Eio.Stdenv.net env in
      let mono_clock = Eio.Stdenv.mono_clock env in
      Eio.Switch.run @@ fun sw ->
      let base_path, result =
        Cases.run_case sw ~proc_mgr ~fs ~net ~mono_clock clock schema
      in
      emit_result ~base_path tool_name result;
      flush stdout;
      flush stderr;
      Unix._exit
        (match result with
        | Ok () -> 0
        | Error _ -> 1)
