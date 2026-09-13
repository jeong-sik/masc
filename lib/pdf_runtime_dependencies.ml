let commands = ["pdftotext"; "pdftoppm"]
let missing () = List.filter (fun command -> not (Executable_path.command_available command)) commands

type check =
  | Missing of string
  | Started of { command : string; output : string }
  | Failed of { command : string; status : Unix.process_status; detail : string }
type t = check list

(* A version probe answers straight away or is no use. Without a bound one
   wedged executable -- a wrapper waiting on input, a stalled network mount --
   holds the setup screen open for as long as it likes, and the sandbox menu
   asks for this before every draw. A spent budget is reported as a failed
   probe, which is what an unusable tool is; no new wire word is introduced. *)
let probe_timeout_sec = 10.

let observe () =
  List.map (fun command ->
    if not (Executable_path.command_available command) then Missing command
    else
      let status, stdout, stderr = Process_eio.run_argv_with_status_split
        ~timeout_sec:probe_timeout_sec
        ~env:(Env_keeper_scrub.filter_environment (Unix.environment ())) [command;"-v"] in
      let output = String.trim (stdout ^ "\n" ^ stderr) in
      match status with
      | Unix.WEXITED 0 -> Started {command;output}
      (* [run_argv_with_status_split] synthesises 124 on its own timeout, the
         way timeout(1) does. *)
      | Unix.WEXITED 124 ->
        Failed {command;status;
                detail=Printf.sprintf "%s -v did not answer within %.0f seconds"
                    command probe_timeout_sec}
      | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
        Failed {command;status;detail=output}) commands

let available checks =
  List.length checks = List.length commands
  && List.for_all (function Started _ -> true | Missing _ | Failed _ -> false) checks

let to_json checks =
  let rows = List.map (function
    | Missing command -> `Assoc ["command",`String command;"status",`String "missing"]
    | Started {command;output} -> `Assoc
        ["command",`String command;"status",`String "started";"output",`String output]
    | Failed {command;status;detail} ->
      let status = match status with
        | Unix.WEXITED code -> `Assoc ["exit_code",`Int code]
        | Unix.WSIGNALED signal -> `Assoc ["signal",`Int signal]
        | Unix.WSTOPPED signal -> `Assoc ["stopped_signal",`Int signal] in
      `Assoc ["command",`String command;"status",`String "failed";"process",status;"detail",`String detail]) checks in
  `Assoc ["schema",`String "masc.pdf_tools_readiness.v1";
          "status",`String (if available checks then "tools_available" else "unavailable");
          "scope",`String "current_process_environment";
          "checks",`List rows;"pdf_inspection",`String "not_run"]
