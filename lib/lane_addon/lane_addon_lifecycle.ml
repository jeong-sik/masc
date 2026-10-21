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

type authority =
  | Container_authority of { runtime : Lane_addon_types.runtime; engine : engine }
  | Native_admission of { installation_id : string }
type resource =
  | Container_resource of string
  | Native_resource of { pid : int; started : string option }
let sorted_identity = List.sort (fun (a,_) (b,_) -> String.compare a b)
let authority_to_json = function
  | Container_authority {runtime;engine} -> `Assoc ["kind",`String "container";
      "runtime",`String (Lane_addon_types.runtime_to_string runtime);"engine",engine_to_json engine]
  | Native_admission {installation_id} -> `Assoc ["kind",`String "host_process";"installation_id",`String installation_id]
let authority_of_json = function
  | `Assoc fields -> (match sorted_identity fields with
      | ["engine",engine;"kind",`String "container";"runtime",`String runtime] ->
          Result.bind (engine_of_json engine) (fun engine ->
            Option.to_result ~none:"invalid owner runtime" (Lane_addon_types.runtime_of_string runtime)
            |> Result.map (fun runtime -> Container_authority {runtime;engine}))
      | ["installation_id",`String installation_id;"kind",`String "host_process"] when String.trim installation_id<>"" ->
          Ok (Native_admission {installation_id})
      | _ -> Error "invalid execution authority")
  | _ -> Error "invalid execution authority"
let resource_to_json = function
  | Container_resource id -> `Assoc ["kind",`String "container";"id",`String id]
  | Native_resource {pid;started} -> `Assoc ["kind",`String "host_process";"pid",`Int pid;
      "started",Option.fold ~none:`Null ~some:(fun text -> `String text) started]
let resource_of_json = function
  | `Assoc fields -> (match sorted_identity fields with
      | ["id",`String id;"kind",`String "container"] when String.trim id<>"" -> Ok (Container_resource id)
      | ["kind",`String "host_process";"pid",`Int pid;"started",started] when pid>1 ->
          (match started with
           | `Null -> Ok (Native_resource {pid;started=None})
           | `String text when String.trim text<>"" -> Ok (Native_resource {pid;started=Some text})
           | _ -> Error "invalid native process incarnation")
      | _ -> Error "invalid execution resource")
  | _ -> Error "invalid execution resource"
let container_id = function Container_resource id -> Some id | Native_resource _ -> None
let resource_to_string = function
  | Container_resource id -> "container " ^ id
  | Native_resource {pid;started} -> Printf.sprintf "native process %d%s" pid
      (Option.fold ~none:"" ~some:(fun value -> " (" ^ value ^ ")") started)

type observed_engine =
  | Other_engine of engine
  | Unreadable_engine of string

type holder = {
  container_id : string;
  instance : string option;
  state_owner : string option;
}

type failure =
  | Engine_unreachable of string
  | Engine_mismatch of { recorded : engine; observed : observed_engine }
  | Slot_foreign of holder
  | Slot_predecessor_unremovable of { instance_id : string; detail : string }
  | Worker_failed of string
  | Cleanup_unconfirmed of string
  | Persistence_failed of string
  | Previous_process
  | Effect_outcome_unknown of string

type failed = { cause : failure; first : failure option }
type release =
  | Never_created
  | Released of { engine : engine; container_id : string option }
  | Native_released of { installation_id : string; instance_id : string }
type state =
  | Attached
  | Observing
  | Failed of failed
  | Detaching of failed option
  | Detached of release
type condition = Engine_reachable | Engine_is of engine | Holder_changes of holder
type heal = Retry | Wait_until of condition

let ( let* ) = Result.bind

(* Every failure is listed. A new failure cannot be added without deciding here
   whether repeating the attempt is worth making. *)
let heal = function
  | Engine_unreachable _ -> Wait_until Engine_reachable
  | Engine_mismatch { recorded; _ } -> Wait_until (Engine_is recorded)
  | Slot_foreign holder -> Wait_until (Holder_changes holder)
  | Slot_predecessor_unremovable _ -> Retry
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

let observed_to_string = function
  | Other_engine engine -> engine_to_string engine
  | Unreadable_engine detail -> "an engine whose identity cannot be read (" ^ detail ^ ")"

let holder_to_string { container_id; instance; state_owner } =
  let label name = function None -> "no " ^ name ^ " label" | Some value -> name ^ " " ^ value in
  "container " ^ container_id ^ " (" ^ label "instance" instance ^ ", " ^ label "state owner" state_owner ^ ")"

let failure_to_string = function
  | Engine_unreachable detail -> "container engine is unreachable: " ^ detail
  | Slot_foreign holder ->
      "the worker's container slot is held by " ^ holder_to_string holder ^ ", which is not a dead predecessor of this worker"
  | Slot_predecessor_unremovable { instance_id; detail } ->
      "the worker's container slot is held by the dead predecessor " ^ instance_id ^ ", which could not be removed: " ^ detail
  | Engine_mismatch { recorded; observed } ->
      "the container engine is not the one that holds this worker: recorded "
      ^ engine_to_string recorded ^ ", reached " ^ observed_to_string observed
  | Worker_failed detail -> detail
  | Cleanup_unconfirmed detail -> "cleanup incomplete: " ^ detail
  | Persistence_failed detail -> detail
  | Previous_process ->
      "left unfinished by an earlier server process; its container is checked and removed on the next configuration pass"
  | Effect_outcome_unknown detail -> detail

let failure_detail = function
  | Cleanup_unconfirmed detail -> detail
  | (Engine_unreachable _ | Engine_mismatch _ | Slot_foreign _ | Slot_predecessor_unremovable _
    | Worker_failed _ | Persistence_failed _ | Previous_process | Effect_outcome_unknown _) as failure ->
      failure_to_string failure

let failed_to_string { cause; first } = match first with
  | None -> failure_to_string cause
  | Some earlier -> failure_to_string cause ^ " (first failure: " ^ failure_to_string earlier ^ ")"

let observed_to_json = function
  | Other_engine engine -> `Assoc ["kind", `String "other"; "engine", engine_to_json engine]
  | Unreadable_engine detail -> `Assoc ["kind", `String "unreadable"; "detail", `String detail]

let optional_string = function None -> `Null | Some value -> `String value
let holder_to_json { container_id; instance; state_owner } =
  `Assoc ["container_id", `String container_id; "instance", optional_string instance;
          "state_owner", optional_string state_owner]

let failure_to_json = function
  | Engine_unreachable detail -> `Assoc ["kind", `String "engine_unreachable"; "detail", `String detail]
  | Slot_foreign holder -> `Assoc ["kind", `String "slot_foreign"; "holder", holder_to_json holder]
  | Slot_predecessor_unremovable { instance_id; detail } ->
      `Assoc ["kind", `String "slot_predecessor_unremovable"; "instance_id", `String instance_id;
              "detail", `String detail]
  | Engine_mismatch { recorded; observed } ->
      `Assoc ["kind", `String "engine_mismatch"; "recorded", engine_to_json recorded;
              "observed", observed_to_json observed]
  | Worker_failed detail -> `Assoc ["kind", `String "worker_failed"; "detail", `String detail]
  | Cleanup_unconfirmed detail -> `Assoc ["kind", `String "cleanup_unconfirmed"; "detail", `String detail]
  | Persistence_failed detail -> `Assoc ["kind", `String "persistence_failed"; "detail", `String detail]
  | Previous_process -> `Assoc ["kind", `String "previous_process"]
  | Effect_outcome_unknown detail ->
      `Assoc ["kind", `String "effect_outcome_unknown"; "detail", `String detail]

let sorted fields = List.sort (fun (a, _) (b, _) -> String.compare a b) fields

let observed_of_json = function
  | `Assoc fields ->
      (match sorted fields with
       | ["engine", engine; "kind", `String "other"] ->
           let* engine = engine_of_json engine in Ok (Other_engine engine)
       | ["detail", `String detail; "kind", `String "unreadable"] -> Ok (Unreadable_engine detail)
       | _ -> Error "invalid observed container engine")
  | _ -> Error "invalid observed container engine"

let optional_string_of_json = function
  | `Null -> Ok None
  | `String value when String.trim value <> "" -> Ok (Some value)
  | _ -> Error "invalid container label"

let holder_of_json = function
  | `Assoc fields ->
      (match sorted fields with
       | ["container_id", `String container_id; "instance", instance; "state_owner", state_owner]
         when String.trim container_id <> "" ->
           let* instance = optional_string_of_json instance in
           let* state_owner = optional_string_of_json state_owner in
           Ok { container_id; instance; state_owner }
       | _ -> Error "invalid slot holder")
  | _ -> Error "invalid slot holder"

let failure_of_json = function
  | `Assoc fields ->
      (match sorted fields with
       | ["detail", `String detail; "kind", `String "engine_unreachable"] -> Ok (Engine_unreachable detail)
       | ["holder", holder; "kind", `String "slot_foreign"] ->
           let* holder = holder_of_json holder in Ok (Slot_foreign holder)
       | ["detail", `String detail; "instance_id", `String instance_id;
          "kind", `String "slot_predecessor_unremovable"] ->
           Ok (Slot_predecessor_unremovable { instance_id; detail })
       | ["kind", `String "engine_mismatch"; "observed", observed; "recorded", recorded] ->
           let* recorded = engine_of_json recorded in
           let* observed = observed_of_json observed in
           Ok (Engine_mismatch { recorded; observed })
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

let release_to_json = function
  | Never_created -> `Assoc ["kind", `String "never_created"]
  | Released { engine; container_id } ->
      `Assoc ["kind", `String "released"; "engine", engine_to_json engine;
              "container_id", (match container_id with None -> `Null | Some id -> `String id)]
  | Native_released {installation_id;instance_id} -> `Assoc ["kind",`String "native_released";
      "installation_id",`String installation_id;"instance_id",`String instance_id]

let release_of_json = function
  | `Assoc ["kind", `String "never_created"] -> Ok Never_created
  | `Assoc fields ->
      (match sorted fields with
       | ["container_id", container_id; "engine", engine; "kind", `String "released"] ->
           let* engine = engine_of_json engine in
           let* container_id = match container_id with
             | `Null -> Ok None
             | `String id when String.trim id <> "" -> Ok (Some id)
             | _ -> Error "invalid released container identity" in
           Ok (Released { engine; container_id })
       | ["installation_id",`String installation_id;"instance_id",`String instance_id;"kind",`String "native_released"]
         when String.trim installation_id<>"" && String.trim instance_id<>"" ->
           Ok (Native_released {installation_id;instance_id})
       | _ -> Error "invalid Lane release evidence")
  | _ -> Error "invalid Lane release evidence"

let project = function
  | Attached -> Lane_addon_types.Attached
  | Observing -> Lane_addon_types.Observing
  | Failed failed -> Lane_addon_types.Failed (failed_to_string failed)
  | Detaching _ -> Lane_addon_types.Detaching
  | Detached _ -> Lane_addon_types.Detached

let state_to_json = function
  | Attached -> `Assoc ["kind", `String "attached"]
  | Observing -> `Assoc ["kind", `String "observing"]
  | Failed failed -> `Assoc ["kind", `String "failed"; "failed", failed_to_json failed]
  | Detaching previous ->
      `Assoc ["kind", `String "detaching";
              "failed", (match previous with None -> `Null | Some failed -> failed_to_json failed)]
  | Detached release -> `Assoc ["kind", `String "detached"; "release", release_to_json release]

let state_of_json = function
  | `Assoc ["kind", `String "attached"] -> Ok Attached
  | `Assoc ["kind", `String "observing"] -> Ok Observing
  | `Assoc fields ->
      (match sorted fields with
       | ["kind", `String "detached"; "release", release] ->
           let* release = release_of_json release in Ok (Detached release)
       | ["failed", failed; "kind", `String "failed"] ->
           let* failed = failed_of_json failed in Ok (Failed failed)
       | ["failed", `Null; "kind", `String "detaching"] -> Ok (Detaching None)
       | ["failed", failed; "kind", `String "detaching"] ->
           let* failed = failed_of_json failed in Ok (Detaching (Some failed))
       | _ -> Error "invalid Lane lifecycle state")
  | _ -> Error "invalid Lane lifecycle state"
