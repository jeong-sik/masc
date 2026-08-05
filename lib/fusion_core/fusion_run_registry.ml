type outcome =
  | Succeeded
  | Failed of
      { reason : string
      ; code : string
      }

type run_status =
  | Running
  | Completed of outcome

type run =
  { run_id : string
  ; keeper : string
  ; preset : string
  ; started_at : float
  ; status : run_status
  }

module Payload = struct
  type registration =
    { keeper : string
    ; preset : string
    }

  type completion = outcome

  let name = "fusion_run_registry"
  let running_noun = "run(s)"
  let restart_reason = "worker fibers do not survive server restart"

  let registration_to_yojson registration =
    `Assoc
      [ "keeper", `String registration.keeper
      ; "preset", `String registration.preset
      ]
  ;;

  let registration_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* () =
      Run_registry_core.Json.exact_fields ~required:[ "keeper"; "preset" ] fields
    in
    let* keeper = Run_registry_core.Json.string_field "keeper" fields in
    let* preset = Run_registry_core.Json.string_field "preset" fields in
    Ok { keeper; preset }
  ;;

  let completion_to_yojson = function
    | Succeeded -> `Assoc [ "outcome", `String "succeeded" ]
    | Failed { reason; code } ->
      `Assoc
        [ "outcome", `String "failed"
        ; "reason", `String reason
        ; "code", `String code
        ]
  ;;

  let completion_of_yojson json =
    let ( let* ) = Result.bind in
    let* fields = Run_registry_core.Json.object_fields json in
    let* label = Run_registry_core.Json.string_field "outcome" fields in
    match label with
    | "succeeded" ->
      let* () =
        Run_registry_core.Json.exact_fields ~required:[ "outcome" ] fields
      in
      Ok Succeeded
    | "failed" ->
      let* () =
        Run_registry_core.Json.exact_fields
          ~required:[ "outcome"; "reason"; "code" ]
          fields
      in
      let* reason = Run_registry_core.Json.string_field "reason" fields in
      let* code = Run_registry_core.Json.string_field "code" fields in
      Ok (Failed { reason; code })
    | other -> Error (Printf.sprintf "unknown fusion outcome %S" other)
  ;;
end

module Store = Run_registry_core.Make (Payload)

type t = Store.t

let create = Store.create
let replay = Store.replay
let max_completed_retained = Store.max_completed_retained

let register_running t ~run_id ~keeper ~preset ~started_at =
  Store.register t ~id:run_id ~started_at ~registration:{ Payload.keeper; preset }
;;

let mark_completed t ~run_id ~outcome =
  match Store.complete t ~id:run_id ~completion:outcome with
  | `Completed -> ()
  | `Unknown -> ()
;;

let run_of_entry (entry : Store.entry) =
  let status =
    match entry.status with
    | Store.Running -> Running
    | Store.Completed outcome -> Completed outcome
  in
  { run_id = entry.id
  ; keeper = entry.registration.keeper
  ; preset = entry.registration.preset
  ; started_at = entry.started_at
  ; status
  }
;;

let list_runs t = List.map run_of_entry (Store.list_entries t)
let get t ~run_id = Option.map run_of_entry (Store.get t ~id:run_id)

let status_label = function
  | Running -> "running"
  | Completed Succeeded -> "completed"
  | Completed (Failed _) -> "failed"
;;

let run_to_yojson run =
  let base =
    [ "run_id", `String run.run_id
    ; "keeper", `String run.keeper
    ; "preset", `String run.preset
    ; "started_at", `Float run.started_at
    ; "status", `String (status_label run.status)
    ]
  in
  let failure_fields =
    match run.status with
    | Running | Completed Succeeded -> []
    | Completed (Failed { reason; code }) ->
      [ "error", `String reason; "failure_code", `String code ]
  in
  `Assoc (base @ failure_fields)
;;

type global_install_error = Already_installed

module Global = Run_registry_core.Global (struct
    type nonrec t = t

    let initial = create ()
  end)

let global = Global.current

let install_global registry =
  match Global.install registry with
  | Ok () -> Ok ()
  | Error Global.Already_installed -> Error Already_installed
;;
