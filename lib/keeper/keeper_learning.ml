(** Keeper_learning — Decision recording and replay for keeper deliberation.

    Records every deliberation decision to a JSONL file per keeper, enabling
    post-hoc analysis, outcome tracking, and human feedback loops. *)

open Keeper_types

(** A single deliberation decision record. *)
type decision_record = {
  id : string;
  keeper_name : string;
  timestamp : float;
  triggers : string list;
  observation_json : Yojson.Safe.t;
  prompt_hash : string;
  action_chosen : string;
  action_json : Yojson.Safe.t;
  reasoning : string;
  confidence : float;
  cost_usd : float;
  outcome : string;
  outcome_detail : string;
  feedback_score : float option;
  feedback_comment : string;
}

(* Fiber-safe RNG for ID generation *)
let rng = Random.State.make_self_init ()

let generate_decision_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rand = Random.State.int rng 10_000 in
  Printf.sprintf "dec-%d-%04d" ts rand

let prompt_hash prompt =
  String.sub (Digest.to_hex (Digest.string prompt)) 0 8

let decision_record_to_json (r : decision_record) : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String r.id);
      ("keeper_name", `String r.keeper_name);
      ("timestamp", `Float r.timestamp);
      ("triggers", `List (List.map (fun s -> `String s) r.triggers));
      ("observation_json", r.observation_json);
      ("prompt_hash", `String r.prompt_hash);
      ("action_chosen", `String r.action_chosen);
      ("action_json", r.action_json);
      ("reasoning", `String r.reasoning);
      ("confidence", `Float r.confidence);
      ("cost_usd", `Float r.cost_usd);
      ("outcome", `String r.outcome);
      ("outcome_detail", `String r.outcome_detail);
      ( "feedback_score",
        match r.feedback_score with
        | Some s -> `Float s
        | None -> `Null );
      ("feedback_comment", `String r.feedback_comment);
    ]

let decision_record_of_json (json : Yojson.Safe.t) : decision_record option =
  try
    let id = Safe_ops.json_string ~default:"" "id" json in
    let keeper_name = Safe_ops.json_string ~default:"" "keeper_name" json in
    if id = "" || keeper_name = "" then None
    else
      Some
        {
          id;
          keeper_name;
          timestamp = Safe_ops.json_float ~default:0.0 "timestamp" json;
          triggers = Safe_ops.json_string_list "triggers" json;
          observation_json =
            (let open Yojson.Safe.Util in
            try json |> member "observation_json" with Type_error _ -> `Null);
          prompt_hash = Safe_ops.json_string ~default:"" "prompt_hash" json;
          action_chosen = Safe_ops.json_string ~default:"" "action_chosen" json;
          action_json =
            (let open Yojson.Safe.Util in
            try json |> member "action_json" with Type_error _ -> `Null);
          reasoning = Safe_ops.json_string ~default:"" "reasoning" json;
          confidence = Safe_ops.json_float ~default:0.0 "confidence" json;
          cost_usd = Safe_ops.json_float ~default:0.0 "cost_usd" json;
          outcome = Safe_ops.json_string ~default:"pending" "outcome" json;
          outcome_detail =
            Safe_ops.json_string ~default:"" "outcome_detail" json;
          feedback_score = Safe_ops.json_float_opt "feedback_score" json;
          feedback_comment =
            Safe_ops.json_string ~default:"" "feedback_comment" json;
        }
  with exn ->
    Log.Misc.warn "keeper_learning: decision record parse failed: %s" (Printexc.to_string exn);
    None

let decisions_path (config : Room.config) (name : string) : string =
  Filename.concat (keeper_dir config) (name ^ ".decisions.jsonl")

let record_decision (config : Room.config) (record : decision_record) : unit =
  let path = decisions_path config record.keeper_name in
  append_jsonl_line path (decision_record_to_json record)

(** Read all decision lines from the JSONL file, returning parsed records. *)
let read_all_decision_lines (config : Room.config) ~(keeper_name : string) :
    decision_record list =
  let path = decisions_path config keeper_name in
  if not (Sys.file_exists path) then []
  else
    match Safe_ops.read_file_safe path with
    | Error _ -> []
    | Ok content ->
        content
        |> String.split_on_char '\n'
        |> List.filter (fun s -> String.trim s <> "")
        |> List.filter_map (fun line ->
               try
                 let json = Yojson.Safe.from_string line in
                 decision_record_of_json json
               with Yojson.Json_error _ -> None)

let read_decisions (config : Room.config) ~(keeper_name : string)
    ~(limit : int) : decision_record list =
  let all = read_all_decision_lines config ~keeper_name in
  (* newest first *)
  let sorted =
    List.sort (fun a b -> compare b.timestamp a.timestamp) all
  in
  if limit <= 0 then sorted
  else
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n <= 0 -> List.rev acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    take limit [] sorted

(** Rewrite the entire decisions file with updated records.
    Used by record_outcome and record_feedback to update individual lines. *)
let rewrite_decisions (config : Room.config) ~(keeper_name : string)
    (records : decision_record list) : unit =
  let path = decisions_path config keeper_name in
  let tmp_path = path ^ ".tmp" in
  let buf = Buffer.create 4096 in
  List.iter
    (fun r ->
      Buffer.add_string buf (Yojson.Safe.to_string (decision_record_to_json r));
      Buffer.add_char buf '\n')
    records;
  Fs_compat.save_file tmp_path (Buffer.contents buf);
  Sys.rename tmp_path path

let record_outcome (config : Room.config) ~(keeper_name : string)
    ~(decision_id : string) ~(outcome : string) ~(detail : string) : unit =
  let all = read_all_decision_lines config ~keeper_name in
  let found = ref false in
  let updated =
    List.map
      (fun r ->
        if r.id = decision_id then (
          found := true;
          { r with outcome; outcome_detail = detail })
        else r)
      all
  in
  if !found then rewrite_decisions config ~keeper_name updated

let record_feedback (config : Room.config) ~(keeper_name : string)
    ~(decision_id : string) ~(score : float) ~(comment : string) : unit =
  let clamped_score = Float.max (-1.0) (Float.min 1.0 score) in
  let all = read_all_decision_lines config ~keeper_name in
  let found = ref false in
  let updated =
    List.map
      (fun r ->
        if r.id = decision_id then (
          found := true;
          { r with feedback_score = Some clamped_score; feedback_comment = comment })
        else r)
      all
  in
  if !found then rewrite_decisions config ~keeper_name updated
