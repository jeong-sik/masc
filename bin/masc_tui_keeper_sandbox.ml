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

type resource_config =
  { memory : string option
  ; cpus : string option
  ; work_volume_size : string option
  ; build_volume_size : string option
  ; pids_limit : int option
  ; tmpfs_size : string option
  }

type sandbox_paths =
  { host_workspace : string option
  ; guest_home : string option
  ; guest_workspace : string option
  ; guest_config : string option
  ; guest_work_volume : string option
  ; guest_build_volume : string option
  }

type sandbox_profile =
  | Docker
  | Micro_vm
  | Remote_ssh

(** A checkout whose [_build] is not on the volume, and why.

    This is the row an operator acts on: it is still writing to the virtiofs
    share, which is what exhausted the host's vnode table. Only a person can
    clear one -- the server refuses to delete build output it did not
    create. *)
type unlinked_checkout =
  { checkout_path : string
  ; checkout_reason : string
  }

type build_volume =
  { volume_name : string option
  ; guest_root : string
  ; linked : int
  ; unlinked : unlinked_checkout list
  }

type t =
  { sandbox_profile : sandbox_profile option
  ; configured_network_mode : string option
  ; containers : container list option
  ; container_error : string option
  ; build_volume : build_volume option
  ; resource_config : resource_config option
  ; paths : sandbox_paths option
  ; keeper_last_error : string option
  }

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

let decode_unlinked ~sanitize index json =
  let open Result.Syntax in
  let prefix = Printf.sprintf "sandbox_live.build_volume.unlinked[%d]." index in
  let* fields = assoc (prefix ^ "row") json in
  let required name =
    match field name fields with
    | Some (`String value) -> Ok (sanitize value)
    | Some _ -> Error (prefix ^ name ^ " must be a string")
    | None -> Error (prefix ^ name ^ " is required")
  in
  let* checkout_path = required "path" in
  let* checkout_reason = required "reason" in
  Ok { checkout_path; checkout_reason }
;;

(* [`Null] rather than a missing key is the docker and remote_ssh answer:
   they have no build volume, which is not the same as one that could not be
   read. Both decode to [None] and the view says nothing, but the server
   states which it means. *)
let decode_build_volume ~sanitize fields =
  let open Result.Syntax in
  match field "build_volume" fields with
  | None | Some `Null -> Ok None
  | Some (`Assoc inner) ->
    let* volume_name = string_opt ~sanitize ~key:"name" ~path:"build_volume.name" inner in
    let* guest_root =
      match field "guest_root" inner with
      | Some (`String value) -> Ok (sanitize value)
      | _ -> Error "sandbox_live.build_volume.guest_root must be a string"
    in
    let* linked =
      match field "linked" inner with
      | Some (`Int value) -> Ok value
      | _ -> Error "sandbox_live.build_volume.linked must be an integer"
    in
    let* unlinked =
      match field "unlinked" inner with
      | Some (`List rows) ->
        List.fold_right
          (fun row result ->
            match row, result with
            | Ok row, Ok rows -> Ok (row :: rows)
            | Error detail, _ | _, Error detail -> Error detail)
          (List.mapi (decode_unlinked ~sanitize) rows)
          (Ok [])
      | _ -> Error "sandbox_live.build_volume.unlinked must be a list"
    in
    Ok (Some { volume_name; guest_root; linked; unlinked })
  | Some _ -> Error "sandbox_live.build_volume must be an object or null"
;;

let decode_optional_object ~path decode fields =
  match field path fields with
  | None | Some `Null -> Ok None
  | Some (`Assoc inner) -> Result.map Option.some (decode inner)
  | Some _ -> Error ("sandbox_live." ^ path ^ " must be an object or null")
;;

let decode_resource_config ~sanitize fields =
  let open Result.Syntax in
  decode_optional_object ~path:"resource_config"
    (fun inner ->
      let* memory = string_opt ~sanitize ~key:"memory" ~path:"resource_config.memory" inner in
      let* cpus = string_opt ~sanitize ~key:"cpus" ~path:"resource_config.cpus" inner in
      let* work_volume_size =
        string_opt ~sanitize ~key:"work_volume_size" ~path:"resource_config.work_volume_size" inner
      in
      let* build_volume_size =
        string_opt ~sanitize ~key:"build_volume_size" ~path:"resource_config.build_volume_size" inner
      in
      let* pids_limit = int_opt ~key:"pids_limit" ~path:"resource_config.pids_limit" inner in
      let* tmpfs_size = string_opt ~sanitize ~key:"tmpfs_size" ~path:"resource_config.tmpfs_size" inner in
      Ok { memory; cpus; work_volume_size; build_volume_size; pids_limit; tmpfs_size })
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
      let* guest_build_volume = get "guest_build_volume" in
      Ok
        { host_workspace
        ; guest_home
        ; guest_workspace
        ; guest_config
        ; guest_work_volume
        ; guest_build_volume
        })
    fields
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
  let* containers = decode_containers ~sanitize live in
  let* container_error =
    string_opt ~sanitize ~path:"container_error" live
  in
  let* build_volume = decode_build_volume ~sanitize live in
  let* resource_config = decode_resource_config ~sanitize live in
  let* paths = decode_paths ~sanitize live in
  Ok
    { sandbox_profile
    ; configured_network_mode
    ; containers
    ; container_error
    ; build_volume
    ; resource_config
    ; paths
    ; keeper_last_error
    }

let styled code text =
  if String.equal code "" then text else code ^ text ^ Masc_tui_theme.Sgr.reset

let value = Option.value ~default:"not reported"

let status_code = function
  | `Ok -> Masc_tui_theme.status Masc_tui_theme.Ok
  | `Warn -> Masc_tui_theme.status Masc_tui_theme.Warn
  | `Bad -> Masc_tui_theme.status Masc_tui_theme.Bad
  | `Info -> Masc_tui_theme.status Masc_tui_theme.Info
  | `Muted -> Masc_tui_theme.status Masc_tui_theme.Muted

let wrapped_rows ~width ~label ~tone text =
  let prefix = Printf.sprintf "  %-14s " label in
  let continuation = String.make (String.length prefix) ' ' in
  let body_width = max 12 (width - String.length prefix) in
  match Masc_tui_message_layout.wrap_words ~max_cells:body_width text with
  | [] -> [ prefix ]
  | first :: rest ->
    (prefix ^ styled (status_code tone) first)
    :: List.map (fun line -> continuation ^ styled (status_code tone) line) rest

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

let profile_label = function
  | Some Docker -> "Docker"
  | Some Micro_vm -> "Apple Container VM"
  | Some Remote_ssh -> "Remote SSH"
  | None -> "not reported"

let status_lines ~width reading =
  let header = [ " " ^ styled Masc_tui_theme.Sgr.bold "status" ] in
  match reading.container_error, reading.containers with
  | Some detail, Some (_ :: _ as containers) ->
    header
    @ [ "  " ^ styled (status_code `Warn) "● DEGRADED" ]
    @ wrapped_rows ~width ~label:"Live instances" ~tone:`Warn
        (Printf.sprintf "%d reported with an inspection error"
           (List.length containers))
    @ wrapped_rows ~width ~label:"Runtime" ~tone:`Bad detail
  | Some detail, _ ->
    header
    @ [ "  " ^ styled (status_code `Bad) "● INSPECTION FAILED" ]
    @ wrapped_rows ~width ~label:"Runtime" ~tone:`Bad detail
  | None, None ->
    header
    @ [ "  " ^ styled (status_code `Warn) "? UNKNOWN" ]
    @ wrapped_rows ~width ~label:"Runtime" ~tone:`Warn
        "Live instance inventory was not reported."
  | None, Some containers ->
    let running =
      List.fold_left
        (fun count container ->
          count + if container.running = Some true then 1 else 0)
        0
        containers
    in
    if running > 0 then
      header
      @ [ "  " ^ styled (status_code `Ok) "● RUNNING" ]
      @ wrapped_rows ~width ~label:"Live instances" ~tone:`Ok
          (Printf.sprintf "%d running · %d total" running (List.length containers))
    else
      match containers with
      | _ :: _ ->
        header
        @ [ "  " ^ styled (status_code `Warn) "● STOPPED" ]
        @ wrapped_rows ~width ~label:"Live instances" ~tone:`Warn
            (Printf.sprintf "%d present · 0 running" (List.length containers))
      | [] ->
        match reading.sandbox_profile with
        | Some Micro_vm ->
          header
          @ [ "  " ^ styled (status_code `Info) "○ NOT STARTED" ]
          @ wrapped_rows ~width ~label:"Next" ~tone:`Info
              "The first sandbox command creates this Keeper's VM."
        | Some Docker ->
          header
          @ [ "  " ^ styled (status_code `Info) "○ IDLE" ]
          @ wrapped_rows ~width ~label:"Next" ~tone:`Info
              "A container starts when a sandbox command runs."
        | Some Remote_ssh ->
          header
          @ [ "  " ^ styled (status_code `Ok) "● REMOTE" ]
          @ wrapped_rows ~width ~label:"Execution" ~tone:`Info
              "Commands run on this Keeper's configured SSH endpoint."
        | None ->
          header
          @ [ "  " ^ styled (status_code `Warn) "○ NO LIVE INSTANCE" ]

let container_lines ~width containers =
  match containers with
  | None | Some [] -> []
  | Some containers ->
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "live instance" ]
    @ (containers
      |> List.concat_map (fun container ->
      let tone = if container.running = Some true then `Ok else `Warn in
      let state =
        match container.running with
        | Some true -> "running"
        | Some false -> "stopped"
        | None -> "state unknown"
      in
      let compute =
        joined_opt
          [ Option.map (fun value -> Printf.sprintf "%d CPU" value) container.cpus
          ; Option.map (fun value -> bytes_text value ^ " RAM") container.memory_bytes
          ]
      in
      let network =
        joined_opt
          [ Option.map (fun value -> "host " ^ value) container.hostname
          ; Option.map (fun value -> "IPv4 " ^ value) container.ipv4_address
          ; Option.map (fun value -> "gateway " ^ value) container.gateway
          ; Option.map (fun value -> "IPv6 " ^ value) container.ipv6_address
          ]
      in
      wrapped_rows ~width ~label:"State" ~tone
        (Printf.sprintf "%s · %s · %s" container.name state container.status)
      @ (match compute with
         | None -> []
         | Some compute -> wrapped_rows ~width ~label:"Compute" ~tone:`Info compute)
      @ (match network with
         | None -> []
         | Some network -> wrapped_rows ~width ~label:"Network" ~tone:`Info network)
      @ wrapped_rows ~width ~label:"Image" ~tone:`Muted container.image
      @ (match container.created_at with
         | None -> []
         | Some created -> wrapped_rows ~width ~label:"Created" ~tone:`Muted created)
      @ wrapped_rows ~width ~label:"Instance ID" ~tone:`Muted container.id
      @ (match container.owner_pid with
         | None -> []
         | Some pid ->
           wrapped_rows ~width ~label:"Owner PID" ~tone:`Muted (string_of_int pid))))

let resource_rows ~width = function
  | None -> []
  | Some resources ->
    let compute =
      [ Option.map (fun value -> "memory " ^ value) resources.memory
      ; Some ("CPU " ^ value resources.cpus)
      ; Option.map (fun value -> Printf.sprintf "pids %d" value) resources.pids_limit
      ; Option.map (fun value -> "tmpfs " ^ value) resources.tmpfs_size
      ]
      |> joined_opt
    in
    let storage =
      [ Option.map (fun size -> "work " ^ size) resources.work_volume_size
      ; Option.map (fun size -> "build " ^ size) resources.build_volume_size
      ]
      |> joined_opt
    in
    (match compute with
     | None -> []
     | Some compute -> wrapped_rows ~width ~label:"Limits" ~tone:`Info compute)
    @ (match storage with
       | None -> []
       | Some storage -> wrapped_rows ~width ~label:"Volume caps" ~tone:`Muted storage)

let configured_lines ~width reading =
  [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "configured" ]
  @ wrapped_rows ~width ~label:"Backend" ~tone:`Info
      (profile_label reading.sandbox_profile)
  @ wrapped_rows ~width ~label:"Network" ~tone:`Info
      (value reading.configured_network_mode)
  @ resource_rows ~width reading.resource_config

let path_lines ~width = function
  | None -> []
  | Some paths ->
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "filesystem" ]
    @ wrapped_rows ~width ~label:"Workspace" ~tone:`Info
        (value paths.guest_workspace)
    @ wrapped_rows ~width ~label:"HOME" ~tone:`Muted
        (Option.value paths.guest_home ~default:"unavailable")
    @ wrapped_rows ~width ~label:"Config" ~tone:`Muted (value paths.guest_config)
    @ wrapped_rows ~width ~label:"Host bundle" ~tone:`Muted
        (value paths.host_workspace)
    @ (match paths.guest_work_volume with
       | None -> []
       | Some path -> wrapped_rows ~width ~label:"Work volume" ~tone:`Muted path)
    @ (match paths.guest_build_volume with
       | None -> []
       | Some path -> wrapped_rows ~width ~label:"Build cache" ~tone:`Muted path)

(* Where this keeper's build output lands.

   A checkout on the share pins one host descriptor per file it writes, and
   a host descriptor is a host vnode; that is what emptied the table and
   panicked the machine. The count alone is not enough -- an operator needs
   the paths, because clearing a real [_build] is a person's job. The server
   will not delete build output it did not create. *)
let build_volume_lines ~width = function
  | None -> []
  | Some volume ->
    let headline =
      match volume.unlinked with
      | [] ->
        ( `Ok
        , Printf.sprintf "%d checkout(s) use the build volume" volume.linked )
      | rows ->
        ( `Warn
        , Printf.sprintf
            "%d use the build volume · %d still use the shared filesystem"
            volume.linked
            (List.length rows) )
    in
    let tone, summary = headline in
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "build cache" ]
    @ wrapped_rows ~width ~label:"Volume" ~tone:`Muted
        (Printf.sprintf "%s at %s" (value volume.volume_name) volume.guest_root)
    @ wrapped_rows ~width ~label:"Checkouts" ~tone summary
    @ List.concat_map
        (fun row ->
          wrapped_rows
            ~width
            ~label:"Shared fs"
            ~tone:`Warn
            (row.checkout_path ^ " — " ^ row.checkout_reason))
        volume.unlinked
;;

let view_lines ~width reading =
  status_lines ~width reading
  @ configured_lines ~width reading
  @ container_lines ~width reading.containers
  @ path_lines ~width reading.paths
  @ build_volume_lines ~width reading.build_volume
  @ (match reading.keeper_last_error with
     | None -> []
     | Some detail ->
       [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "diagnostics" ]
       @ wrapped_rows ~width ~label:"Keeper error" ~tone:`Bad detail)
  @ [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "related" ]
  @ wrapped_rows ~width ~label:"Container stdio" ~tone:`Info "o  actual logs"
  @ wrapped_rows ~width ~label:"Sandbox calls" ~tone:`Info "t  tool calls"

type log_backend =
  | Docker_log_backend
  | Apple_container_log_backend

type log_instance =
  { log_instance_id : string
  ; log_instance_name : string
  ; log_instance_running : bool option
  ; log_stdout : string list
  ; log_stderr : string list
  ; log_error : string option
  }

type logs =
  { log_backend : log_backend
  ; log_state : [ `Available | `No_instance ]
  ; log_tail : int
  ; log_instances : log_instance list
  }

let decode_logs ~sanitize json =
  let open Result.Syntax in
  let* fields = assoc "sandbox logs" json in
  let required_string path name fields =
    match field name fields with
    | Some (`String value) -> Ok value
    | Some _ -> Error (path ^ " must be a string")
    | None -> Error (path ^ " is required")
  in
  let* backend = required_string "sandbox logs.backend" "backend" fields in
  let* log_backend =
    match backend with
    | "docker" -> Ok Docker_log_backend
    | "apple_container" -> Ok Apple_container_log_backend
    | value -> Error ("sandbox logs.backend has unsupported value " ^ sanitize value)
  in
  let* state = required_string "sandbox logs.state" "state" fields in
  let* log_state =
    match state with
    | "available" -> Ok `Available
    | "no_instance" -> Ok `No_instance
    | value -> Error ("sandbox logs.state has unsupported value " ^ sanitize value)
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
  if log_state = `No_instance && log_instances <> [] then
    Error "sandbox logs.no_instance cannot carry instances"
  else if log_state = `Available && log_instances = [] then
    Error "sandbox logs.available requires an instance"
  else Ok { log_backend; log_state; log_tail; log_instances }
;;

let logs_view_lines ~width logs =
  let backend =
    match logs.log_backend with
    | Docker_log_backend -> "Docker"
    | Apple_container_log_backend -> "Apple Container"
  in
  let header =
    [ ""
    ; " " ^ styled Masc_tui_theme.Sgr.bold "container logs"
    ; Printf.sprintf "  %-18s %s · last %d lines per instance" "Source" backend
        logs.log_tail
    ]
  in
  match logs.log_state with
  | `No_instance ->
    header
    @ wrapped_rows ~width ~label:"State" ~tone:`Muted
        "No container instance exists yet; run a sandbox command first."
  | `Available ->
    header
    @ List.concat_map
        (fun instance ->
          let state =
            match instance.log_instance_running with
            | Some true -> "running"
            | Some false -> "stopped"
            | None -> "state unknown"
          in
          [ ""
          ; Printf.sprintf "  %s%s%s · %s · %s" Masc_tui_theme.Sgr.bold
              instance.log_instance_name Masc_tui_theme.Sgr.reset
              instance.log_instance_id state
          ]
          @ (match instance.log_error with
             | None -> []
             | Some detail -> wrapped_rows ~width ~label:"Error" ~tone:`Bad detail)
          @ List.map (fun line -> "  out  " ^ line) instance.log_stdout
          @ List.map (fun line -> "  err  " ^ line) instance.log_stderr)
        logs.log_instances
