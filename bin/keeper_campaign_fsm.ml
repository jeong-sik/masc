(** keeper_campaign_fsm — replay keeper campaign event logs into a final FSM snapshot.

    Usage:
      keeper_campaign_fsm replay <events.jsonl> [output.json]
*)

module Fsm = Masc_mcp.Keeper_campaign_fsm

let usage () =
  prerr_endline "Usage: keeper_campaign_fsm replay <events.jsonl> [output.json]";
  exit 1

let read_events path =
  let ic = open_in path in
  let rec loop acc =
    try
      let line = input_line ic in
      let trimmed = String.trim line in
      if trimmed = "" then loop acc
      else
        let json = Yojson.Safe.from_string trimmed in
        match Fsm.event_of_yojson_result json with
        | Ok event -> loop (event :: acc)
        | Error msg ->
          close_in_noerr ic;
          failwith (Printf.sprintf "failed to decode %s: %s" path msg)
    with End_of_file ->
      close_in ic;
      List.rev acc
  in
  loop []

let write_snapshot path snapshot =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> Yojson.Safe.pretty_to_channel oc (Fsm.snapshot_to_yojson snapshot))

let () =
  let args = Array.to_list Sys.argv in
  match args with
  | [ _; "replay"; events_path ] -> (
      match Fsm.replay (read_events events_path) with
      | Ok snapshot ->
        Yojson.Safe.pretty_to_channel stdout (Fsm.snapshot_to_yojson snapshot);
        output_char stdout '\n'
      | Error msg ->
        prerr_endline msg;
        exit 2)
  | [ _; "replay"; events_path; output_path ] -> (
      match Fsm.replay (read_events events_path) with
      | Ok snapshot ->
        write_snapshot output_path snapshot;
        Yojson.Safe.pretty_to_channel stdout (Fsm.snapshot_to_yojson snapshot);
        output_char stdout '\n'
      | Error msg ->
        prerr_endline msg;
        exit 2)
  | _ -> usage ()
