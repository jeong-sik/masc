open Result.Syntax

type composition =
  { request_id : string
  ; composition_run_id : Keeper_tool_plan.Composition_run_id.t
  ; skill_reference : Skill_reference.t
  ; composition_tool : string
  ; parent_tool_use_id : string
  ; source_turn : int
  ; source_task_id : string option
  }

let object_fields ~required ~optional json =
  Agent_core.Execution_json.object_fields
    ~context:"composition result dependency" ~required ~optional json

let string name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when value <> "" && String.equal value (String.trim value) -> Ok value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) | None ->
    Error ("invalid dependency field " ^ name)

let composition_of_json json =
  let* fields = object_fields
    ~required:["request_id"; "composition_run_id"; "skill_reference";
               "composition_tool"; "parent_tool_use_id"; "source_turn"]
    ~optional:["source_task_id"] json in
  let* request_id = string "request_id" fields in
  let* run_id = string "composition_run_id" fields in
  let* composition_run_id = Keeper_tool_plan.Composition_run_id.of_string run_id
    |> Result.map_error (fun _ -> "invalid composition run identity") in
  let* skill_reference = Skill_reference.of_yojson (List.assoc "skill_reference" fields)
    |> Result.map_error (fun _ -> "invalid exact Skill reference") in
  let* composition_tool = string "composition_tool" fields in
  let* parent_tool_use_id = string "parent_tool_use_id" fields in
  let* source_turn = match List.assoc "source_turn" fields with
    | `Int turn when turn >= 0 -> Ok turn
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
      Error "invalid original source turn" in
  let* source_task_id = match List.assoc_opt "source_task_id" fields with
    | None -> Ok None
    | Some _ -> string "source_task_id" fields |> Result.map Option.some in
  Ok {request_id; composition_run_id; skill_reference; composition_tool;
      parent_tool_use_id; source_turn; source_task_id}

let composition_to_json value =
  `Assoc
    (["request_id", `String value.request_id;
      "composition_run_id", `String (Keeper_tool_plan.Composition_run_id.to_string value.composition_run_id);
      "skill_reference", Skill_reference.to_yojson value.skill_reference;
      "composition_tool", `String value.composition_tool;
      "parent_tool_use_id", `String value.parent_tool_use_id;
      "source_turn", `Int value.source_turn]
     @ Option.to_list (Option.map (fun task -> "source_task_id", `String task) value.source_task_id))

let composition_of_request_context ~request_id context =
  let* fields = object_fields
    ~required:["composition_run_id"; "skill_reference"; "composition_tool";
               "parent_tool_use_id"; "source_turn"]
    ~optional:["source_task_id"; "draft_reference"; "run_artifact"] (`Assoc context) in
  composition_of_json (`Assoc (("request_id", `String request_id) ::
    List.filter (fun (name, _) -> name <> "draft_reference" && name <> "run_artifact") fields))

type t = Owned_job of Keeper_owned_job_identity.Job_id.t | Composition_result of composition
type readiness = Waiting | Ready

let to_json = function
  | Owned_job id -> `Assoc ["kind", `String "owned_job";
      "job_id", `String (Keeper_owned_job_identity.Job_id.to_string id)]
  | Composition_result binding -> `Assoc ["kind", `String "composition_result";
      "binding", composition_to_json binding]

let of_json json =
  let* fields = object_fields ~required:["kind"] ~optional:["job_id"; "binding"] json in
  let* kind = string "kind" fields in
  match kind with
  | "owned_job" ->
    let* fields = object_fields ~required:["kind"; "job_id"] ~optional:[] json in
    let* value = string "job_id" fields in
    Keeper_owned_job_identity.Job_id.of_string value |> Result.map (fun id -> Owned_job id)
  | "composition_result" ->
    let* fields = object_fields ~required:["kind"; "binding"] ~optional:[] json in
    composition_of_json (List.assoc "binding" fields) |> Result.map (fun binding -> Composition_result binding)
  | _ -> Error "unknown result dependency kind"

let identity dependency = Yojson.Safe.to_string (to_json dependency)
let normalize dependencies =
  match dependencies with
  | [] | [_] -> dependencies
  | _ :: _ :: _ ->
    dependencies
    |> List.map (fun dependency -> identity dependency, dependency)
    |> List.sort_uniq (fun (left, _) (right, _) -> String.compare left right)
    |> List.map snd

let list_of_json = function
  | `List (_ :: _ as values) ->
    let* decoded = List.fold_left (fun prior value ->
      let* decoded = prior in let* value = of_json value in Ok (value :: decoded)) (Ok []) values
      |> Result.map List.rev in
    if List.length (normalize decoded) <> List.length decoded
    then Error "result wait repeats a dependency" else Ok decoded
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List [] | `Assoc _ ->
    Error "result wait requires a nonempty dependency array"
