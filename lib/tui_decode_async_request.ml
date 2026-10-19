open Result.Syntax
type target = { submitted_by : string; request_id : string; keeper_name : string }
let equal_target (a : target) (b : target) =
  String.equal a.submitted_by b.submitted_by && String.equal a.request_id b.request_id
  && String.equal a.keeper_name b.keeper_name
type source = { target : target; request_context : Yojson.Safe.t }
let equal_source a b = equal_target a.target b.target
  && Yojson.Safe.equal a.request_context b.request_context
type phase = Queued | Running | Cancelling | Waiting | Lost | Cancelled | Persistence_failed | Done of bool
type owner = { request_id : string; generation : int }
type decision = Rejected | Cancelled_continuation
type resolution =
  { owner : owner; decision : decision; requested_by : string; reason : string
  ; resolved_at : float; expected_version : string; marker_version : string }
type run =
  { run_id : string; source_task_id : string option; owner : owner
  ; journal_version : string; observed_at : float; resolution : resolution option }
type logical_value = Not_composition | Original_run of run
type logical = Confirmed of logical_value | Unavailable of string
type snapshot =
  { source : source; phase : phase; submitted_at : float; completed_at : float option
  ; dependencies : Keeper_composition_dependency.t list; result : Yojson.Safe.t option
  ; notice : string option; logical : logical }
type reading = Observed of snapshot | Absent

let fields ~required ?(optional=[]) json =
  Agent_core.Execution_json.object_fields ~context:"async request status" ~required ~optional json
let get fields name = match List.assoc_opt name fields with
  | Some value -> Ok value | None -> Error ("missing " ^ name)
let text = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error "expected nonblank text"
let identity json = let* value = text json in
  if String.equal value (String.trim value) then Ok value else Error "identity contains outer whitespace"
let string fields name = let* json = get fields name in identity json
let target_of_json json =
  let* fields = fields ~required:["submitted_by";"request_id";"keeper_name"] json in
  let* submitted_by = string fields "submitted_by" in
  let* request_id = string fields "request_id" in
  let* keeper_name = string fields "keeper_name" in
  Ok {submitted_by;request_id;keeper_name}
let number = function
  | `Float value when Float.is_finite value && value >= 0. -> Ok value
  | `Int value when value >= 0 -> Ok (float_of_int value)
  | _ -> Error "expected finite nonnegative time"
let time fields name = let* json = get fields name in number json
let digest fields name = let* value = string fields name in
  if String.length value = 64 && String.for_all
      (function '0'..'9' | 'a'..'f' -> true | _ -> false) value
  then Ok value else Error (name ^ " is not a SHA256 identity")
let owner json =
  let* fields = fields ~required:["request_id";"generation"] json in
  let* request_id = string fields "request_id" in
  let* generation = match List.assoc "generation" fields with
    | `Int value when value > 0 -> Ok value | _ -> Error "invalid owner generation" in
  Ok {request_id;generation}
let resolution json =
  let* f = fields ~required:["owner";"decision";"requested_by";"reason";"resolved_at";"expected_version";"marker_version"] json in
  let* owner = owner (List.assoc "owner" f) in
  let* decision = match List.assoc "decision" f with
    | `String "rejected" -> Ok Rejected | `String "cancelled" -> Ok Cancelled_continuation
    | _ -> Error "unknown logical resolution" in
  let* requested_by = string f "requested_by" in
  let* reason = text (List.assoc "reason" f) in
  let* resolved_at = time f "resolved_at" in
  let* expected_version = digest f "expected_version" in
  let* marker_version = digest f "marker_version" in
  Ok {owner;decision;requested_by;reason;resolved_at;expected_version;marker_version}
let logical ~request_context json =
  let* f = fields ~required:["kind"] ~optional:["observation";"detail"] json in
  let* kind = string f "kind" in
  match kind with
  | "not_composition" ->
    let* _ = fields ~required:["kind"] json in Ok (Confirmed Not_composition)
  | "unavailable" ->
    let* f = fields ~required:["kind";"detail"] json in
    let* detail = text (List.assoc "detail" f) in Ok (Unavailable detail)
  | "observed" ->
    let* f = fields ~required:["kind";"observation"] json in
    let* f = fields ~required:["composition_run_id";"source_task_id";"owner";"journal_version";"observed_at";"resolution"]
        (List.assoc "observation" f) in
    let* run_id = string f "composition_run_id" in
    let* _ = Keeper_tool_plan.Composition_run_id.of_string run_id
      |> Result.map_error (function Keeper_tool_plan.Composition_run_id.Invalid_uuid_v7 detail -> detail) in
    let* source_task_id = match List.assoc "source_task_id" f with
      | `Null -> Ok None | json -> identity json |> Result.map Option.some in
    let* owner = owner (List.assoc "owner" f) in
    let* journal_version = digest f "journal_version" in
    let* observed_at = time f "observed_at" in
    let* resolution = match List.assoc "resolution" f with
      | `Null -> Ok None | json -> resolution json |> Result.map Option.some in
    let* context = match request_context with
      | `Assoc f -> Ok f | _ -> Error "logical run lacks original request context" in
    let* original_run = string context "composition_run_id" in
    let* original_task = match List.assoc_opt "source_task_id" context with
      | None -> Ok None | Some json -> identity json |> Result.map Option.some in
    let* () = if String.equal run_id original_run && source_task_id = original_task
        && Option.fold ~none:true ~some:(fun (value : resolution) -> value.owner = owner) resolution
      then Ok () else Error "logical run/Task/resolution differs from original source" in
    Ok (Confirmed (Original_run {run_id;source_task_id;owner;journal_version;observed_at;resolution}))
  | _ -> Error "unknown continuation observation"

let decode ~target json =
  let* () = Agent_core.Execution_json.validate ~context:"async request status" json
    |> Result.map_error Agent_core.Execution_json.validation_error_to_string in
  let* f = fields ~required:["schema";"status"] ~optional:["request";"detail";"reason"] json in
  let* schema = string f "schema" in
  let* () = if schema = "masc.async-request-status/v1" then Ok () else Error "unknown async request schema" in
  let* status = string f "status" in
  match status with
  | "absent" -> let* _ = fields ~required:["schema";"status"] json in Ok Absent
  | "unavailable" | "rejected" ->
    let name = if status = "unavailable" then "detail" else "reason" in
    let* f = fields ~required:["schema";"status";name] json in
    let* detail = text (List.assoc name f) in Error (status ^ ": " ^ detail)
  | "observed" ->
    let* f = fields ~required:["schema";"status";"request"] json in
    let* f = fields ~required:["request_id";"submitted_by";"keeper_name";"request_context";"status";"submitted_at";"continuation"]
        ~optional:["completed_at";"elapsed_sec";"ok";"result";"dependencies";"worker_released"] (List.assoc "request" f) in
    let* request_id = string f "request_id" in
    let* submitted_by = string f "submitted_by" in
    let* keeper_name = string f "keeper_name" in
    let* () = if equal_target target {submitted_by;request_id;keeper_name} then Ok ()
      else Error "request status differs from the selected original owner/target" in
    let* request_context = match List.assoc "request_context" f with
      | (`Null | `Assoc _) as json -> Ok (Yojson.Safe.sort json) | _ -> Error "invalid original request context" in
    let* submitted_at = time f "submitted_at" in
    let* completed_at = match List.assoc_opt "completed_at" f with
      | None -> Ok None | Some json -> number json |> Result.map Option.some in
    let* status = string f "status" in
    let* phase = match status with
      | "queued" -> Ok Queued | "running" -> Ok Running | "cancelling" -> Ok Cancelling
      | "waiting_for_dependencies" -> Ok Waiting | "lost" -> Ok Lost
      | "cancelled" -> Ok Cancelled | "persistence_failed" -> Ok Persistence_failed
      | "done" | "error" -> (match status,List.assoc_opt "ok" f with
          | "done",Some (`Bool true) -> Ok (Done true)
          | "error",Some (`Bool false) -> Ok (Done false)
          | _ -> Error "completed phase and outcome disagree")
      | _ -> Error "unknown physical request phase" in
    let* () = match phase,completed_at with
      | (Queued | Running | Cancelling),None -> Ok ()
      | (Waiting | Lost | Cancelled | Persistence_failed | Done _),Some _ -> Ok ()
      | (Queued | Running | Cancelling),Some _
      | (Waiting | Lost | Cancelled | Persistence_failed | Done _),None ->
        Error "physical phase and completion boundary disagree" in
    let* () = match phase,List.assoc_opt "ok" f,List.assoc_opt "result" f with
      | (Queued | Running),None,None -> Ok ()
      | Waiting,None,Some _ -> Ok ()
      | (Cancelling | Lost | Cancelled | Persistence_failed),Some (`Bool false),Some _ -> Ok ()
      | Done expected,Some (`Bool ok),Some _ when expected=ok -> Ok ()
      | (Queued | Running | Waiting | Cancelling | Lost | Cancelled | Persistence_failed | Done _),_,_ ->
        Error "physical phase, outcome and retained result disagree" in
    let* dependencies = match phase,List.assoc_opt "dependencies" f,List.assoc_opt "worker_released" f with
      | Waiting,Some (`List values),Some (`Bool true) ->
        let* reversed = List.fold_left (fun prior json -> let* values = prior in
          let* value = Keeper_composition_dependency.of_json json in Ok (value::values)) (Ok []) values in
        if reversed = [] then Error "waiting physical owner has no dependencies" else Ok (List.rev reversed)
      | Waiting,_,_ -> Error "invalid physical dependency wait"
      | (Queued | Running | Cancelling | Lost | Cancelled | Persistence_failed | Done _),None,None -> Ok []
      | (Queued | Running | Cancelling | Lost | Cancelled | Persistence_failed | Done _),_,_ ->
        Error "dependency wait fields outside their physical phase" in
    let* logical = logical ~request_context (List.assoc "continuation" f) in
    let* notice = match phase with
      | Cancelling | Lost | Cancelled | Persistence_failed ->
        (match List.assoc_opt "result" f with
         | Some (`Assoc result) -> let* reason = get result "reason" in text reason |> Result.map Option.some
         | Some _ | None -> Error "physical failure lacks its original reason")
      | Queued | Running | Waiting | Done _ -> Ok None in
    Ok (Observed {source={target;request_context};phase;submitted_at;completed_at;dependencies;
      result=List.assoc_opt "result" f;notice;logical})
  | _ -> Error "unknown async request observation"
