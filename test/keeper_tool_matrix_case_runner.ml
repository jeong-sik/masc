module Types = Masc_domain

module Cases = Test_keeper_tool_matrix_cases

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
      Masc_mcp.Mcp_server_eio.set_net (Eio.Stdenv.net env);
      Masc_mcp.Mcp_server_eio.set_clock (Eio.Stdenv.clock env);
      let clock = Eio.Stdenv.clock env in
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let fs = Eio.Stdenv.fs env in
      let net = Eio.Stdenv.net env in
      let mono_clock = Eio.Stdenv.mono_clock env in
      let base_path, result =
        Eio.Switch.run @@ fun sw ->
        Cases.run_case sw ~proc_mgr ~fs ~net ~mono_clock clock schema
      in
      emit_result ~base_path tool_name result;
      flush stdout;
      flush stderr;
      Unix._exit
        (match result with
        | Ok () -> 0
        | Error _ -> 1)
