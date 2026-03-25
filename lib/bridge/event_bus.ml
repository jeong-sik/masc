(** Event Bus - Communication bridge between MASC and External Viewers (e.g., Bevy) *)

type event_type = 
  | TurnStarted of string (* Agent Name *)
  | ActionPerformed of { agent: string; action: string; target: string option }
  | JudgmentMade of { agent: string; result: string }
  | DialogueSpoken of { agent: string; text: string }

let to_json = function
  | TurnStarted name ->
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "TurnStarted");
        ("agent", `String name);
      ])
  | ActionPerformed { agent; action; target } ->
      let target_val = match target with Some t -> `String t | None -> `Null in
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "ActionPerformed");
        ("agent", `String agent);
        ("action", `String action);
        ("target", target_val);
      ])
  | JudgmentMade { agent; result } ->
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "JudgmentMade");
        ("agent", `String agent);
        ("result", `String result);
      ])
  | DialogueSpoken { agent; text } ->
      Yojson.Safe.to_string (`Assoc [
        ("type", `String "DialogueSpoken");
        ("agent", `String agent);
        ("text", `String text);
      ])

let broadcast event =
  let json = to_json event in
  let log_path = "logs/game_events.jsonl" in
  let oc = open_out_gen [Open_append; Open_creat] 0o666 log_path in
  output_string oc (json ^ "\n");
  close_out oc;
  Printf.eprintf "[event_bus] Event broadcasted: %s\n%!" json
