module Headless = Runtime_vibe_headless

type stop =
  | Usage_error
  | Config_error
  | Infrastructure_failure
  | Turn_limit
  | Token_limit
  | Price_limit
  | Deadline
  | Terminated
  | Length
  | Refusal
  | Aborted
  | Unrecognized_outcome of string

let outcome_of_stop = function
  | Usage_error -> Headless.Usage_error
  | Config_error -> Headless.Config_error
  | Infrastructure_failure -> Headless.Infrastructure_failure
  | Turn_limit -> Headless.Turn_limit
  | Token_limit -> Headless.Token_limit
  | Price_limit -> Headless.Price_limit
  | Deadline -> Headless.Deadline
  | Terminated -> Headless.Terminated
  | Length -> Headless.Length
  | Refusal -> Headless.Refusal
  | Aborted -> Headless.Aborted
  | Unrecognized_outcome value -> Headless.Unrecognized_outcome value
;;

let stop_of_outcome = function
  | Headless.Finished -> None
  | Headless.Usage_error -> Some Usage_error
  | Headless.Config_error -> Some Config_error
  | Headless.Infrastructure_failure -> Some Infrastructure_failure
  | Headless.Turn_limit -> Some Turn_limit
  | Headless.Token_limit -> Some Token_limit
  | Headless.Price_limit -> Some Price_limit
  | Headless.Deadline -> Some Deadline
  | Headless.Terminated -> Some Terminated
  | Headless.Length -> Some Length
  | Headless.Refusal -> Some Refusal
  | Headless.Aborted -> Some Aborted
  | Headless.Unrecognized_outcome value -> Some (Unrecognized_outcome value)
;;

type error =
  | Not_finished of
      { stop : stop
      ; run_error : Headless.run_error option
      }
  | No_output
  | No_assistant_reply
  | Unrecognized_last_role of string
  | Unrecognized_last_entry of string
  | Unrecognized_reply_part of string

let error_to_string = function
  | Not_finished { stop; run_error = Some { message; _ } } ->
    Printf.sprintf
      "Vibe stopped at %s: %s"
      (Headless.outcome_to_wire (outcome_of_stop stop))
      message
  | Not_finished { stop; run_error = None } ->
    "Vibe stopped at " ^ Headless.outcome_to_wire (outcome_of_stop stop)
  | No_output -> "Vibe finished with no transcript on stdout"
  | No_assistant_reply -> "Vibe's transcript does not end in an assistant reply"
  | Unrecognized_last_role role ->
    "Vibe's transcript ends in a message whose role this decoder does not know: " ^ role
  | Unrecognized_last_entry kind ->
    "Vibe's transcript ends in an entry this decoder does not know: " ^ kind
  | Unrecognized_reply_part kind ->
    "Vibe's reply holds a part this decoder does not know: " ^ kind
;;

let text_of_parts parts =
  let rec loop acc = function
    | [] -> Ok (String.concat "" (List.rev acc))
    | Headless.Text text :: rest -> loop (text :: acc) rest
    | Headless.Unrecognized_part kind :: _ -> Error (Unrecognized_reply_part kind)
  in
  loop [] parts
;;

(* Only the last entry can be the reply. Skipping back past an entry would
   take an earlier assistant message, such as one written before a tool
   call, for the answer. *)
let reply entries =
  match List.rev entries with
  | [] -> Error No_assistant_reply
  | last :: _ ->
    (match last with
     | Headless.Message { role = Headless.Assistant; content = []; _ } ->
       Error No_assistant_reply
     | Headless.Message { role = Headless.Assistant; content = _ :: _ as parts; _ } ->
       text_of_parts parts
     | Headless.Message { role = Headless.User; _ }
     | Headless.Reasoning _
     | Headless.Effect _ -> Error No_assistant_reply
     | Headless.Message { role = Headless.Unrecognized_role role; _ } ->
       Error (Unrecognized_last_role role)
     | Headless.Unrecognized_entry { kind; _ } -> Error (Unrecognized_last_entry kind))
;;

let of_run (run : Runtime_vibe_cli.run) =
  match stop_of_outcome run.export.outcome, run.transcript with
  | Some stop, (Runtime_vibe_cli.No_output | Runtime_vibe_cli.Entries _) ->
    Error (Not_finished { stop; run_error = run.export.error })
  | None, Runtime_vibe_cli.No_output -> Error No_output
  | None, Runtime_vibe_cli.Entries entries -> reply entries
;;
