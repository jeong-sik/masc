module Headless = Runtime_vibe_headless

type error =
  | Not_finished of
      { outcome : Headless.outcome
      ; run_error : Headless.run_error option
      }
  | No_output
  | No_assistant_reply
  | Unrecognized_reply_part of string

let error_to_string = function
  | Not_finished { outcome; run_error = Some { message; _ } } ->
    Printf.sprintf "Vibe stopped at %s: %s" (Headless.outcome_to_wire outcome) message
  | Not_finished { outcome; run_error = None } ->
    "Vibe stopped at " ^ Headless.outcome_to_wire outcome
  | No_output -> "Vibe finished with no transcript on stdout"
  | No_assistant_reply -> "Vibe finished without an assistant reply"
  | Unrecognized_reply_part kind ->
    "Vibe's reply holds a part this decoder does not know: " ^ kind
;;

let assistant_content = function
  | Headless.Message { role = Headless.Assistant; content; _ } -> Some content
  | Headless.Message { role = Headless.User | Headless.Unrecognized_role _; _ }
  | Headless.Reasoning _ | Headless.Effect _ | Headless.Unrecognized_entry _ -> None
;;

let text_of_parts parts =
  let rec loop acc = function
    | [] -> Ok (String.concat "" (List.rev acc))
    | Headless.Text text :: rest -> loop (text :: acc) rest
    | Headless.Unrecognized_part kind :: _ -> Error (Unrecognized_reply_part kind)
  in
  loop [] parts
;;

let reply entries =
  match List.rev (List.filter_map assistant_content entries) with
  | [] | [] :: _ -> Error No_assistant_reply
  | (_ :: _ as parts) :: _ -> text_of_parts parts
;;

let of_run (run : Runtime_vibe_cli.run) =
  match run.export.outcome, run.transcript with
  | Headless.Finished, Runtime_vibe_cli.No_output -> Error No_output
  | Headless.Finished, Runtime_vibe_cli.Entries entries -> reply entries
  | ( ( Headless.Usage_error
      | Headless.Config_error
      | Headless.Infrastructure_failure
      | Headless.Turn_limit
      | Headless.Token_limit
      | Headless.Price_limit
      | Headless.Deadline
      | Headless.Terminated
      | Headless.Length
      | Headless.Refusal
      | Headless.Aborted
      | Headless.Unrecognized_outcome _ ) as outcome )
    , (Runtime_vibe_cli.No_output | Runtime_vibe_cli.Entries _) ->
    Error (Not_finished { outcome; run_error = run.export.error })
;;
