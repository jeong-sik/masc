type container =
  { name : string
  ; id : string
  ; image : string
  ; status : string
  ; running : bool option
  ; created_at : string option
  ; owner_pid : int option
  ; cpus : int option
  ; memory_bytes : int option
  ; hostname : string option
  ; ipv4_address : string option
  ; ipv6_address : string option
  ; gateway : string option
  }

type work_volume_discard_default =
  | Discard_set
  | Discard_absent
  | Discard_unreadable of string

type guest_size_issue = Guest_size_unresolved | Guest_size_unclassified

type resource_config =
  { memory : string option
  ; cpus : string option
  (* Why the guest size could not be resolved. Set when the keeper's or the
     workspace's size does not parse, which is the same refusal the next boot
     gives, so the operator reads it here before a turn hits it. *)
  ; guest_size_error : string option
  ; guest_size_issue : guest_size_issue option
  ; work_volume_size : string option
  ; work_volume_discard_default : work_volume_discard_default option
  ; pids_limit : int option
  ; tmpfs_size : string option
  }

type sandbox_paths =
  { host_workspace : string option
  ; guest_home : string option
  ; guest_workspace : string option
  ; guest_config : string option
  ; guest_work_volume : string option
  }

type sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

type image_issue =
  | Image_not_declared
  | Image_catalog_unreadable
  | Image_unknown_name
  | Image_not_promoted
  | Image_no_store
  | Image_issue_unclassified

type kata_host_alignment =
  | Host_selectors_match
  | Host_selectors_differ
  | Host_selectors_unavailable

type kata_name_observation =
  | Kata_not_applicable
  | Kata_name_absent
  | Kata_name_expected_runtime
  | Kata_name_other_runtime
  | Kata_name_runtime_unreported
  | Kata_name_unavailable

type inventory_error_code = Context_unavailable | Backend_unresolved | Other_inventory_error

type t =
  { sandbox_profile : sandbox_profile option
  ; configured_network_mode : string option
  ; configured_image_name : string option
  ; configured_image : string option
  ; configured_image_unresolved : string option
  ; configured_image_issue : image_issue option
  ; containers : container list option
  ; container_error : string option
  ; container_error_code : inventory_error_code option
  ; kata_name_observation : kata_name_observation option
  ; kata_scoped_name_seen : bool option
  ; kata_host_alignment : kata_host_alignment option
  ; resource_config : resource_config option
  ; paths : sandbox_paths option
  ; keeper_last_error : string option
  }

type inventory_decision =
  | Remote_execution_unobserved
  | Remote_inventory_inconsistent
  | Inventory_context_unavailable of string
  | Inventory_backend_unresolved of string
  | Inventory_failed of string
  | Inventory_unreported
  | Inventory_observed of { total : int; running : int; unknown : int }

let inventory_decision reading =
  match reading.container_error, reading.container_error_code, reading.containers, reading.sandbox_profile with
  | Some detail, Some Context_unavailable, _, _ -> Inventory_context_unavailable detail
  | Some detail, Some Backend_unresolved, _, _ -> Inventory_backend_unresolved detail
  | Some detail, (Some Other_inventory_error | None), _, _ -> Inventory_failed detail
  | None, _, None, _ -> Inventory_unreported
  | None, _, Some [], Some Remote_ssh -> Remote_execution_unobserved
  | None, _, Some (_ :: _), Some Remote_ssh -> Remote_inventory_inconsistent
  | None, _, Some containers, (Some (Docker | Micro_vm) | None) ->
    let running = List.fold_left (fun n c -> n + if c.running = Some true then 1 else 0) 0 containers in
    let unknown = List.fold_left (fun n c -> n + if c.running = None then 1 else 0) 0 containers in
    Inventory_observed {total = List.length containers; running; unknown}

type name_report =
  { name_state : kata_name_observation
  ; expected_name : string option
  ; network_mode : string
  ; host_alignment : kata_host_alignment option
  }

type load_result =
  | Inventory_result of (t, string) result
  | Name_result of (name_report, string) result

type partial =
  { inventory : (t, string) result option
  ; name : (name_report, string) result option
  }

let empty_partial = { inventory = None; name = None }

let add_partial partial = function
  | Inventory_result result when Option.is_none partial.inventory ->
    { partial with inventory = Some result }
  | Name_result result when Option.is_none partial.name ->
    { partial with name = Some result }
  | Inventory_result _ | Name_result _ -> partial

let partial_complete partial = Option.is_some partial.inventory && Option.is_some partial.name
let partial_results partial = partial.inventory, partial.name

let kata_name_observation reading = reading.kata_name_observation
let kata_scoped_name_seen reading = reading.kata_scoped_name_seen
let image_issue reading = reading.configured_image_issue
let guest_size_issue reading = Option.bind reading.resource_config (fun resources -> resources.guest_size_issue)
let kata_host_alignment reading = reading.kata_host_alignment

type kata_status_decision =
  | Kata_not_observed
  | Kata_inapplicable
  | Kata_scoped_name_seen
  | Kata_unscoped_expected_runtime
  | Kata_other_runtime
  | Kata_unreported_runtime
  | Kata_absent
  | Kata_unavailable

let kata_status_decision reading =
  match reading.kata_name_observation, reading.kata_scoped_name_seen with
  | None, _ -> Kata_not_observed
  | Some Kata_not_applicable, _ -> Kata_inapplicable
  | Some Kata_name_expected_runtime, Some true -> Kata_scoped_name_seen
  | Some Kata_name_expected_runtime, (Some false | None) -> Kata_unscoped_expected_runtime
  | Some Kata_name_other_runtime, _ -> Kata_other_runtime
  | Some Kata_name_runtime_unreported, _ -> Kata_unreported_runtime
  | Some Kata_name_absent, _ -> Kata_absent
  | Some Kata_name_unavailable, _ -> Kata_unavailable

let assoc field = function
  | `Assoc fields -> Ok fields
  | _ -> Error (field ^ " must be an object")

let field name fields = List.assoc_opt name fields

let string_opt ~sanitize ?key ~path fields =
  match field (Option.value key ~default:path) fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some (sanitize value))
  | Some _ -> Error (path ^ " must be a string or null")

let bool_opt ?key ~path fields =
  match field (Option.value key ~default:path) fields with
  | None | Some `Null -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some _ -> Error (path ^ " must be a boolean or null")

let int_opt ?key ~path fields =
  match field (Option.value key ~default:path) fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (path ^ " must be an integer or null")

let profile_opt ~sanitize fields =
  match field "sandbox_profile" fields with
  | None | Some `Null -> Ok None
  | Some (`String "docker") -> Ok (Some Docker)
  | Some (`String "microvm") -> Ok (Some Micro_vm)
  | Some (`String "remote_ssh") -> Ok (Some Remote_ssh)
  | Some (`String value) ->
    Error ("sandbox_profile has unsupported value " ^ sanitize value)
  | Some _ -> Error "sandbox_profile must be a string or null"

let decode_container ~sanitize index json =
  let open Result.Syntax in
  let prefix = Printf.sprintf "sandbox_live.containers[%d]." index in
  let* fields = assoc (prefix ^ "row") json in
  let required name =
    match field name fields with
    | Some (`String value) -> Ok (sanitize value)
    | Some _ -> Error (prefix ^ name ^ " must be a string")
    | None -> Error (prefix ^ name ^ " is required")
  in
  let* name = required "name" in
  let* id = required "id" in
  let* image = required "image" in
  let* status = required "status" in
  let* running = bool_opt ~key:"running" ~path:(prefix ^ "running") fields in
  let* created_at =
    string_opt ~sanitize ~key:"created_at" ~path:(prefix ^ "created_at") fields
  in
  let* owner_pid =
    int_opt ~key:"owner_pid" ~path:(prefix ^ "owner_pid") fields
  in
  let* cpus = int_opt ~key:"cpus" ~path:(prefix ^ "cpus") fields in
  let* memory_bytes =
    int_opt ~key:"memory_bytes" ~path:(prefix ^ "memory_bytes") fields
  in
  let* hostname = string_opt ~sanitize ~key:"hostname" ~path:(prefix ^ "hostname") fields in
  let* ipv4_address =
    string_opt ~sanitize ~key:"ipv4_address" ~path:(prefix ^ "ipv4_address") fields
  in
  let* ipv6_address =
    string_opt ~sanitize ~key:"ipv6_address" ~path:(prefix ^ "ipv6_address") fields
  in
  let* gateway = string_opt ~sanitize ~key:"gateway" ~path:(prefix ^ "gateway") fields in
  Ok
    { name
    ; id
    ; image
    ; status
    ; running
    ; created_at
    ; owner_pid
    ; cpus
    ; memory_bytes
    ; hostname
    ; ipv4_address
    ; ipv6_address
    ; gateway
    }

let decode_containers ~sanitize fields =
  match field "containers" fields with
  | None | Some `Null -> Ok None
  | Some (`List rows) ->
    let decoded = List.mapi (decode_container ~sanitize) rows in
    List.fold_right
      (fun row result ->
        match row, result with
        | Ok row, Ok rows -> Ok (row :: rows)
        | Error detail, _ | _, Error detail -> Error detail)
      decoded
      (Ok [])
    |> Result.map Option.some
  | Some _ -> Error "sandbox_live.containers must be a list or null"

let decode_optional_object ~path decode fields =
  match field path fields with
  | None | Some `Null -> Ok None
  | Some (`Assoc inner) -> Result.map Option.some (decode inner)
  | Some _ -> Error ("sandbox_live." ^ path ^ " must be an object or null")
;;

let decode_discard_default ~sanitize fields =
  let path = "resource_config.work_volume_discard_default" in
  let matches = List.filter (fun (key, _) -> key = "work_volume_discard_default") fields in
  match matches with
  | [] -> Error (path ^ " is required")
  | [_key, `Null] -> Ok None
  | [_key, `Assoc observation] ->
    let keys = List.map fst observation in
    let sorted = List.sort String.compare keys in
    if List.length sorted <> List.length (List.sort_uniq String.compare sorted) then
      Error (path ^ " has duplicate keys")
    else if List.exists (fun key -> key <> "state" && key <> "error") keys then
      Error (path ^ " has unknown keys")
    else if sorted <> ["error"; "state"] then
      Error (path ^ " requires state and error")
    else
      (match field "state" observation, field "error" observation with
       | Some (`String "set"), Some `Null -> Ok (Some Discard_set)
       | Some (`String "absent"), Some `Null -> Ok (Some Discard_absent)
       | Some (`String "unreadable"), Some (`String detail) when String.trim detail <> "" ->
         Ok (Some (Discard_unreadable (sanitize detail)))
       | Some (`String ("set" | "absent" | "unreadable")), Some _ ->
         Error (path ^ " has contradictory state and error")
       | Some (`String state), Some _ -> Error (path ^ " has unsupported state " ^ sanitize state)
       | Some _, Some _ -> Error (path ^ ".state must be a string")
       | None, _ | _, None -> Error (path ^ " requires state and error"))
  | [_key, _] -> Error (path ^ " must be an object or null")
  | _ :: _ :: _ -> Error (path ^ " is duplicated")
;;

let decode_resource_config ~sanitize fields =
  let open Result.Syntax in
  let* () =
    match List.filter (fun (key, _) -> key = "resource_config") fields with
    | [] | [_] -> Ok ()
    | _ :: _ :: _ -> Error "sandbox_live.resource_config is duplicated"
  in
  decode_optional_object ~path:"resource_config"
    (fun inner ->
      let* memory = string_opt ~sanitize ~key:"memory" ~path:"resource_config.memory" inner in
      let* cpus = string_opt ~sanitize ~key:"cpus" ~path:"resource_config.cpus" inner in
      let* guest_size_error =
        string_opt ~sanitize ~key:"guest_size_error"
          ~path:"resource_config.guest_size_error" inner
      in
      let* guest_size_issue =
        match List.filter (fun (key, _) -> String.equal key "guest_size_error_code") inner,
              guest_size_error with
        | ([] | [_, `Null]), None -> Ok None
        | ([] | [_, `Null]), Some _ -> Ok (Some Guest_size_unclassified)
        | [_, `String "guest_size_unresolved"], Some _ -> Ok (Some Guest_size_unresolved)
        | [_, `String _], Some _ -> Ok (Some Guest_size_unclassified)
        | [_, `String _], None | [_], _ | _ :: _ :: _, _ ->
          Error "resource_config.guest_size_error_code is invalid or contradicts its diagnostic" in
      let* work_volume_size =
        string_opt ~sanitize ~key:"work_volume_size" ~path:"resource_config.work_volume_size" inner
      in
      let* pids_limit = int_opt ~key:"pids_limit" ~path:"resource_config.pids_limit" inner in
      let* tmpfs_size = string_opt ~sanitize ~key:"tmpfs_size" ~path:"resource_config.tmpfs_size" inner in
      let* work_volume_discard_default = decode_discard_default ~sanitize inner in
      Ok { memory; cpus; guest_size_error; guest_size_issue; work_volume_size; work_volume_discard_default; pids_limit; tmpfs_size })
    fields
;;

let decode_paths ~sanitize fields =
  let open Result.Syntax in
  decode_optional_object ~path:"paths"
    (fun inner ->
      let get name = string_opt ~sanitize ~key:name ~path:("paths." ^ name) inner in
      let* host_workspace = get "host_workspace" in
      let* guest_home = get "guest_home" in
      let* guest_workspace = get "guest_workspace" in
      let* guest_config = get "guest_config" in
      let* guest_work_volume = get "guest_work_volume" in
      Ok
        { host_workspace
        ; guest_home
        ; guest_workspace
        ; guest_config
        ; guest_work_volume
        })
    fields
;;

let decode_kata_name_observation fields =
  match List.filter (fun (key, _) -> String.equal key "kata_name_observation") fields with
  | [] -> Ok (None, None)
  | [_, `Assoc observed] ->
    let keys = List.map fst observed |> List.sort String.compare in
    if keys <> ["scoped_name_seen"; "state"] then
      Error "sandbox_live.kata_name_observation requires state and scoped_name_seen"
    else
      let open Result.Syntax in
      let* state = match List.assoc_opt "state" observed with
        | Some (`String "not_applicable") -> Ok Kata_not_applicable
        | Some (`String "absent") -> Ok Kata_name_absent
        | Some (`String "expected_runtime") -> Ok Kata_name_expected_runtime
        | Some (`String "other_runtime") -> Ok Kata_name_other_runtime
        | Some (`String "runtime_unreported") -> Ok Kata_name_runtime_unreported
        | Some (`String "unavailable") -> Ok Kata_name_unavailable
        | Some _ | None -> Error "sandbox_live.kata_name_observation has an unsupported state" in
      let* scoped = match List.assoc_opt "scoped_name_seen" observed with
        | Some `Null -> Ok None
        | Some (`Bool value) -> Ok (Some value)
        | Some _ | None -> Error "sandbox_live.kata_name_observation scoped_name_seen must be boolean or null" in
      (match state, scoped with
       | Kata_not_applicable, Some _ -> Error "inapplicable Kata observation has a scoped name"
       | (Kata_name_absent | Kata_name_expected_runtime | Kata_name_other_runtime
         | Kata_name_runtime_unreported | Kata_name_unavailable | Kata_not_applicable), _ ->
         Ok (Some state, scoped))
  | [_] -> Error "sandbox_live.kata_name_observation must be an object"
  | _ :: _ :: _ -> Error "sandbox_live.kata_name_observation is duplicated"
;;

let decode_host_alignment = function
  | `Null -> Ok None
  | `String "selectors_match" -> Ok (Some Host_selectors_match)
  | `String "selectors_differ" -> Ok (Some Host_selectors_differ)
  | `String "selectors_unavailable" -> Ok (Some Host_selectors_unavailable)
  | _ -> Error "Kata host environment alignment is invalid"
;;

let decode_name ~sanitize ~keeper_name json =
  let open Result.Syntax in
  let* fields = assoc "Kata name observation" json in
  let keys = List.map fst fields |> List.sort String.compare in
  if keys <> ["expected_name"; "host_environment_alignment"; "keeper"; "network_mode"; "state"] then
    Error "Kata name observation has invalid fields"
  else
    let* () = match List.assoc_opt "keeper" fields with
      | Some (`String keeper) when String.equal keeper keeper_name -> Ok ()
      | Some _ | None -> Error "Kata name observation has a different Keeper" in
    let* state, _ = decode_kata_name_observation
        ["kata_name_observation", `Assoc [
          "state", Option.value ~default:`Null (List.assoc_opt "state" fields);
          "scoped_name_seen", `Null]] in
    let* state = match state with Some value -> Ok value | None -> Error "Kata name state is missing" in
    let* expected_name = match List.assoc_opt "expected_name" fields with
      | Some `Null -> Ok None
      | Some (`String value) when String.trim value <> "" -> Ok (Some (sanitize value))
      | Some _ | None -> Error "Kata expected name is invalid" in
    let* network_mode = match List.assoc_opt "network_mode" fields with
      | Some (`String value) when String.trim value <> "" -> Ok (sanitize value)
      | Some _ | None -> Error "Kata observed network mode is invalid" in
    let* host_alignment = decode_host_alignment
        (Option.value ~default:`Null (List.assoc_opt "host_environment_alignment" fields)) in
    let consistent = match state with
      | Kata_not_applicable -> Option.is_none expected_name && Option.is_none host_alignment
      | Kata_name_unavailable -> Option.is_some expected_name && Option.is_some host_alignment
      | Kata_name_absent | Kata_name_expected_runtime | Kata_name_other_runtime
      | Kata_name_runtime_unreported ->
        Option.is_some expected_name && host_alignment = Some Host_selectors_match in
    if consistent then Ok {name_state = state; expected_name; network_mode; host_alignment}
    else Error "Kata name state contradicts its context or expected name"
;;

let decode ~sanitize json =
  let open Result.Syntax in
  let* root = assoc "keeper status" json in
  let* keeper_last_error =
    string_opt ~sanitize ~path:"keeper_last_error" root
  in
  let* live =
    match field "sandbox_live" root with
    | Some (`Assoc fields) -> Ok fields
    | Some `Null | None -> Error "keeper status has no sandbox_live observation"
    | Some _ -> Error "sandbox_live must be an object"
  in
  let* sandbox_profile = profile_opt ~sanitize live in
  let* configured_network_mode =
    string_opt ~sanitize ~path:"configured_network_mode" live
  in
  let* configured_image_name =
    string_opt ~sanitize ~path:"configured_image_name" live
  in
  let* configured_image = string_opt ~sanitize ~path:"configured_image" live in
  let* configured_image_unresolved =
    string_opt ~sanitize ~path:"configured_image_unresolved" live
  in
  let* configured_image_issue =
    match List.filter (fun (key, _) -> String.equal key "configured_image_unresolved_code") live,
          configured_image_unresolved with
    | ([] | [_, `Null]), None -> Ok None
    | ([] | [_, `Null]), Some _ -> Ok (Some Image_issue_unclassified)
    | [_, `String code], Some _ ->
      let issue = match code with
        | "not_declared" -> Image_not_declared
        | "catalog_unreadable" -> Image_catalog_unreadable
        | "unknown_image" -> Image_unknown_name
        | "not_promoted" -> Image_not_promoted
        | "no_image_store" -> Image_no_store
        | _ -> Image_issue_unclassified in
      Ok (Some issue)
    | [_, `String _], None | [_], _ | _ :: _ :: _, _ ->
      Error "configured_image_unresolved_code is invalid or contradicts its diagnostic" in
  let* containers = decode_containers ~sanitize live in
  let* container_error =
    string_opt ~sanitize ~path:"container_error" live
  in
  let* container_error_code =
    match List.filter (fun (key, _) -> String.equal key "container_error_code") live,
          container_error with
    | ([] | [_, `Null]), _ -> Ok None
    | [_, `String "kata_execution_context_unavailable"], Some _ -> Ok (Some Context_unavailable)
    | [_, `String "microvm_backend_unresolved"], Some _ -> Ok (Some Backend_unresolved)
    | [_, `String _], Some _ -> Ok (Some Other_inventory_error)
    | [_, `String _], None | [_], _ | _ :: _ :: _, _ ->
      Error "container_error_code is invalid or contradicts its diagnostic" in
  let* kata_name_observation, kata_scoped_name_seen = decode_kata_name_observation live in
  let* kata_host_alignment = match List.filter
      (fun (key, _) -> String.equal key "kata_host_environment_alignment") live with
    | [] -> Ok None
    | [_, value] -> decode_host_alignment value
    | _ :: _ :: _ -> Error "Kata host environment alignment is duplicated" in
  let* resource_config = decode_resource_config ~sanitize live in
  let* paths = decode_paths ~sanitize live in
  Ok
    { sandbox_profile
    ; configured_network_mode
    ; configured_image_name
    ; configured_image
    ; configured_image_unresolved
    ; configured_image_issue
    ; containers
    ; container_error
    ; container_error_code
    ; kata_name_observation
    ; kata_scoped_name_seen
    ; kata_host_alignment
    ; resource_config
    ; paths
    ; keeper_last_error
    }

let decode_for_keeper ~sanitize ~keeper_name json =
  let open Result.Syntax in
  let* fields = assoc "keeper status" json in
  let exactly_named name fields =
    match List.filter (fun (key, _) -> String.equal key name) fields with
    | [_, `String value] when String.equal value keeper_name -> Ok ()
    | _ -> Error (name ^ " does not identify the requested Keeper") in
  let* () = exactly_named "name" fields in
  let* live = match List.filter (fun (key, _) -> String.equal key "sandbox_live") fields with
    | [_, `Assoc live] -> Ok live
    | _ -> Error "sandbox_live is missing or duplicated" in
  let* () = exactly_named "keeper" live in
  decode ~sanitize json
;;

let styled code text =
  if String.equal code "" then text else code ^ text ^ Masc_tui_theme.Sgr.reset

let text ~ko korean english = if ko then korean else english
let value ~ko = Option.value ~default:(text ~ko "미보고" "not reported")

let status_code = function
  | `Ok -> Masc_tui_theme.status Masc_tui_theme.Ok
  | `Warn -> Masc_tui_theme.status Masc_tui_theme.Warn
  | `Bad -> Masc_tui_theme.status Masc_tui_theme.Bad
  | `Info -> Masc_tui_theme.status Masc_tui_theme.Info
  | `Muted -> Masc_tui_theme.status Masc_tui_theme.Muted

let row_geometry ~width ~label =
  let label_cells = Masc_tui_message_layout.display_width label in
  let prefix_cells = 2 + max 14 label_cells + 1 in
  prefix_cells, max 1 (width - prefix_cells)

let wrapped_rows ~width ~label ~tone text =
  let label_cells = Masc_tui_message_layout.display_width label in
  let prefix_cells, body_width = row_geometry ~width ~label in
  let prefix = "  " ^ label ^ String.make (max 0 (14 - label_cells)) ' ' ^ " " in
  let continuation = String.make prefix_cells ' ' in
  match Masc_tui_message_layout.wrap_words ~max_cells:body_width text with
  | [] -> [ prefix ]
  | first :: rest ->
    (prefix ^ styled (status_code tone) first)
    :: List.map (fun line -> continuation ^ styled (status_code tone) line) rest

let inventory_error_rows ~ko ~width ~label ~tone reading detail =
  let summary = match ko, reading.container_error_code with
    | true, Some Context_unavailable -> Some "샌드박스 실행 환경을 확인할 수 없습니다."
    | true, Some Backend_unresolved -> Some "microVM 런타임이 설정되지 않았습니다."
    | true, (Some Other_inventory_error | None) -> Some "인스턴스 목록을 확인하지 못했습니다."
    | false, _ -> None in
  match summary with
  | None -> wrapped_rows ~width ~label ~tone detail
  | Some summary ->
    wrapped_rows ~width ~label ~tone summary
    @ wrapped_rows ~width ~label:"상세 원문" ~tone:`Muted detail

let bytes_text bytes =
  let gib = 1024. *. 1024. *. 1024. in
  if Float.of_int bytes >= gib then
    Printf.sprintf "%.1f GiB" (Float.of_int bytes /. gib)
  else
    Printf.sprintf "%.1f MiB" (Float.of_int bytes /. (1024. *. 1024.))

let joined_opt parts =
  match List.filter_map Fun.id parts with
  | [] -> None
  | rows -> Some (String.concat " · " rows)

(* The profile, not the runtime under it: this wire carries which sandbox a
   Keeper declared and not which microVM CLI serves it. Naming Apple here
   labelled every msb and nerdctl Keeper with a runtime it does not use. The
   runtime appears in the logs section, which does carry it. *)
let profile_label ~ko = function
  | Some Docker -> "Docker"
  | Some Micro_vm -> text ~ko "microVM 게스트" "microVM guest"
  | Some Remote_ssh -> "Remote SSH"
  | None -> text ~ko "미보고" "not reported"

let legacy_status_lines ~ko ~width reading =
  let tr = text ~ko in
  let header = [ " " ^ styled Masc_tui_theme.Sgr.bold (tr "1. 샌드박스 상태" "1. Sandbox status") ] in
  match reading.container_error, reading.containers with
  | Some detail, Some (_ :: _ as containers) ->
    header
    @ [ "  " ^ styled (status_code `Warn) (tr "● 일부 조회 실패" "● PARTIAL INSPECTION") ]
    @ wrapped_rows ~width ~label:(tr "인스턴스" "Instances") ~tone:`Warn
        (if ko then Printf.sprintf "%d개 관측 · 일부 조회 실패" (List.length containers)
         else Printf.sprintf "%d observed · inspection incomplete" (List.length containers))
    @ inventory_error_rows ~ko ~width ~label:(tr "조회 오류" "Inspection error") ~tone:`Bad reading detail
  | Some detail, _ ->
    header
    @ [ "  " ^ styled (status_code `Bad) (tr "● 조회 실패" "● INSPECTION FAILED") ]
    @ inventory_error_rows ~ko ~width ~label:(tr "조회 오류" "Inspection error") ~tone:`Bad reading detail
  | None, None ->
    header
    @ [ "  " ^ styled (status_code `Warn) (tr "? 상태 미확인" "? UNKNOWN") ]
    @ wrapped_rows ~width ~label:(tr "목록" "Inventory") ~tone:`Warn
        (tr "인스턴스 목록이 보고되지 않았습니다." "Instance inventory was not reported.")
  | None, Some containers ->
    let running =
      List.fold_left
        (fun count container ->
          count + if container.running = Some true then 1 else 0)
        0
        containers
    in
    let unknown = List.fold_left (fun count container ->
      count + if container.running = None then 1 else 0) 0 containers in
    if unknown > 0 then
      header
      @ [ "  " ^ styled (status_code `Warn) (tr "? 상태 일부 미확인" "? STATE INCOMPLETE") ]
      @ wrapped_rows ~width ~label:(tr "인스턴스" "Instances") ~tone:`Warn
          (if ko then Printf.sprintf "실행 %d · 미확인 %d · 전체 %d" running unknown (List.length containers)
           else Printf.sprintf "%d running · %d unknown · %d total" running unknown (List.length containers))
    else if running > 0 then
      header
      @ [ "  " ^ styled (status_code `Ok) (tr "● 실행 중" "● RUNNING") ]
      @ wrapped_rows ~width ~label:(tr "인스턴스" "Instances") ~tone:`Ok
          (if ko then Printf.sprintf "실행 %d · 전체 %d" running (List.length containers)
           else Printf.sprintf "%d running · %d total" running (List.length containers))
    else
      match containers with
      | _ :: _ ->
        header
        @ [ "  " ^ styled (status_code `Warn) (tr "● 중지됨" "● STOPPED") ]
        @ wrapped_rows ~width ~label:(tr "인스턴스" "Instances") ~tone:`Warn
            (if ko then Printf.sprintf "%d개 존재 · 실행 0" (List.length containers)
             else Printf.sprintf "%d present · 0 running" (List.length containers))
      | [] ->
        match reading.sandbox_profile with
        | Some Micro_vm ->
          header
          @ [ "  " ^ styled (status_code `Info) (tr "○ 시작 전" "○ NOT STARTED") ]
          @ wrapped_rows ~width ~label:(tr "다음" "Next") ~tone:`Info
              (tr "첫 샌드박스 명령에서 이 Keeper의 VM을 만듭니다."
                 "The first sandbox command creates this Keeper's VM.")
        | Some Docker ->
          header
          @ [ "  " ^ styled (status_code `Info) (tr "○ 대기 중" "○ IDLE") ]
          @ wrapped_rows ~width ~label:(tr "다음" "Next") ~tone:`Info
              (tr "샌드박스 명령을 실행하면 컨테이너가 시작됩니다."
                 "A container starts when a sandbox command runs.")
        | Some Remote_ssh ->
          header
          @ [ "  " ^ styled (status_code `Ok) (tr "● 원격" "● REMOTE") ]
          @ wrapped_rows ~width ~label:(tr "실행" "Execution") ~tone:`Info
              (tr "설정된 SSH 엔드포인트에서 명령을 실행합니다."
                 "Commands run on this Keeper's configured SSH endpoint.")
        | None ->
          header
          @ [ "  " ^ styled (status_code `Warn) (tr "○ 인스턴스 없음" "○ NO LIVE INSTANCE") ]

let status_lines ~ko ~width reading =
  let text korean english = if ko then korean else english in
  let header = [ " " ^ styled Masc_tui_theme.Sgr.bold
      (text "1. 샌드박스 상태" "1. Sandbox status") ] in
  let name_row tone title detail =
    header
    @ [ "  " ^ styled (status_code tone) title ]
    @ wrapped_rows ~width ~label:(text "이름" "Name") ~tone detail
  in
  let separate_readings =
    wrapped_rows ~width ~label:(text "관측" "Observation") ~tone:`Info
      (text "인스턴스 목록과 별도 시점 · 소유권 미확인"
         "Separate from the instance listing; ownership unverified.") in
  let inventory_error = match reading.container_error with
    | None -> []
    | Some detail -> inventory_error_rows ~ko ~width ~label:(text "목록 오류" "Inventory error")
        ~tone:`Bad reading detail in
  match kata_status_decision reading with
  | Kata_inapplicable -> legacy_status_lines ~ko ~width reading
  | Kata_not_observed ->
    (match reading.sandbox_profile with
     | Some Micro_vm ->
       name_row `Warn (text "? 이름 미조회" "? NAME NOT OBSERVED")
         (text "이름 점유 여부를 확인하지 못했습니다." "Name occupancy was not observed.")
       @ inventory_error
     | Some (Docker | Remote_ssh) | None -> legacy_status_lines ~ko ~width reading)
  | Kata_scoped_name_seen ->
    name_row `Warn (text "? 동일 인스턴스 미확인" "? INSTANCE MATCH UNCONFIRMED")
      (text "두 조회에서 같은 이름이 보였지만 동일 인스턴스인지 확인되지 않았습니다."
         "Both readings reported the name; they may describe different instances.")
    @ separate_readings @ inventory_error
  | Kata_unscoped_expected_runtime ->
    name_row `Warn (text "● 이름 사용 중" "● NAME PRESENT")
      (text "예상 런타임이 보고됐지만 소유권은 확인되지 않았습니다."
         "The expected runtime was reported; ownership is unverified.")
    @ separate_readings @ inventory_error
  | Kata_other_runtime ->
    name_row `Warn (text "● 이름 사용 중" "● NAME PRESENT")
      (text "같은 이름에 다른 런타임이 보고됐습니다. 소유권은 확인되지 않았습니다."
         "Another runtime was reported for this name; ownership is unverified.")
    @ separate_readings @ inventory_error
  | Kata_unreported_runtime ->
    name_row `Warn (text "● 이름 사용 중" "● NAME PRESENT")
      (text "같은 이름이 있지만 런타임과 소유권은 확인되지 않았습니다."
         "The name is present, but runtime and ownership are unverified.")
    @ separate_readings @ inventory_error
  | Kata_absent ->
    name_row `Info (text "○ 이름 없음" "○ NAME NOT SEEN")
      (text "조회 시점의 런타임 목록에 이 이름이 없었습니다."
         "The name was not in the runtime listing at observation time.")
    @ (match reading.kata_scoped_name_seen with
       | Some true -> wrapped_rows ~width ~label:(text "목록" "Inventory") ~tone:`Warn
           (text "별도 인스턴스 목록에는 같은 이름이 있었습니다."
              "The separate instance listing contained this name.")
       | Some false | None -> [])
    @ separate_readings @ inventory_error
  | Kata_unavailable ->
    name_row `Warn (text "? 이름 조회 실패" "? NAME LOOKUP FAILED")
      (text "런타임 목록에서 이름 점유 여부를 확인하지 못했습니다."
         "Name occupancy could not be determined from the runtime listing.")
    @ separate_readings @ inventory_error
;;

let container_lines ~ko ~width reading =
  let tr = text ~ko in
  let separate = match reading.sandbox_profile, reading.kata_name_observation with
    | Some Micro_vm, (Some Kata_not_applicable) -> false
    | Some Micro_vm, (Some (Kata_name_absent | Kata_name_expected_runtime
                           | Kata_name_other_runtime | Kata_name_runtime_unreported
                           | Kata_name_unavailable) | None) -> true
    | (Some (Docker | Remote_ssh) | None), _ -> false in
  match reading.containers with
  | None | Some [] -> []
  | Some containers ->
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold
        (if separate then tr "3. 별도 인스턴스 관측" "3. Separate instance observations"
         else tr "3. 인스턴스" "3. Instances") ]
    @ (containers
      |> List.concat_map (fun container ->
      let tone = if not separate && container.running = Some true then `Ok else `Warn in
      let state =
        match container.running with
        | Some true -> tr "실행 관측" "observed running"
        | Some false -> tr "중지 관측" "observed stopped"
        | None -> tr "상태 미확인" "state unknown"
      in
      let compute =
        joined_opt
          [ Option.map (fun value -> Printf.sprintf "%d CPU" value) container.cpus
          ; Option.map (fun value -> bytes_text value ^ " RAM") container.memory_bytes
          ]
      in
      let network =
        joined_opt
          [ Option.map (fun value -> tr "호스트 " "host " ^ value) container.hostname
          ; Option.map (fun value -> "IPv4 " ^ value) container.ipv4_address
          ; Option.map (fun value -> tr "게이트웨이 " "gateway " ^ value) container.gateway
          ; Option.map (fun value -> "IPv6 " ^ value) container.ipv6_address
          ]
      in
      (* Keep the typed inspection and the runtime's display prose separate. *)
      wrapped_rows ~width ~label:(tr "관측 상태" "Observed state") ~tone
        state
      @ wrapped_rows ~width ~label:(tr "런타임 원문" "Runtime status") ~tone:`Muted container.status
      @ wrapped_rows ~width ~label:(tr "이름" "Name") ~tone:`Muted container.name
      @ (match compute with
         | None -> []
         | Some compute -> wrapped_rows ~width ~label:(tr "컴퓨팅" "Compute") ~tone:`Info compute)
      @ (match network with
         | None -> []
         | Some network -> wrapped_rows ~width ~label:(tr "네트워크" "Network") ~tone:`Info network)
      @ wrapped_rows ~width ~label:(tr "이미지" "Image") ~tone:`Muted container.image
      @ (match container.created_at with
         | None -> []
         | Some created -> wrapped_rows ~width ~label:(tr "생성 시각" "Created") ~tone:`Muted created)
      @ wrapped_rows ~width ~label:(tr "인스턴스 ID" "Instance ID") ~tone:`Muted container.id
      @ (match container.owner_pid with
         | None -> []
         | Some pid ->
           wrapped_rows ~width ~label:(tr "소유 PID" "Owner PID") ~tone:`Muted (string_of_int pid))))

let resource_rows ~ko ~width = function
  | None -> []
  | Some resources ->
    let compute =
      [ Option.map (fun value -> text ~ko "메모리 " "memory " ^ value) resources.memory
      ; Some ("CPU " ^ value ~ko resources.cpus)
      ; Option.map (fun value -> Printf.sprintf "pids %d" value) resources.pids_limit
      ; Option.map (fun value -> "tmpfs " ^ value) resources.tmpfs_size
      ]
      |> joined_opt
    in
    let storage =
      [ Option.map (fun size -> text ~ko "작업 " "work " ^ size) resources.work_volume_size ]
      |> joined_opt
    in
    (match compute with
     | None -> []
     | Some compute -> wrapped_rows ~width ~label:(text ~ko "제한" "Limits") ~tone:`Info compute)
    @ (match resources.guest_size_error with
       | None -> []
     | Some detail when ko ->
       let summary = match resources.guest_size_issue with
         | Some Guest_size_unresolved -> "게스트 CPU·메모리 크기를 결정하지 못했습니다."
         | Some Guest_size_unclassified | None -> "게스트 크기를 확인하지 못했습니다." in
       wrapped_rows ~width ~label:"게스트 크기" ~tone:`Bad summary
       @ wrapped_rows ~width ~label:"상세 원문" ~tone:`Muted detail
     | Some detail -> wrapped_rows ~width ~label:"Guest size" ~tone:`Bad detail)
    @ (match storage with
       | None -> []
     | Some storage -> wrapped_rows ~width ~label:(text ~ko "볼륨 한도" "Volume caps") ~tone:`Muted storage)
    @ (match resources.work_volume_discard_default with
       | None -> []
       | Some Discard_set -> wrapped_rows ~width ~label:(text ~ko "작업 discard" "Work discard") ~tone:`Ok (text ~ko "설정됨" "set")
       | Some Discard_absent -> wrapped_rows ~width ~label:(text ~ko "작업 discard" "Work discard") ~tone:`Warn (text ~ko "없음" "absent")
       | Some (Discard_unreadable detail) ->
         wrapped_rows ~width ~label:(text ~ko "작업 discard" "Work discard") ~tone:`Warn
           (text ~ko "읽지 못함: " "unreadable: " ^ detail))

(* A Keeper names an image and the host catalog says which build that name
   is now. The row shows the name and the build, or, when the catalog cannot
   answer, the reason, which is what stops the Keeper's next container. *)
let image_rows ~ko ~width reading =
  let named tag =
    match reading.configured_image_name with
    | Some name -> name ^ " \xc2\xb7 " ^ tag
    | None -> tag
  in
  match reading.configured_image, reading.configured_image_unresolved with
  | Some tag, _ -> wrapped_rows ~width ~label:(text ~ko "이미지" "Image") ~tone:`Info (named tag)
  | None, Some reason when ko ->
    let summary = match reading.configured_image_issue with
      | Some Image_not_declared -> "이미지 이름이 설정되지 않았습니다."
      | Some Image_catalog_unreadable -> "이미지 목록을 읽지 못했습니다."
      | Some Image_unknown_name -> "설정한 이미지 이름이 목록에 없습니다."
      | Some Image_not_promoted -> "이 저장소에 등록된 이미지 빌드가 없습니다."
      | Some Image_no_store -> "이 Keeper의 이미지 저장소를 확인할 수 없습니다."
      | Some Image_issue_unclassified | None -> "이미지 구성을 확인하지 못했습니다." in
    wrapped_rows ~width ~label:"이미지" ~tone:`Bad summary
    @ wrapped_rows ~width ~label:"상세 원문" ~tone:`Muted reason
  | None, Some reason -> wrapped_rows ~width ~label:"Image" ~tone:`Bad reason
  | None, None -> []

let configured_lines ~ko ~width reading =
  [ ""; " " ^ styled Masc_tui_theme.Sgr.bold (text ~ko "2. 구성 · 이미지와 리소스" "2. Configuration · image and resources") ]
  @ wrapped_rows ~width ~label:(text ~ko "방식" "Backend") ~tone:`Info
      (profile_label ~ko reading.sandbox_profile)
  @ image_rows ~ko ~width reading
  @ wrapped_rows ~width ~label:(text ~ko "네트워크" "Network") ~tone:`Info
      (value ~ko reading.configured_network_mode)
  @ resource_rows ~ko ~width reading.resource_config

let path_lines ~ko ~width = function
  | None -> []
  | Some paths ->
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold (text ~ko "4. 파일시스템 마운트" "4. Filesystem mounts") ]
    @ wrapped_rows ~width ~label:(text ~ko "작업공간" "Workspace") ~tone:`Info
        (value ~ko paths.guest_workspace)
    @ wrapped_rows ~width ~label:"HOME" ~tone:`Muted
        (Option.value paths.guest_home ~default:(text ~ko "확인 불가" "unavailable"))
    @ wrapped_rows ~width ~label:(text ~ko "설정" "Config") ~tone:`Muted (value ~ko paths.guest_config)
    @ wrapped_rows ~width ~label:(text ~ko "호스트 번들" "Host bundle") ~tone:`Muted
        (value ~ko paths.host_workspace)
    @ (match paths.guest_work_volume with
       | None -> []
       | Some path -> wrapped_rows ~width ~label:(text ~ko "작업 볼륨" "Work volume") ~tone:`Muted path)

let detail_sections ~ko ~width reading =
  configured_lines ~ko ~width reading
  @ container_lines ~ko ~width reading
  @ path_lines ~ko ~width reading.paths
  @ (match reading.keeper_last_error with
     | None -> []
     | Some detail ->
       [ ""; " " ^ styled Masc_tui_theme.Sgr.bold (text ~ko "5. 진단 오류" "5. Diagnostics") ]
       @ wrapped_rows ~width ~label:(text ~ko "Keeper 오류" "Keeper error") ~tone:`Bad detail)
  @ [ ""; " " ^ styled Masc_tui_theme.Sgr.bold (text ~ko "6. 연관 화면" "6. Related") ]
  @ wrapped_rows ~width ~label:(text ~ko "컨테이너 출력" "Container output") ~tone:`Info
      (text ~ko "o  실제 로그" "o  actual logs")
  @ wrapped_rows ~width ~label:(text ~ko "샌드박스 호출" "Sandbox calls") ~tone:`Info
      (text ~ko "t  도구 호출" "t  tool calls")

let view_lines ?(ko = false) ~width reading =
  status_lines ~ko ~width reading @ detail_sections ~ko ~width reading

(* These replies can arrive in either order. Do not join names or infer that
   they refer to the same guest: each section reports only its own lookup. *)
let partial_view_lines ~sanitize ~ko ~width partial =
  let tr = text ~ko in
  let request_failure_rows ~label ~summary detail =
    let detail = sanitize detail in
    if ko then
      wrapped_rows ~width ~label ~tone:`Warn summary
      @ wrapped_rows ~width ~label:"상세 원문" ~tone:`Muted detail
    else wrapped_rows ~width ~label ~tone:`Warn detail in
  let context_rows = function
    | None -> []
    | Some alignment ->
      let detail = match alignment with
        | Host_selectors_match -> tr
            "턴 실행 환경 기준 · 호스트 선택 변수 일치, 대상은 미검증"
            "Turn execution context; host selectors match, target unverified"
        | Host_selectors_differ -> tr
            "턴 실행과 호스트 이미지·볼륨 조회의 선택 환경이 다름"
            "Turn and host image/volume CLI selectors differ"
        | Host_selectors_unavailable -> tr
            "턴 실행과 호스트 조회 환경 비교 불가"
            "Turn and host CLI environment comparison unavailable" in
      wrapped_rows ~width ~label:(tr "조회 환경" "CLI context") ~tone:`Warn detail in
  let name_lines =
    match partial.name with
    | None ->
      [ " " ^ styled Masc_tui_theme.Sgr.bold (tr "1. Kata 이름 관측" "1. Kata name observation") ]
      @ wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Info
          (tr "조회 중" "Loading")
    | Some (Error detail) ->
      [ " " ^ styled Masc_tui_theme.Sgr.bold (tr "1. Kata 이름 관측" "1. Kata name observation") ]
      @ request_failure_rows ~label:(tr "조회 실패" "Lookup failed")
          ~summary:"이름 조회를 완료하지 못했습니다." detail
    | Some (Ok report) when report.name_state = Kata_not_applicable
                            && Option.is_none report.expected_name
                            && Option.is_none report.host_alignment ->
      [ " " ^ styled Masc_tui_theme.Sgr.bold (tr "1. Kata 이름 관측" "1. Kata name observation") ]
      @ wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Info
          (tr "이 조회 시점에는 해당 없음" "Not applicable at this observation")
      @ wrapped_rows ~width ~label:(tr "조회 네트워크" "Observed network") ~tone:`Muted report.network_mode
    | Some (Ok report) ->
      let reading =
        { sandbox_profile = Some Micro_vm; configured_network_mode = None
        ; configured_image_name = None; configured_image = None
        ; configured_image_unresolved = None; configured_image_issue = None
        ; containers = None; container_error = None; container_error_code = None
        ; kata_name_observation = Some report.name_state; kata_scoped_name_seen = None
        ; kata_host_alignment = report.host_alignment
        ; resource_config = None; paths = None; keeper_last_error = None } in
      status_lines ~ko ~width reading
      @ context_rows report.host_alignment
      @ wrapped_rows ~width ~label:(tr "조회 네트워크" "Observed network") ~tone:`Muted report.network_mode
      @ (match report.expected_name with
         | None -> []
         | Some name -> wrapped_rows ~width ~label:(tr "조회 이름" "Queried name") ~tone:`Muted name)
  in
  let inventory_header = [ ""; " " ^ styled Masc_tui_theme.Sgr.bold
      (tr "인스턴스 목록 관측" "Instance inventory observation") ] in
  let inventory_lines = match partial.inventory with
    | None -> inventory_header @ wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Info
        (tr "조회 중" "Loading")
    | Some (Error detail) -> inventory_header
      @ request_failure_rows ~label:(tr "조회 실패" "Lookup failed")
          ~summary:"인스턴스 목록 조회를 완료하지 못했습니다." detail
    | Some (Ok reading) ->
      let summary = match inventory_decision reading with
        | Inventory_context_unavailable detail | Inventory_backend_unresolved detail
        | Inventory_failed detail ->
          inventory_error_rows ~ko ~width ~label:(tr "목록 오류" "Inventory error")
            ~tone:`Warn reading detail
        | Inventory_unreported -> wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Warn
            (tr "목록이 보고되지 않음" "Inventory not reported")
        | Remote_execution_unobserved -> wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Info
            (tr "로컬 인스턴스 없음 · 원격 실행 상태 미관측"
               "No local instance; remote execution state not observed")
        | Remote_inventory_inconsistent -> wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Warn
            (tr "원격 프로필과 로컬 목록이 일치하지 않음" "Remote profile and local inventory disagree")
        | Inventory_observed {total; running; unknown} ->
          let detail = if ko then Printf.sprintf "관측 %d · 실행 %d · 미확인 %d" total running unknown
            else Printf.sprintf "%d observed · %d running · %d unknown" total running unknown in
          wrapped_rows ~width ~label:(tr "목록" "Inventory") ~tone:`Info detail in
      inventory_header @ summary @ context_rows reading.kata_host_alignment
      @ detail_sections ~ko ~width { reading with kata_name_observation = None; kata_scoped_name_seen = None }
  in
  name_lines @ inventory_lines

(* The server answers the runtime's own spelling, so every runtime it can
   name has to be a value here. A strict decoder is the point -- an unknown
   string blanks the whole panel rather than guessing -- which is why a new
   microVM runtime is a change on both sides of this wire.

   This type is parallel to the server's closed sum rather than the same
   type: this library links no server code, so the compiler cannot ask. What
   asks is
   [test_the_reader_accepts_every_runtime_the_server_can_name] in
   test/test_tui_keeper_sandbox.ml, which iterates
   [Keeper_microvm_backend.valid_strings] and fails when one has no arm
   below. Adding a runtime there without adding it here fails the suite. *)
type log_backend =
  | Docker_log_backend
  | Apple_container_log_backend
  | Microsandbox_log_backend
  | Nerdctl_kata_log_backend

type log_instance =
  { log_instance_id : string
  ; log_instance_name : string
  ; log_instance_running : bool option
  ; log_stdout : string list
  ; log_stderr : string list
  ; log_error : string option
  }

(* The server's three states, each carrying only what that state owns. A
   backend with no instances and a Keeper with no local stream at all are
   different answers, and neither is an error. *)
type log_location = Local_log_stream | Remote_ssh_logs | Unknown_log_location

type log_source =
  | Local_instances of log_backend * log_instance list
  | Local_no_instance of log_backend
  | No_local_stream of log_location * string

type logs =
  { log_source : log_source
  ; log_tail : int
  ; log_kata_host_alignment : kata_host_alignment option
  }

let log_location logs = match logs.log_source with
  | Local_instances _ | Local_no_instance _ -> Local_log_stream
  | No_local_stream (location, _) -> location

let logs_kata_host_alignment logs = logs.log_kata_host_alignment

let decode_logs ~sanitize json =
  let open Result.Syntax in
  let* fields = assoc "sandbox logs" json in
  let required_string path name fields =
    match field name fields with
    | Some (`String value) -> Ok value
    | Some _ -> Error (path ^ " must be a string")
    | None -> Error (path ^ " is required")
  in
  let* log_tail =
    match field "tail" fields with
    | Some (`Int value) when value > 0 -> Ok value
    | Some _ -> Error "sandbox logs.tail must be a positive integer"
    | None -> Error "sandbox logs.tail is required"
  in
  let decode_lines = function
    | "" -> []
    | value -> String.split_on_char '\n' value |> List.map sanitize
  in
  let decode_instance index json =
    let prefix = Printf.sprintf "sandbox logs.instances[%d]" index in
    let* fields = assoc prefix json in
    let* log_instance_id = required_string (prefix ^ ".instance_id") "instance_id" fields in
    let* log_instance_name =
      required_string (prefix ^ ".instance_name") "instance_name" fields
    in
    let* log_instance_running =
      bool_opt ~key:"running" ~path:(prefix ^ ".running") fields
    in
    let* stdout = required_string (prefix ^ ".stdout") "stdout" fields in
    let* stderr = required_string (prefix ^ ".stderr") "stderr" fields in
    let* log_error =
      string_opt ~sanitize ~key:"error" ~path:(prefix ^ ".error") fields
    in
    Ok
      { log_instance_id = sanitize log_instance_id
      ; log_instance_name = sanitize log_instance_name
      ; log_instance_running
      ; log_stdout = decode_lines stdout
      ; log_stderr = decode_lines stderr
      ; log_error
      }
  in
  let* log_instances =
    match field "instances" fields with
    | Some (`List rows) ->
      (* No pipe into fold_right: [a |> List.fold_right f init] would hand [a]
         to the function's own slot. The list goes where the signature says. *)
      List.fold_right
        (fun row result ->
           match row, result with
           | Ok row, Ok rows -> Ok (row :: rows)
           | Error detail, _ | _, Error detail -> Error detail)
        (List.mapi decode_instance rows)
        (Ok [])
    | Some _ -> Error "sandbox logs.instances must be a list"
    | None -> Error "sandbox logs.instances is required"
  in
  (* A Keeper with no local stream names no backend, so the field is null
     there and a string only for the two local states. *)
  let* log_backend =
    match field "backend" fields with
    | None | Some `Null -> Ok None
    | Some (`String "docker") -> Ok (Some Docker_log_backend)
    | Some (`String "apple_container") -> Ok (Some Apple_container_log_backend)
    | Some (`String "microsandbox") -> Ok (Some Microsandbox_log_backend)
    | Some (`String "nerdctl_kata") -> Ok (Some Nerdctl_kata_log_backend)
    | Some (`String value) ->
      Error ("sandbox logs.backend has unsupported value " ^ sanitize value)
    | Some _ -> Error "sandbox logs.backend must be a string or null"
  in
  let* log_kata_host_alignment =
    match List.filter (fun (key, _) -> String.equal key "kata_host_environment_alignment") fields with
    | [] -> Ok None
    | [_, value] -> decode_host_alignment value
    | _ :: _ :: _ -> Error "sandbox logs.kata_host_environment_alignment is duplicated" in
  let* () = match log_backend, log_kata_host_alignment with
    | Some Nerdctl_kata_log_backend, _
    | (None | Some (Docker_log_backend | Apple_container_log_backend | Microsandbox_log_backend)), None -> Ok ()
    | (None | Some (Docker_log_backend | Apple_container_log_backend | Microsandbox_log_backend)), Some _ ->
      Error "sandbox logs context contradicts its backend" in
  let* state = required_string "sandbox logs.state" "state" fields in
  let* log_source =
    match state with
    | "available" ->
      (match log_backend, log_instances with
       | None, _ -> Error "sandbox logs.available requires a backend"
       | Some _, [] -> Error "sandbox logs.available requires an instance"
       | Some backend, instances -> Ok (Local_instances (backend, instances)))
    | "no_instance" ->
      (match log_backend, log_instances with
       | None, _ -> Error "sandbox logs.no_instance requires a backend"
       | Some _, _ :: _ -> Error "sandbox logs.no_instance cannot carry instances"
       | Some backend, [] -> Ok (Local_no_instance backend))
    | "no_local_stream" ->
      let* reason = required_string "sandbox logs.reason" "reason" fields in
      let* location = match List.filter (fun (key, _) -> String.equal key "reason_code") fields with
        | [] | [_, `Null] -> Ok Unknown_log_location
        | [_, `String "remote_ssh"] -> Ok Remote_ssh_logs
        | [_, `String _] -> Ok Unknown_log_location
        | [_] | _ :: _ :: _ -> Error "sandbox logs.reason_code is invalid or duplicated" in
      (match log_backend, log_instances with
       | Some _, _ -> Error "sandbox logs.no_local_stream cannot name a backend"
       | None, _ :: _ -> Error "sandbox logs.no_local_stream cannot carry instances"
       | None, [] -> Ok (No_local_stream (location, sanitize reason)))
    | value -> Error ("sandbox logs.state has unsupported value " ^ sanitize value)
  in
  Ok { log_source; log_tail; log_kata_host_alignment }
;;

let logs_view_lines ?(ko = false) ~width logs =
  let tr = text ~ko in
  let title = [ ""; " " ^ styled Masc_tui_theme.Sgr.bold (tr "7. 컨테이너 로그" "7. container logs") ] in
  let backend_label = function
    | Docker_log_backend -> "Docker"
    | Apple_container_log_backend -> "Apple Container"
    | Microsandbox_log_backend -> "microsandbox"
    | Nerdctl_kata_log_backend -> "nerdctl (Kata)"
  in
  (* A tail count belongs to a stream. Without one, neither it nor a backend
     name is printed: there is nothing they would describe. *)
  let source_row backend =
    if ko then Printf.sprintf "  출처            %s · 인스턴스별 최근 %d줄" (backend_label backend) logs.log_tail
    else Printf.sprintf "  %-18s %s · last %d lines per instance" "Source" (backend_label backend) logs.log_tail
  in
  let context_rows backend =
    match backend with
    | Docker_log_backend | Apple_container_log_backend | Microsandbox_log_backend -> []
    | Nerdctl_kata_log_backend ->
      let detail = match logs.log_kata_host_alignment with
        | Some Host_selectors_match -> tr
            "턴 실행 환경 기준 · 호스트 선택 변수 일치, 대상 미검증"
            "Turn execution context; host selectors match, target unverified"
        | Some Host_selectors_differ -> tr
            "턴 실행 환경 기준 · 호스트 조회 환경과 다름, 대상 미검증"
            "Turn execution context differs from host reads; target unverified"
        | Some Host_selectors_unavailable -> tr
            "턴 실행 환경 기준 · 호스트 환경 비교 불가, 대상 미검증"
            "Turn execution context; host comparison unavailable, target unverified"
        | None -> tr "로그 조회 환경 미보고" "Log execution context not reported" in
      wrapped_rows ~width ~label:(tr "조회 환경" "CLI context") ~tone:`Warn detail in
  match logs.log_source with
  | No_local_stream (location, reason) ->
    title
    @ wrapped_rows ~width ~label:(tr "출처" "Source") ~tone:`Info
        (tr "이 호스트의 로컬 스트림 없음" "no local stream on this host")
    @ wrapped_rows ~width ~label:(tr "위치" "Where") ~tone:`Info
        (match ko, location with
         | true, Remote_ssh_logs ->
           "이 Keeper는 설정된 SSH 엔드포인트에서 실행됩니다. 로그는 해당 엔드포인트에서 확인하세요."
         | (false, Remote_ssh_logs) | (_, (Local_log_stream | Unknown_log_location)) -> reason)
  | Local_no_instance backend ->
    title
    @ [ source_row backend ]
    @ context_rows backend
    @ wrapped_rows ~width ~label:(tr "상태" "State") ~tone:`Muted
        (match backend with
         | Nerdctl_kata_log_backend ->
           tr "이 로그 조회에서 인스턴스를 관측하지 못했습니다."
             "No instance was observed in this log listing."
         | Docker_log_backend | Apple_container_log_backend | Microsandbox_log_backend ->
           tr "아직 인스턴스가 없습니다. 샌드박스 명령을 실행해 주세요."
             "No container instance exists yet; run a sandbox command first.")
  | Local_instances (backend, instances) ->
    title
    @ [ source_row backend ]
    @ context_rows backend
    @ List.concat_map
        (fun instance ->
          let state =
            match instance.log_instance_running with
            | Some true -> tr "실행 관측" "observed running"
            | Some false -> tr "중지 관측" "observed stopped"
            | None -> tr "상태 미확인" "state unknown"
          in
          [ ""
          ; Printf.sprintf "  %s%s%s · %s · %s" Masc_tui_theme.Sgr.bold
              instance.log_instance_name Masc_tui_theme.Sgr.reset
              instance.log_instance_id state
          ]
          @ (match instance.log_error with
             | None -> []
             | Some detail -> wrapped_rows ~width ~label:(tr "오류" "Error") ~tone:`Bad detail)
          @ List.map (fun line -> "  out  " ^ line) instance.log_stdout
          @ List.map (fun line -> "  err  " ^ line) instance.log_stderr)
        instances
