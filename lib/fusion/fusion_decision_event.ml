open Result.Syntax

type disposition = Adopted | Rejected | Modified

let disposition_to_string = function
  | Adopted -> "adopted"
  | Rejected -> "rejected"
  | Modified -> "modified"

let disposition_of_string = function
  | "adopted" -> Ok Adopted
  | "rejected" -> Ok Rejected
  | "modified" -> Ok Modified
  | _ -> Error "decision must be adopted, rejected or modified"

type proposal =
  { run_id : string
  ; task_id : string
  ; disposition : disposition
  ; choice : string
  ; reason : string
  }

let parse json =
  let* fields = match json with `Assoc fields -> Ok fields | _ -> Error "decision must be an object" in
  let names = List.map fst fields in
  if List.exists (fun name -> not (List.mem name ["run_id"; "task_id"; "decision"; "choice"; "reason"])) names
     || List.length names <> List.length (List.sort_uniq String.compare names)
  then Error "unknown or duplicate decision fields"
  else
    let string name = match List.assoc_opt name fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | _ -> Error (name ^ " must be nonblank") in
    let* run_id = string "run_id" in
    let* task_id = string "task_id" in
    let* decision = string "decision" in
    let* disposition = disposition_of_string decision in
    let* choice = string "choice" in
    let* reason = string "reason" in
    Ok { run_id; task_id; disposition; choice; reason }

type payload =
  { decision_id : string
  ; proposal : proposal
  ; post_id : string
  ; evidence_sha256 : string
  ; goal_ids : string list
  ; agent : string
  ; turn_ref : Ids.Turn_ref.t
  ; turn_ref_wire : Yojson.Safe.t
  }

type t =
  { payload : payload
  ; timestamp : string
  ; json : Yojson.Safe.t
  }

let prepare ~decision_id ~post_id ~evidence_sha256 ~goal_ids ~agent ~turn_ref proposal =
  { decision_id; proposal; post_id; evidence_sha256; goal_ids; agent; turn_ref
  ; turn_ref_wire = Ids.Turn_ref.to_yojson turn_ref
  }

let decode_selected json =
  let names = ["type"; "decision_id"; "fusion_run_id"; "fusion_post_id"; "fusion_evidence_sha256"; "task";
    "goal_ids"; "agent"; "actor_kind"; "turn_ref"; "decision"; "choice"; "reason"; "ts"] in
  let* fields = match json with
    | `Assoc fields when List.sort String.compare (List.map fst (List.remove_assoc "notes" fields)) = List.sort String.compare names -> Ok fields
    | _ -> Error "invalid Fusion decision event fields" in
  let value key = List.assoc key fields in
  let string key = match value key with `String text when String.trim text <> "" -> Ok text
    | _ -> Error ("invalid decision event " ^ key) in
  let* decision_id = string "decision_id" in
  let* run_id = string "fusion_run_id" in
  let* post_id = string "fusion_post_id" in
  let* evidence_sha256 = string "fusion_evidence_sha256" in
  let* task_id = string "task" in
  let* agent = string "agent" in
  let* timestamp = string "ts" in
  let* decision = string "decision" in
  let* disposition = disposition_of_string decision in
  let* choice = string "choice" in
  let* reason = string "reason" in
  let turn_ref_wire = value "turn_ref" in
  let* turn_ref = Ids.Turn_ref.of_yojson turn_ref_wire in
  let* goal_ids = match value "goal_ids" with
    | `List goals ->
        let rec strings acc = function
          | [] -> Ok (List.rev acc)
          | `String id :: rest when String.trim id <> "" -> strings (id :: acc) rest
          | _ -> Error "invalid decision Goal context"
        in
        strings [] goals
    | _ -> Error "invalid decision Goal context" in
  if value "actor_kind" <> `String "keeper" then Error "invalid decision actor kind"
  else
    let proposal = { run_id; task_id; disposition; choice; reason } in
    let payload =
      { decision_id; proposal; post_id; evidence_sha256; goal_ids; agent
      ; turn_ref; turn_ref_wire
      }
    in
    Ok { payload; timestamp; json }

let select_for_run ~run_id json =
  if Json_util.get_string json "type" = Some "fusion_decision"
     && Json_util.get_string json "fusion_run_id" = Some run_id
  then Result.map Option.some (decode_selected json)
  else Ok None

let decision_id event = event.payload.decision_id
let agent event = event.payload.agent
let timestamp event = event.timestamp
let to_yojson event = event.json

let matches_payload event expected =
  let actual = event.payload in
  String.equal actual.decision_id expected.decision_id
  && actual.proposal = expected.proposal
  && String.equal actual.post_id expected.post_id
  && String.equal actual.evidence_sha256 expected.evidence_sha256
  && actual.goal_ids = expected.goal_ids
  && String.equal actual.agent expected.agent
  && Ids.Turn_ref.equal actual.turn_ref expected.turn_ref
  (* Parsing accepts multiple numeric spellings. Their original wire equality
     still decides whether this is the same recorded payload. *)
  && actual.turn_ref_wire = expected.turn_ref_wire

let encode payload ~timestamp =
  let proposal = payload.proposal in
  `Assoc
    [ "fusion_evidence_sha256", `String payload.evidence_sha256
    ; "type", `String "fusion_decision"
    ; "decision_id", `String payload.decision_id
    ; "fusion_run_id", `String proposal.run_id
    ; "fusion_post_id", `String payload.post_id
    ; "task", `String proposal.task_id
    ; "goal_ids", `List (List.map (fun id -> `String id) payload.goal_ids)
    ; "agent", `String payload.agent
    ; "actor_kind", `String "keeper"
    ; "turn_ref", payload.turn_ref_wire
    ; "decision", `String (disposition_to_string proposal.disposition)
    ; "choice", `String proposal.choice
    ; "reason", `String proposal.reason
    ; "ts", `String timestamp
    ]
