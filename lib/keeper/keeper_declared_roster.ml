type requirement = Runtime_check_required | Sandbox_check_required | Declaration_invalid

type t = { name : string; requirements : requirement list }

let requirement_label = function
  | Runtime_check_required -> "모델 연결 확인 필요"
  | Sandbox_check_required -> "샌드박스 확인 필요"
  | Declaration_invalid -> "Keeper 선언 수정 필요"

let requirement_code = function
  | Runtime_check_required -> "runtime_check_required"
  | Sandbox_check_required -> "sandbox_check_required"
  | Declaration_invalid -> "declaration_invalid"

let missing ~base_path ~persisted_names =
  let snapshot = Keeper_types_profile.read_keeper_profile_snapshot ~base_path in
  Keeper_types_profile.snapshot_configured_keeper_names snapshot
  |> List.filter (fun name -> not (List.mem name persisted_names))
  |> List.map (fun name ->
    let requirements =
      match Keeper_types_profile.snapshot_profile_defaults snapshot name with
      | Ok _ -> [ Runtime_check_required; Sandbox_check_required ]
      | Error _ -> [ Declaration_invalid; Runtime_check_required; Sandbox_check_required ]
    in
    { name; requirements })

let to_json row =
  `Assoc
    [ "name", `String row.name
    ; "runtime_class", `String "keeper"
    ; "status", `String "unbooted"
    ; "phase", `String "Offline"
    ; "registered", `Bool false
    ; "keepalive_running", `Bool false
    ; "declaration_only", `Bool true
    ; "preparation_requirements", `List (List.map (fun requirement ->
        `String (requirement_code requirement)) row.requirements)
    ]
