(* Imessage_applescript — outbound side of the iMessage connector.

   The script takes its arguments through `on run argv`: Messages.app bodies
   are user text, and building the script by concatenation would make every
   reply an injection site. *)

type error =
  | Missing_chat_guid
  | Invalid_chat_guid
  | Osascript_failed of { exit_code : int; stderr : string }
  | Osascript_timed_out of float

let error_to_string = function
  | Missing_chat_guid -> "no chat guid to reply to"
  | Invalid_chat_guid -> "invalid chat guid"
  | Osascript_failed { exit_code; stderr } ->
    Printf.sprintf "osascript exited %d: %s" exit_code (String.trim stderr)
  | Osascript_timed_out seconds ->
    Printf.sprintf "osascript did not finish within %gs" seconds
;;

let script =
  "on run argv\n\
  \  tell application \"Messages\"\n\
  \    set targetChat to first chat whose id is (item 1 of argv)\n\
  \    send (item 2 of argv) to targetChat\n\
  \  end tell\n\
   end run"
;;

let is_valid_chat_guid chat_guid =
  String.length chat_guid > 0
  && chat_guid.[0] <> '-'
  && not
       (String.exists
          (fun c ->
            let code = Char.code c in
            code < 0x20 || code = 0x7f)
          chat_guid)
;;

let send_argv ~chat_guid ~text = [ "osascript"; "-e"; script; "--"; chat_guid; text ]

(* Messages.app blocks on the first-run Automation prompt, and that prompt is
   answered by a human at the console or not at all. Bounding the run keeps a
   waiting dialog from stalling the poll fiber behind it. *)
let default_timeout_sec = 15.

(* Process_eio synthesizes [WEXITED 124] on timeout, following timeout(1). *)
let timeout_exit_code = 124

let send ?(timeout_sec = default_timeout_sec) ~chat_guid ~text () =
  let chat_guid = String.trim chat_guid in
  if String.equal chat_guid "" then Error Missing_chat_guid
  else if not (is_valid_chat_guid chat_guid) then Error Invalid_chat_guid
  else (
    let argv = send_argv ~chat_guid ~text in
    match Process_eio.run_argv_with_status_split ~timeout_sec argv with
    | Unix.WEXITED 0, _stdout, _stderr -> Ok ()
    | Unix.WEXITED code, _stdout, _stderr when code = timeout_exit_code ->
      Error (Osascript_timed_out timeout_sec)
    | Unix.WEXITED code, _stdout, stderr ->
      Error (Osascript_failed { exit_code = code; stderr })
    | Unix.WSIGNALED signal, _stdout, stderr
    | Unix.WSTOPPED signal, _stdout, stderr ->
      Error
        (Osascript_failed
           { exit_code = signal
           ; stderr =
               Printf.sprintf "terminated by signal %d: %s" signal
                 (String.trim stderr)
           }))
;;
