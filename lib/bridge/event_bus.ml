(** Event Bus - Communication bridge between MASC and External Viewers (e.g., Bevy) *)

type event_type = 
  | TurnStarted of string (* Agent Name *)
  | ActionPerformed of { agent: string; action: string; target: string option }
  | JudgmentMade of { agent: string; result: string }
  | DialogueSpoken of { agent: string; text: string }

let to_json = function
  | TurnStarted name -> 
      Printf.sprintf "{\"type\": \"TurnStarted\", \"agent\": \"%s\"}" name
  | ActionPerformed { agent; action; target } ->
      let target_str = match target with Some t -> t | None -> "null" in
      Printf.sprintf "{\"type\": \"ActionPerformed\", \"agent\": \"%s\", \"action\": \"%s\", \"target\": \"%s\"}" agent action target_str
  | JudgmentMade { agent; result } ->
      Printf.sprintf "{\"type\": \"JudgmentMade\", \"agent\": \"%s\", \"result\": \"%s\"}" agent result
  | DialogueSpoken { agent; text } ->
      Printf.sprintf "{\"type\": \"DialogueSpoken\", \"agent\": \"%s\", \"text\": \"%s\"}" agent text

let broadcast event =
  let json = to_json event in
  let log_path = "logs/game_events.jsonl" in
  let oc = open_out_gen [Open_append; Open_creat] 0o666 log_path in
  output_string oc (json ^ "\n");
  close_out oc;
  print_endline ("📡 Event Broadcasted: " ^ json)
