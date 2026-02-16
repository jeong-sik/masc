(** GAME-VIEW decision state store.

    Stores decision lifecycle records used by:
    - decision.create / decision.finalize
    - experiment.start / trpg.action.submit precondition checks
*)

open Yojson.Safe.Util

type decision = {
  decision_id: string;
  session_id: string;
  issue: string;
  options: string list;
  criteria: string list;
  weights: Yojson.Safe.t option;
  created_at: float;
  finalized_at: float option;
  selected_option: string option;
  rationale: string option;
  confidence: float option;
  verifier: string option;
  risk_ack: string option;
}

let decisions_path config =
  Filename.concat (Room.masc_dir config) "game_view_decisions.json"

let decision_to_json d =
  `Assoc [
    ("decision_id", `String d.decision_id);
    ("session_id", `String d.session_id);
    ("issue", `String d.issue);
    ("options", `List (List.map (fun s -> `String s) d.options));
    ("criteria", `List (List.map (fun s -> `String s) d.criteria));
    ("weights", match d.weights with Some w -> w | None -> `Null);
    ("created_at", `Float d.created_at);
    ("finalized_at", match d.finalized_at with Some ts -> `Float ts | None -> `Null);
    ("selected_option", match d.selected_option with Some s -> `String s | None -> `Null);
    ("rationale", match d.rationale with Some s -> `String s | None -> `Null);
    ("confidence", match d.confidence with Some c -> `Float c | None -> `Null);
    ("verifier", match d.verifier with Some s -> `String s | None -> `Null);
    ("risk_ack", match d.risk_ack with Some s -> `String s | None -> `Null);
  ]

let decision_of_json json =
  let decision_id = Safe_ops.json_string "decision_id" json in
  let session_id = Safe_ops.json_string "session_id" json in
  if decision_id = "" || session_id = "" then
    None
  else
    let weights =
      match json |> member "weights" with
      | (`Assoc _ as w) -> Some w
      | _ -> None
    in
    Some {
      decision_id;
      session_id;
      issue = Safe_ops.json_string "issue" json;
      options = Safe_ops.json_string_list "options" json;
      criteria = Safe_ops.json_string_list "criteria" json;
      weights;
      created_at = Safe_ops.json_float ~default:(Time_compat.now ()) "created_at" json;
      finalized_at = Safe_ops.json_float_opt "finalized_at" json;
      selected_option = Safe_ops.json_string_opt "selected_option" json;
      rationale = Safe_ops.json_string_opt "rationale" json;
      confidence = Safe_ops.json_float_opt "confidence" json;
      verifier = Safe_ops.json_string_opt "verifier" json;
      risk_ack = Safe_ops.json_string_opt "risk_ack" json;
    }

let load_decisions config =
  let path = decisions_path config in
  match Room_utils.read_json_opt config path with
  | None -> []
  | Some json ->
      (match json |> member "decisions" with
       | `List items -> List.filter_map decision_of_json items
       | _ -> [])

let save_decisions config decisions =
  let path = decisions_path config in
  Room_utils.write_json config path
    (`Assoc [("decisions", `List (List.map decision_to_json decisions))])

let create_decision config ~session_id ~issue ~options ~criteria ~weights =
  let now = Time_compat.now () in
  let decision_id =
    Printf.sprintf "decision-%Ld" (Int64.of_float (now *. 1_000_000.0))
  in
  let decision = {
    decision_id;
    session_id;
    issue;
    options;
    criteria;
    weights;
    created_at = now;
    finalized_at = None;
    selected_option = None;
    rationale = None;
    confidence = None;
    verifier = None;
    risk_ack = None;
  } in
  let decisions = load_decisions config in
  save_decisions config (decision :: decisions);
  decision

let is_finalized d = d.finalized_at <> None

let finalize_decision config
    ~session_id ~decision_id ~selected_option ~rationale
    ~confidence ~verifier ~risk_ack =
  let decisions = load_decisions config in
  let rec loop acc = function
    | [] ->
        Error (Printf.sprintf "decision not found: %s (session: %s)" decision_id session_id)
    | d :: rest ->
        if d.session_id = session_id && d.decision_id = decision_id then begin
          if not (List.mem selected_option d.options) then
            Error (Printf.sprintf
                     "selected_option '%s' not in decision options"
                     selected_option)
          else
            let finalized = {
              d with
              finalized_at = Some (Time_compat.now ());
              selected_option = Some selected_option;
              rationale = Some rationale;
              confidence;
              verifier = Some verifier;
              risk_ack;
            } in
            let merged = List.rev_append acc (finalized :: rest) in
            save_decisions config merged;
            Ok finalized
        end else
          loop (d :: acc) rest
  in
  loop [] decisions

let find_decision decisions ~session_id ~decision_id =
  List.find_opt
    (fun d -> d.session_id = session_id && d.decision_id = decision_id)
    decisions

let latest_finalized_decision config ~session_id =
  let score d =
    match d.finalized_at with
    | Some ts -> ts
    | None -> d.created_at
  in
  load_decisions config
  |> List.filter (fun d -> d.session_id = session_id && is_finalized d)
  |> List.sort (fun a b -> Float.compare (score b) (score a))
  |> function
     | head :: _ -> Some head
     | [] -> None

let finalized_decision_for_session ?decision_id config ~session_id =
  let decisions = load_decisions config in
  match decision_id with
  | Some did when String.trim did <> "" ->
      (match find_decision decisions ~session_id ~decision_id:did with
       | None ->
           Error (Printf.sprintf "decision not found: %s (session: %s)" did session_id)
       | Some d when not (is_finalized d) ->
           Error (Printf.sprintf "decision not finalized yet: %s" did)
       | Some d -> Ok d)
  | _ ->
      (match latest_finalized_decision config ~session_id with
       | Some d -> Ok d
       | None ->
           Error (Printf.sprintf
                    "no finalized decision for session: %s (decision.finalize required)"
                    session_id))
