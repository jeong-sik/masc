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

type identity =
  { agent_name : string option
  ; expected_agent_name : string option
  ; agent_name_matches : bool option
  ; warnings : string list
  }

type t =
  { sandbox_profile : string option
  ; configured_network_mode : string option
  ; effective_mode : string option
  ; managed_container_kind : string option
  ; containers : container list option
  ; container_error : string option
  ; why_no_container : string option
  ; sandbox_last_error : string option
  ; identity : identity option
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

let string_list ~sanitize ?key ~path fields =
  match field (Option.value key ~default:path) fields with
  | None | Some `Null -> Ok []
  | Some (`List values) ->
    List.fold_right
      (fun value result ->
        match value, result with
        | `String value, Ok values -> Ok (sanitize value :: values)
        | `String _, (Error _ as error) -> error
        | _, _ -> Error (path ^ " entries must be strings"))
      values
      (Ok [])
  | Some _ -> Error (path ^ " must be a list or null")

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

let decode_identity ~sanitize fields =
  match field "identity" fields with
  | None | Some `Null -> Ok None
  | Some json ->
    let open Result.Syntax in
    let* fields = assoc "sandbox_live.identity" json in
    let* agent_name =
      string_opt ~sanitize ~key:"agent_name"
        ~path:"sandbox_live.identity.agent_name" fields
    in
    let* expected_agent_name =
      string_opt ~sanitize
        ~key:"expected_agent_name"
        ~path:"sandbox_live.identity.expected_agent_name"
        fields
    in
    let* agent_name_matches =
      bool_opt ~key:"agent_name_matches"
        ~path:"sandbox_live.identity.agent_name_matches" fields
    in
    let* warnings =
      string_list ~sanitize ~key:"warnings"
        ~path:"sandbox_live.identity.warnings" fields
    in
    Ok (Some { agent_name; expected_agent_name; agent_name_matches; warnings })

let decode ~sanitize json =
  let open Result.Syntax in
  let* root = assoc "keeper status" json in
  let* sandbox_last_error =
    string_opt ~sanitize ~path:"sandbox_last_error" root
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
  let* identity = decode_identity ~sanitize live in
  Ok
    { sandbox_profile
    ; configured_network_mode
    ; effective_mode
    ; managed_container_kind
    ; containers
    ; container_error
    ; why_no_container
    ; sandbox_last_error
    ; identity
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
    ; Option.map
        (fun detail -> wrapped_rows ~width ~label:"Last error" ~tone:`Bad detail)
        reading.sandbox_last_error
    ]
    |> List.filter_map Fun.id
    |> List.concat
  in
  let explanation_lines =
    match reading.why_no_container with
    | None -> []
    | Some reason -> wrapped_rows ~width ~label:"Why no container" ~tone:`Info reason
  in
  let identity_lines =
    match reading.identity with
    | None -> []
    | Some identity ->
      let match_line =
        match identity.agent_name_matches with
        | Some true ->
          wrapped_rows ~width ~label:"Identity" ~tone:`Ok
            (Printf.sprintf "%s matches canonical name"
               (value identity.agent_name))
        | Some false ->
          wrapped_rows ~width ~label:"Identity" ~tone:`Bad
            (Printf.sprintf "%s expected %s"
               (value identity.agent_name)
               (value identity.expected_agent_name))
        | None ->
          wrapped_rows ~width ~label:"Identity" ~tone:`Muted "not reported"
      in
      match_line
      @ List.concat_map
          (wrapped_rows ~width ~label:"Warning" ~tone:`Warn)
          identity.warnings
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
  @ explanation_lines
  @ error_lines
  @ (if identity_lines = [] then [] else "" :: identity_lines)
