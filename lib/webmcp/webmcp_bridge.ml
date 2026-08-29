(* WebMCP consumer bridge — see webmcp_bridge.mli.

   The node script is the SSOT at dashboard/scripts/webmcp-bridge.mjs and is
   embedded into the binary at build time (dune rule -> Webmcp_bridge_source),
   so a deployed server never depends on a repo checkout or a separately
   shipped asset. At runtime the source is materialized once into a temp file
   and reused for the life of the process. *)

type failure =
  | Bridge_unavailable of string
  | Page_not_found of string
  | Surface_or_tool_missing of string
  | Invalid_args of string
  | Bridge_failure of string

let failure_message = function
  | Bridge_unavailable detail ->
    Printf.sprintf
      "webmcp bridge unavailable: %s (node must be on the server PATH)"
      detail
  | Page_not_found detail ->
    Printf.sprintf
      "webmcp page not found: %s (is Chrome running with --remote-debugging-port and the target page open?)"
      detail
  | Surface_or_tool_missing detail ->
    Printf.sprintf
      "webmcp surface or tool missing: %s (the page has no document.modelContext, or the tool is not registered — Chrome needs --enable-features=WebMCP)"
      detail
  | Invalid_args detail -> Printf.sprintf "webmcp args_json invalid: %s" detail
  | Bridge_failure detail -> Printf.sprintf "webmcp bridge failure: %s" detail
;;

type runner =
  timeout_sec:float ->
  string list ->
  (Unix.process_status * string * string, string) result

(* One wall-clock budget for a whole bridge invocation: CDP connect, page
   evaluation, and the page's own MCP round trip all happen inside it. *)
let bridge_timeout_sec = 30.0

(* Exit codes are the bridge script's contract (see its file header):
   0 ok, 1 unexpected, 2 target page not found, 3 assertion/tool missing. *)
let exit_page_not_found = 2
let exit_surface_or_tool_missing = 3

let default_runner ~timeout_sec argv =
  try Ok (Process_eio.run_argv_with_status_split ~timeout_sec argv) with
  | exn -> Error (Printexc.to_string exn)
;;

let script_mutex = Mutex.create ()
let script_path : string option ref = ref None

let materialize_script () =
  Mutex.protect script_mutex (fun () ->
    match !script_path with
    | Some path when Sys.file_exists path -> Ok path
    | Some _ | None ->
      (try
         let path = Filename.temp_file "masc-webmcp-bridge" ".mjs" in
         Out_channel.with_open_bin path (fun oc ->
           Out_channel.output_string oc Webmcp_bridge_source.source);
         script_path := Some path;
         Ok path
       with
       | exn -> Error (Bridge_unavailable (Printexc.to_string exn))))
;;

let bridge_argv ~script_path ~cdp_port ~page ~subcommand =
  ("node" :: script_path :: subcommand)
  @ [ "--port"; string_of_int cdp_port; "--page"; page ]
;;

let truncate_detail text =
  let limit = 400 in
  let text = String.trim text in
  if String.length text <= limit then text else String.sub text 0 limit ^ "…"
;;

let classify_exit status ~stdout ~stderr =
  match Process_eio.exit_reason_of_status status with
  | Process_eio.Completed 0 -> Ok stdout
  | Process_eio.Completed code when code = exit_page_not_found ->
    Error (Page_not_found (truncate_detail stderr))
  | Process_eio.Completed code when code = exit_surface_or_tool_missing ->
    Error
      (Surface_or_tool_missing
         (truncate_detail (if String.trim stderr = "" then stdout else stderr)))
  | Process_eio.Completed code ->
    Error
      (Bridge_failure
         (Printf.sprintf "exit %d: %s" code (truncate_detail stderr)))
  | Process_eio.Timed_out ->
    Error
      (Bridge_failure
         (Printf.sprintf "timed out after %.0fs" bridge_timeout_sec))
  | Process_eio.Signaled signal ->
    Error (Bridge_failure (Printf.sprintf "killed by signal %d" signal))
  | Process_eio.Stopped signal ->
    Error (Bridge_failure (Printf.sprintf "stopped by signal %d" signal))
;;

let default_cdp_port = 9222

let run ?(runner = default_runner) ?(cdp_port = default_cdp_port) ~page ~subcommand () =
  match materialize_script () with
  | Error _ as err -> err
  | Ok script_path ->
    let argv = bridge_argv ~script_path ~cdp_port ~page ~subcommand in
    (match runner ~timeout_sec:bridge_timeout_sec argv with
     | Error spawn_error -> Error (Bridge_unavailable spawn_error)
     | Ok (status, stdout, stderr) -> classify_exit status ~stdout ~stderr)
;;

let list_tools ?runner ?cdp_port ~page () =
  run ?runner ?cdp_port ~page ~subcommand:[ "list" ] ()
;;

let call_tool ?runner ?cdp_port ~page ~tool ~args_json () =
  match Yojson.Safe.from_string args_json with
  | exception Yojson.Json_error message -> Error (Invalid_args message)
  | `Assoc _ ->
    run ?runner ?cdp_port ~page ~subcommand:[ "call"; tool; args_json ] ()
  | _ -> Error (Invalid_args "args_json must be a JSON object")
;;
