type container =
  { name : string
  ; id : string
  ; image : string
  ; status : string
  ; running : bool option
  ; container_kind : string option
  ; network_label : string option
  ; owner_pid : int option
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
  Ok
    { name
    ; id
    ; image
    ; status
    ; running
    ; container_kind
    ; network_label
    ; owner_pid
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
  Ok
    { sandbox_profile
    ; configured_network_mode
    ; effective_mode
    ; managed_container_kind
    ; containers
    ; container_error
    ; why_no_container
    ; build_volume
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
    (styled (status_code tone) "â")
    label
    (styled (status_code tone) value)

let flow_link = "      â\n      â¼" |> String.split_on_char '\n'

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
    ( Printf.sprintf "%d observed Â· %d running" (List.length rows) running
    , if running = List.length rows then `Ok else `Warn )

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
        Printf.sprintf "%s Â· %s Â· %s" container.name state container.status
      in
      let details =
        [ Some ("id " ^ container.id)
        ; Some ("image " ^ container.image)
        ; Option.map (fun value -> "kind " ^ value) container.container_kind
        ; Option.map (fun value -> "network " ^ value) container.network_label
        ; Option.map (fun value -> "pid " ^ string_of_int value) container.owner_pid
        ]
        |> List.filter_map Fun.id
        |> String.concat " Â· "
      in
      wrapped_rows ~width ~label:"Container" ~tone headline
      @ wrapped_rows ~width ~label:"" ~tone:`Muted details)

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
  @ build_volume_lines ~width reading.build_volume
  @ explanation_lines
  @ error_lines
