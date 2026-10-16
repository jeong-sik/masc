type engine = Docker_engine of string | Apple_app_root of string
type engine_fault =
  | Unreachable of string
  | Identity_unreadable of string

let engine_equal left right = match left, right with
  | Docker_engine a, Docker_engine b -> String.equal a b
  | Apple_app_root a, Apple_app_root b -> String.equal a b
  | Docker_engine _, Apple_app_root _ | Apple_app_root _, Docker_engine _ -> false

let engine_to_string = function
  | Docker_engine id -> "docker engine " ^ id
  | Apple_app_root root -> "Apple container service at " ^ root

let engine_to_json = function
  | Docker_engine id -> `Assoc ["kind", `String "docker"; "id", `String id]
  | Apple_app_root root -> `Assoc ["kind", `String "apple_container"; "app_root", `String root]

let engine_of_json = function
  | `Assoc fields ->
      (match List.sort (fun (a, _) (b, _) -> String.compare a b) fields with
       | ["id", `String id; "kind", `String "docker"] when String.trim id <> "" ->
           Ok (Docker_engine id)
       | ["app_root", `String root; "kind", `String "apple_container"] when String.trim root <> "" ->
           Ok (Apple_app_root root)
       | _ -> Error "invalid container engine identity")
  | _ -> Error "invalid container engine identity"

type failure =
  | Engine_unreachable of string
  | Worker_failed of string
  | Cleanup_unconfirmed of string
  | Persistence_failed of string
  | Previous_process
  | Effect_outcome_unknown of string

type failed = { cause : failure; first : failure option }
type state =
  | Attached
  | Observing
  | Failed of failed
  | Detaching of failed option
  | Detached
type condition = Engine_reachable
type heal = Retry | Wait_until of condition

let ( let* ) = Result.bind

(* Every failure is listed. A new failure cannot be added without deciding here
   whether repeating the attempt is worth making. *)
let heal = function
  | Engine_unreachable _ -> Wait_until Engine_reachable
  | Worker_failed _ -> Retry
  | Cleanup_unconfirmed _ -> Retry
  | Persistence_failed _ -> Retry
  | Previous_process -> Retry
  | Effect_outcome_unknown _ -> Retry

let failed cause = { cause; first = None }
let fail_again previous cause =
  let first = match previous.first with
    | Some _ as kept -> kept
    | None -> if previous.cause = cause then None else Some previous.cause in
  { cause; first }

let failure_to_string = function
  | Engine_unreachable detail -> "container engine is unreachable: " ^ detail
  | Worker_failed detail -> detail
  | Cleanup_unconfirmed detail -> "cleanup incomplete: " ^ detail
  | Persistence_failed detail -> detail
  | Previous_process -> "previous process; explicit detach can verify container cleanup"
  | Effect_outcome_unknown detail -> detail

let failure_detail = function
  | Cleanup_unconfirmed detail -> detail
  | (Engine_unreachable _ | Worker_failed _ | Persistence_failed _ | Previous_process
    | Effect_outcome_unknown _) as failure -> failure_to_string failure

let failed_to_string { cause; first } = match first with
  | None -> failure_to_string cause
  | Some earlier -> failure_to_string cause ^ " (first failure: " ^ failure_to_string earlier ^ ")"

let failure_to_json = function
  | Engine_unreachable detail -> `Assoc ["kind", `String "engine_unreachable"; "detail", `String detail]
  | Worker_failed detail -> `Assoc ["kind", `String "worker_failed"; "detail", `String detail]
  | Cleanup_unconfirmed detail -> `Assoc ["kind", `String "cleanup_unconfirmed"; "detail", `String detail]
  | Persistence_failed detail -> `Assoc ["kind", `String "persistence_failed"; "detail", `String detail]
  | Previous_process -> `Assoc ["kind", `String "previous_process"]
  | Effect_outcome_unknown detail ->
      `Assoc ["kind", `String "effect_outcome_unknown"; "detail", `String detail]

let sorted fields = List.sort (fun (a, _) (b, _) -> String.compare a b) fields

let failure_of_json = function
  | `Assoc fields ->
      (match sorted fields with
       | ["detail", `String detail; "kind", `String "engine_unreachable"] -> Ok (Engine_unreachable detail)
       | ["detail", `String detail; "kind", `String "worker_failed"] -> Ok (Worker_failed detail)
       | ["detail", `String detail; "kind", `String "cleanup_unconfirmed"] -> Ok (Cleanup_unconfirmed detail)
       | ["detail", `String detail; "kind", `String "persistence_failed"] -> Ok (Persistence_failed detail)
       | ["kind", `String "previous_process"] -> Ok Previous_process
       | ["detail", `String detail; "kind", `String "effect_outcome_unknown"] ->
           Ok (Effect_outcome_unknown detail)
       | _ -> Error "invalid Lane failure")
  | _ -> Error "invalid Lane failure"

let failed_to_json { cause; first } =
  `Assoc ["cause", failure_to_json cause;
          "first", (match first with None -> `Null | Some earlier -> failure_to_json earlier)]

let failed_of_json = function
  | `Assoc fields ->
      (match sorted fields with
       | ["cause", cause; "first", first] ->
           let* cause = failure_of_json cause in
           let* first = match first with
             | `Null -> Ok None
             | json -> Result.map Option.some (failure_of_json json) in
           Ok { cause; first }
       | _ -> Error "invalid Lane failure record")
  | _ -> Error "invalid Lane failure record"

let project = function
  | Attached -> Lane_addon_types.Attached
  | Observing -> Lane_addon_types.Observing
  | Failed failed -> Lane_addon_types.Failed (failed_to_string failed)
  | Detaching _ -> Lane_addon_types.Detaching
  | Detached -> Lane_addon_types.Detached

let state_to_json = function
  | Attached -> `Assoc ["kind", `String "attached"]
  | Observing -> `Assoc ["kind", `String "observing"]
  | Failed failed -> `Assoc ["kind", `String "failed"; "failed", failed_to_json failed]
  | Detaching previous ->
      `Assoc ["kind", `String "detaching";
              "failed", (match previous with None -> `Null | Some failed -> failed_to_json failed)]
  | Detached -> `Assoc ["kind", `String "detached"]

let state_of_json = function
  | `Assoc ["kind", `String "attached"] -> Ok Attached
  | `Assoc ["kind", `String "observing"] -> Ok Observing
  | `Assoc ["kind", `String "detached"] -> Ok Detached
  | `Assoc fields ->
      (match sorted fields with
       | ["failed", failed; "kind", `String "failed"] ->
           let* failed = failed_of_json failed in Ok (Failed failed)
       | ["failed", `Null; "kind", `String "detaching"] -> Ok (Detaching None)
       | ["failed", failed; "kind", `String "detaching"] ->
           let* failed = failed_of_json failed in Ok (Detaching (Some failed))
       | _ -> Error "invalid Lane lifecycle state")
  | _ -> Error "invalid Lane lifecycle state"
