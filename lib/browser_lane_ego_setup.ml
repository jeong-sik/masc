type request =
  { runtime_config_path : string
  ; command : string option
  ; space : string option
  }

let default_space = "masc"

type key = Command | Space

let key_name = function
  | Command -> "command"
  | Space -> "space"

type change =
  | Created
  | Updated of key list
  | Unchanged

type error =
  | Configuration_missing of string
  | Configuration_unreadable of { path : string; reason : string }
  | Configuration_refused of string
  | Ego_not_found
  | Ego_not_executable of string
  | Ego_unusable of { path : string; detail : string }
  | Table_refused of string
  | Configuration_changed
  | Not_written of string

let table_path = "browser.live.ego"

let error_message = function
  | Configuration_missing path ->
    Printf.sprintf
      "%s does not exist, so there is no workspace configuration to add the table to. Run \
       masc init first, then this again."
      path
  | Configuration_unreadable { path; reason } ->
    Printf.sprintf "%s cannot be read: %s." path reason
  | Configuration_refused reason ->
    Printf.sprintf "runtime.toml would not load, so nothing was written: %s." reason
  | Ego_not_found ->
    "No ego-browser answered on PATH or in ~/.local/bin. Install ego lite and finish its \
     onboarding, which puts ego-browser there, or name it with --ego-command."
  | Ego_not_executable path ->
    Printf.sprintf "--ego-command must be an executable file, and %s is not one." path
  | Ego_unusable { path; detail } ->
    Printf.sprintf
      "The ego-browser at %s did not answer --version with ego lite's and Chromium's \
       versions: %s. Finish ego lite's onboarding, or name another with --ego-command."
      path detail
  | Table_refused reason ->
    Printf.sprintf "The [%s] table would not load as written, so nothing was written: %s." table_path
      reason
  | Configuration_changed ->
    "runtime.toml changed while this ran, so nothing was written. Run this again."
  | Not_written reason -> Printf.sprintf "runtime.toml was not written: %s." reason

let ( let* ) = Result.bind

let configuration_of_text text =
  match Otoml.Parser.from_string_result text with
  | Error reason -> Error reason
  | Ok toml -> Browser_configuration.parse toml

let set_key ~(table : Browser_configuration.live_ego) text = function
  | Command ->
    Toml_line_editor.edit_table_scalar text ~path:table_path ~key:"command" ~value:(Some table.command)
  | Space ->
    Toml_line_editor.edit_table_scalar text ~path:table_path ~key:"space" ~value:(Some table.space)

let edit_text ~table ~set text = List.fold_left (set_key ~table) text set

(* What the loader reads from the edited text is the table that was asked for. *)
let reads_back ~table text =
  match configuration_of_text text with
  | Error reason -> Error (Table_refused reason)
  | Ok { Browser_configuration.live_ego = Some written; _ }
    when Browser_configuration.equal_live_ego written table -> Ok ()
  | Ok { Browser_configuration.live_ego = Some _ | None; _ } ->
    Error (Table_refused "the file loads with other values than the ones written")

let table_path_list = [ "browser"; "live"; "ego" ]
let ancestors = [ [ "browser" ]; [ "browser"; "live" ] ]

let editable ~existing text =
  Runtime_table_edit.check_editable
    ~table_path:table_path_list
    ~ancestors
    ~declared:(Option.is_some existing)
    text
  |> Result.map_error (fun unreachable ->
    Table_refused (Runtime_table_edit.unreachable_message ~table_path:table_path_list unreachable))

let edited ~existing ~table ~set text =
  let* () = editable ~existing text in
  let text = edit_text ~table ~set text in
  let* () = reads_back ~table text in
  Ok text

let installed_ego () =
  Browser_runtime_dependencies.observe Browser_runtime_dependencies.Ego_browser

(* An ego-browser that answered named ego lite's and Chromium's versions
   (Browser_runtime_dependencies.probe_program); they are read from its answer. *)
let versions_of ~path output =
  Browser_runtime_dependencies.ego_versions output
  |> Result.map_error (fun detail -> Ego_unusable { path; detail })

let discovered ~find_ego =
  match find_ego () with
  | Browser_runtime_dependencies.Started { path; output; _ } ->
    let* versions = versions_of ~path output in
    Ok (path, versions)
  | Browser_runtime_dependencies.Missing _ -> Error Ego_not_found
  | Browser_runtime_dependencies.Failed { path; detail; _ } -> Error (Ego_unusable { path; detail })

(* A named command is started as it is: the worker runs exactly the path the
   table holds. *)
let named path =
  if not (String.equal (String.trim path) path) || Filename.is_relative path
  then Error (Ego_not_executable path)
  else
    match Browser_runtime_dependencies.(probe_program Ego_browser) path with
    | Browser_runtime_dependencies.Missing _ -> Error (Ego_not_executable path)
    | Browser_runtime_dependencies.Failed { detail; _ } -> Error (Ego_unusable { path; detail })
    | Browser_runtime_dependencies.Started { output; _ } -> versions_of ~path output

(* A table that is not there is written whole, with the defaults for what was
   not named. A table that is there keeps its values and changes only what was
   named and differs from what it holds. The command written is started once
   to read its versions; a command the table keeps is not started. *)
let decide ~find_ego request = function
  | None ->
    let* command, versions =
      match request.command with
      | Some path -> let* versions = named path in Ok (path, versions)
      | None -> discovered ~find_ego
    in
    let space = Option.value request.space ~default:default_space in
    Ok ({ Browser_configuration.command; space }, [ Command; Space ], Created, Some versions)
  | Some (current : Browser_configuration.live_ego) ->
    let command = Option.value request.command ~default:current.command in
    let space = Option.value request.space ~default:current.space in
    let set =
      List.filter_map
        Fun.id
        [ (if String.equal command current.command then None else Some Command)
        ; (if String.equal space current.space then None else Some Space)
        ]
    in
    let* versions = if List.mem Command set then Result.map Option.some (named command) else Ok None in
    let change = match set with [] -> Unchanged | keys -> Updated keys in
    Ok ({ Browser_configuration.command; space }, set, change, versions)

type plan =
  { runtime_config_path : string
  ; revision : string
  ; existing : Browser_configuration.live_ego option
  ; table : Browser_configuration.live_ego
  ; set : key list
  ; change : change
  ; lane_enabled : bool
  ; versions : (string * string) option
  }

let table plan = plan.table
let change plan = plan.change
let lane_enabled plan = plan.lane_enabled
let versions plan = plan.versions

let observe path =
  let* observation =
    Runtime.load_config_observation ~runtime_config_path:path ()
    |> Result.map_error (fun reason -> Configuration_unreadable { path; reason })
  in
  let* configuration =
    configuration_of_text observation.source_text
    |> Result.map_error (fun reason -> Configuration_refused reason)
  in
  Ok (observation, configuration)

let validated ~path ~existing ~table ~set text =
  match set with
  | [] -> Ok ()
  | set ->
    let* edited = edited ~existing ~table ~set text in
    Runtime.validate_config_text ~runtime_config_path:path edited
    |> Result.map_error (fun reason -> Configuration_refused reason)

let plan ~find_ego (request : request) =
  let path = request.runtime_config_path in
  if not (Sys.file_exists path)
  then Error (Configuration_missing path)
  else
    let* observation, configuration = observe path in
    let existing = configuration.Browser_configuration.live_ego in
    let* table, set, change, versions = decide ~find_ego request existing in
    let* () = validated ~path ~existing ~table ~set observation.source_text in
    Ok
      { runtime_config_path = path
      ; revision = Runtime_table_edit.revision_of_observation observation
      ; existing
      ; table
      ; set
      ; change
      ; lane_enabled = configuration.Browser_configuration.live_enabled
      ; versions
      }

let replan previous =
  let path = previous.runtime_config_path in
  let* observation, configuration = observe path in
  let existing = configuration.Browser_configuration.live_ego in
  let* () = validated ~path ~existing ~table:previous.table ~set:previous.set observation.source_text in
  Ok
    { previous with
      revision = Runtime_table_edit.revision_of_observation observation
    ; existing
    ; lane_enabled = configuration.Browser_configuration.live_enabled
    }

(* Under the configuration lock the text is the one on disk now: the revision
   the plan was made from is compared again, and what the edit produces is read
   back before it is committed. *)
let apply plan =
  match plan.set with
  | [] -> Ok ()
  | _ :: _ ->
    (match
       Runtime_table_edit.commit
         ~runtime_config_path:plan.runtime_config_path
         ~revision:plan.revision
         ~edit:(edited ~existing:plan.existing ~table:plan.table ~set:plan.set)
     with
     | Ok () -> Ok ()
     | Error Runtime_table_edit.Changed_meanwhile -> Error Configuration_changed
     | Error (Runtime_table_edit.Edit_refused error) -> Error error
     | Error (Runtime_table_edit.Not_written reason) -> Error (Not_written reason))
