type container =
  { name : string
  ; id : string
  ; image : string
  ; status : string
  ; running : bool option
  ; created_at : string option
  ; container_kind : string option
  ; network_label : string option
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
  { sandbox_profile : string option
  ; configured_network_mode : string option
  ; effective_mode : string option
  ; managed_container_kind : string option
  ; containers : container list option
  ; container_error : string option
  ; why_no_container : string option
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
  let* container_kind =
    string_opt ~sanitize ~key:"container_kind"
      ~path:(prefix ^ "container_kind") fields
  in
  let* network_label =
    string_opt ~sanitize ~key:"network_label"
      ~path:(prefix ^ "network_label") fields
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
    ; container_kind
    ; network_label
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
  let* sandbox_profile =
    string_opt ~sanitize ~path:"sandbox_profile" live
  in
  let* configured_network_mode =
    string_opt ~sanitize ~path:"configured_network_mode" live
  in
  let* effective_mode =
    string_opt ~sanitize ~path:"effective_mode" live
  in
  let* managed_container_kind =
    string_opt ~sanitize ~path:"managed_container_kind" live
  in
  let* containers = decode_containers ~sanitize live in
  let* container_error =
    string_opt ~sanitize ~path:"container_error" live
  in
  let* why_no_container =
    string_opt ~sanitize ~path:"why_no_container" live
  in
  let* build_volume = decode_build_volume ~sanitize live in
  let* resource_config = decode_resource_config ~sanitize live in
  let* paths = decode_paths ~sanitize live in
  Ok
    { sandbox_profile
    ; configured_network_mode
    ; effective_mode
    ; managed_container_kind
    ; containers
    ; container_error
    ; why_no_container
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

let flow_row ~tone label value =
  Printf.sprintf "  %s %-10s %s"
    (styled (status_code tone) "●")
    label
    (styled (status_code tone) value)

let flow_link = "      │\n      ▼" |> String.split_on_char '\n'

let wrapped_rows ~width ~label ~tone text =
  let prefix = Printf.sprintf "  %-14s " label in
  let continuation = String.make (String.length prefix) ' ' in
  let body_width = max 12 (width - String.length prefix) in
  match Masc_tui_message_layout.wrap_words ~max_cells:body_width text with
  | [] -> [ prefix ]
  | first :: rest ->
    (prefix ^ styled (status_code tone) first)
    :: List.map (fun line -> continuation ^ styled (status_code tone) line) rest

let container_summary = function
  | None -> "not reported", `Muted
  | Some [] -> "0 observed", `Info
  | Some rows ->
    let running =
      List.fold_left
        (fun count container ->
          count + if container.running = Some true then 1 else 0)
        0
        rows
    in
    ( Printf.sprintf "%d observed · %d running" (List.length rows) running
    , if running = List.length rows then `Ok else `Warn )

let bytes_text bytes =
  let gib = 1024. *. 1024. *. 1024. in
  if Float.of_int bytes >= gib then
    Printf.sprintf "%.1f GiB" (Float.of_int bytes /. gib)
  else
    Printf.sprintf "%.1f MiB" (Float.of_int bytes /. (1024. *. 1024.))

let container_lines ~width containers =
  match containers with
  | None | Some [] -> []
  | Some containers ->
    containers
    |> List.concat_map (fun container ->
      let tone = if container.running = Some true then `Ok else `Warn in
      let state =
        match container.running with
        | Some true -> "running"
        | Some false -> "stopped"
        | None -> "state unknown"
      in
      let headline =
        Printf.sprintf "%s · %s · %s" container.name state container.status
      in
      let details =
        [ Some ("id " ^ container.id)
        ; Some ("image " ^ container.image)
        ; Option.map (fun value -> "kind " ^ value) container.container_kind
        ; Option.map (fun value -> "network " ^ value) container.network_label
        ; Option.map (fun value -> "pid " ^ string_of_int value) container.owner_pid
        ; Option.map (fun value -> "created " ^ value) container.created_at
        ; Option.map (fun value -> Printf.sprintf "%d CPU" value) container.cpus
        ; Option.map (fun value -> "memory " ^ bytes_text value) container.memory_bytes
        ]
        |> List.filter_map Fun.id
        |> String.concat " · "
      in
      let network =
        [ Option.map (fun value -> "host " ^ value) container.hostname
        ; Option.map (fun value -> "IPv4 " ^ value) container.ipv4_address
        ; Option.map (fun value -> "gateway " ^ value) container.gateway
        ; Option.map (fun value -> "IPv6 " ^ value) container.ipv6_address
        ]
        |> List.filter_map Fun.id
        |> String.concat " · "
      in
      wrapped_rows ~width ~label:"Container" ~tone headline
      @ wrapped_rows ~width ~label:"" ~tone:`Muted details
      @ if String.equal network "" then [] else wrapped_rows ~width ~label:"Network" ~tone:`Info network)

let resource_lines ~width = function
  | None -> []
  | Some resources ->
    let compute =
      [ Option.map (fun value -> "memory " ^ value) resources.memory
      ; Some ("CPU " ^ value resources.cpus)
      ; Option.map (fun value -> Printf.sprintf "pids %d" value) resources.pids_limit
      ; Option.map (fun value -> "tmpfs " ^ value) resources.tmpfs_size
      ]
      |> List.filter_map Fun.id
      |> String.concat " · "
    in
    let storage =
      [ Option.map (fun size -> "work " ^ size) resources.work_volume_size
      ; Option.map (fun size -> "build " ^ size) resources.build_volume_size
      ]
      |> List.filter_map Fun.id
      |> String.concat " · "
    in
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "resources" ]
    @ wrapped_rows ~width ~label:"Configured" ~tone:`Info compute
    @ if String.equal storage "" then [] else wrapped_rows ~width ~label:"Volume caps" ~tone:`Muted storage

let path_lines ~width = function
  | None -> []
  | Some paths ->
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "paths" ]
    @ wrapped_rows ~width ~label:"Host workspace" ~tone:`Muted (value paths.host_workspace)
    @ wrapped_rows ~width ~label:"Guest home" ~tone:`Info
        (Option.value paths.guest_home
           ~default:"not observed (HOME is not declared by the sandbox runtime)")
    @ wrapped_rows ~width ~label:"Guest workspace" ~tone:`Info (value paths.guest_workspace)
    @ wrapped_rows ~width ~label:"Guest config" ~tone:`Muted (value paths.guest_config)
    @ (match paths.guest_work_volume with
       | None -> []
       | Some path -> wrapped_rows ~width ~label:"Work volume" ~tone:`Muted path)
    @ (match paths.guest_build_volume with
       | None -> []
       | Some path -> wrapped_rows ~width ~label:"Build volume" ~tone:`Muted path)

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
        , Printf.sprintf "%d checkout(s) on %s" volume.linked volume.guest_root )
      | rows ->
        ( `Warn
        , Printf.sprintf
            "%d on %s, %d still on the share"
            volume.linked
            volume.guest_root
            (List.length rows) )
    in
    let tone, summary = headline in
    [ ""; " " ^ styled Masc_tui_theme.Sgr.bold "build output" ]
    @ wrapped_rows ~width ~label:"Volume" ~tone:`Muted (value volume.volume_name)
    @ wrapped_rows ~width ~label:"Placed" ~tone summary
    @ List.concat_map
        (fun row ->
          wrapped_rows
            ~width
            ~label:"On share"
            ~tone:`Warn
            (row.checkout_path ^ " — " ^ row.checkout_reason))
        volume.unlinked
;;

let view_lines ~width reading =
  let containers, observed_tone = container_summary reading.containers in
  let declared =
    Printf.sprintf "%s / network %s"
      (value reading.sandbox_profile)
      (value reading.configured_network_mode)
  in
  let effective = value reading.effective_mode in
  let error_lines =
    [ Option.map
        (fun detail -> wrapped_rows ~width ~label:"Container error" ~tone:`Bad detail)
        reading.container_error
      (* Not the sandbox's error. [Keeper_registry] records the keeper's last
         error whatever its source, so a Board ledger decode failure lands
         here too. It sat under "Last error" one line below "Container
         error", and a reader took a schema-version complaint about an
         unrelated ledger as proof the sandbox was broken. The label names
         whose error it is; "Container error" above stays the sandbox one. *)
    ; Option.map
        (fun detail ->
           wrapped_rows ~width ~label:"Keeper last error" ~tone:`Bad detail)
        reading.keeper_last_error
    ]
    |> List.filter_map Fun.id
    |> List.concat
  in
  let explanation_lines =
    match reading.why_no_container with
    | None -> []
    | Some reason -> wrapped_rows ~width ~label:"Why no container" ~tone:`Info reason
  in
  [ " " ^ styled Masc_tui_theme.Sgr.bold "sandbox flow"
  ; flow_row ~tone:`Info "Declared" declared
  ]
  @ flow_link
  @ [ flow_row ~tone:`Info "Effective" effective ]
  @ flow_link
  @ [ flow_row ~tone:observed_tone "Observed" containers
    ; ""
    ; " " ^ styled Masc_tui_theme.Sgr.bold "live evidence"
    ]
  @ wrapped_rows ~width ~label:"Managed kind" ~tone:`Muted
      (value reading.managed_container_kind)
  @ container_lines ~width reading.containers
  @ resource_lines ~width reading.resource_config
  @ path_lines ~width reading.paths
  @ build_volume_lines ~width reading.build_volume
  @ explanation_lines
  @ error_lines
  @ [ ""
    ; " " ^ styled Masc_tui_theme.Sgr.bold "observability"
    ]
  @ wrapped_rows ~width ~label:"Keeper logs" ~tone:`Info "press l"
  @ wrapped_rows ~width ~label:"Tool calls" ~tone:`Info "press t"
