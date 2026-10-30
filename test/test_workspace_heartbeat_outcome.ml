(** A heartbeat that wrote nothing used to report success.

    [Workspace.heartbeat] returned a status string with three spellings —
    "<agent> heartbeat updated", "Agent <agent> not found", "Invalid agent file
    for <agent>" — and both readers decided success without parsing it.

    The MCP handler tested the first three bytes of the message against the
    UTF-8 encoding of a warning sign. No branch of [heartbeat] emits one, so
    the test could not fail and [masc_heartbeat] answered [Tool_result.ok] for
    an agent that does not exist.

    The keeper's work-as-heartbeat refresher treated any call that did not
    raise as proof that a session-bound workspace was writable, and a missing
    agent file returns without raising. That is the evidence it uses to reset
    [consecutive_failures].

    These cases pin the outcome an unwritten heartbeat now reports, and that
    the rendered message is unchanged. *)

open Alcotest

module Q = Masc.Workspace

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "heartbeat-outcome-%d" (Unix.getpid ()))
  in
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Array.iter (fun e -> rm (Filename.concat path e)) (Sys.readdir path);
        Sys.rmdir path)
      else Sys.remove path
  in
  rm dir;
  Unix.mkdir dir 0o755;
  Unix.putenv "MASC_BASE_PATH" dir;
  let config = Q.default_config dir in
  let (_ : string) = Q.init config ~agent_name:(Some "claude") in
  Fun.protect
    ~finally:(fun () ->
      let (_ : string) = Q.reset config in
      rm dir)
    (fun () -> f config)
;;

let outcome_name = function
  | Q.Heartbeat_updated _ -> "Heartbeat_updated"
  | Q.Agent_file_invalid _ -> "Agent_file_invalid"
  | Q.Agent_not_found _ -> "Agent_not_found"
;;

(* The defect in one case: nothing was written, and the old readers called it
   a success. *)
let test_unknown_agent_is_not_an_update () =
  with_workspace (fun config ->
    let outcome = Q.heartbeat config ~agent_name:"no-such-agent" in
    check string "outcome" "Agent_not_found" (outcome_name outcome))
;;

let test_registered_agent_updates () =
  with_workspace (fun config ->
    let (_ : string) = Q.bind_session config ~agent_name:"alpha" ~capabilities:[] () in
    let outcome = Q.heartbeat config ~agent_name:"alpha" in
    check string "outcome" "Heartbeat_updated" (outcome_name outcome))
;;

(* Callers that log the outcome keep the strings they had. *)
let test_messages_are_unchanged () =
  check string "not found" "Agent ghost not found"
    (Q.heartbeat_message (Q.Agent_not_found "ghost"));
  check string "invalid" "Invalid agent file for alpha"
    (Q.heartbeat_message (Q.Agent_file_invalid "alpha"));
  check string "updated" "alpha heartbeat updated"
    (Q.heartbeat_message (Q.Heartbeat_updated "alpha"))
;;

(* None of the messages carries the warning-sign prefix the MCP handler used to
   look for, which is why that test always passed. *)
let test_no_message_carries_a_warning_prefix () =
  List.iter
    (fun outcome ->
      let message = Q.heartbeat_message outcome in
      check bool
        (Printf.sprintf "%s has no warning prefix" (outcome_name outcome))
        false
        (String.length message >= 3
         && Char.code message.[0] = 0xe2
         && Char.code message.[1] = 0x9a
         && Char.code message.[2] = 0xa0))
    [ Q.Heartbeat_updated "alpha"
    ; Q.Agent_file_invalid "alpha"
    ; Q.Agent_not_found "ghost"
    ]
;;

let () =
  Alcotest.run
    "Workspace heartbeat outcome"
    [ ( "outcome"
      , [ test_case "an unknown agent is not an update" `Quick
            test_unknown_agent_is_not_an_update
        ; test_case "a registered agent updates" `Quick test_registered_agent_updates
        ] )
    ; ( "rendering"
      , [ test_case "messages are unchanged" `Quick test_messages_are_unchanged
        ; test_case "no message carries a warning prefix" `Quick
            test_no_message_carries_a_warning_prefix
        ] )
    ]
;;
