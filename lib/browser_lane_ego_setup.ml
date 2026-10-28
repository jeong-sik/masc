type request =
  { runtime_config_path : string
  ; command : string option
  ; space : string option
  }

let default_space = "masc-keepers"

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
  | Ego_unstartable of { path : string; detail : string }
  | Table_refused of string
  | Space_held_by_operator of { space : Browser_configuration.ego_space; space_id : int }
  | Spaces_unanswered of { path : string; space : Browser_configuration.ego_space; detail : string }
  | Spaces_unreadable of { path : string; space : Browser_configuration.ego_space; detail : string }
  | Configuration_changed
  | Not_written of string

let table_path = "browser.live.ego"
(* How a message names the configured Space: a name quoted, an exact ID as a
   number, since a quoted number is a name (RFC-browser-live-ego). *)
let space_label = function
  | Browser_configuration.Named_space name -> Printf.sprintf "%S" name
  | Existing_space id -> Printf.sprintf "id %d" id

let error_message = function
  | Configuration_missing path ->
    Printf.sprintf
      "%s does not exist, so there is no workspace configuration to add the table to. Run \
       masc init first, then this again."
      path
  | Configuration_unreadable { path; reason } ->
    Printf.sprintf "%s cannot be read: %s." path reason
  | Configuration_refused reason ->
    Printf.sprintf "runtime.toml would not load, so [%s] was not written: %s." table_path reason
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
  | Ego_unstartable { path; detail } ->
    Printf.sprintf "The ego-browser at %s could not be started: %s. Name another with --ego-command."
      path detail
  | Table_refused reason ->
    Printf.sprintf "The [%s] table would not load as written, so it was not written: %s." table_path
      reason
  | Space_held_by_operator { space; space_id } ->
    Printf.sprintf
      "The ego task space %s (id %d) belongs to the operator, and masc does not take over a \
       space the operator made. Name another with --ego-space."
      (space_label space) space_id
  | Spaces_unanswered { path; space; detail } ->
    Printf.sprintf
      "The ego-browser at %s did not list ego lite's task spaces, so whether the operator \
       holds %s is unknown: %s. Open ego lite and run this again."
      path (space_label space) detail
  | Spaces_unreadable { path; space; detail } ->
    Printf.sprintf
      "The ego-browser at %s answered the task space list in a form masc does not read, so \
       whether the operator holds %S is unknown: %s. Running this again will not help until \
       masc and ego lite agree; update the one that is older."
      path (space_label space) detail
  | Configuration_changed ->
    Printf.sprintf "runtime.toml changed while this ran, so [%s] was not written. Run this again."
      table_path
  | Not_written reason -> Printf.sprintf "[%s] was not written to runtime.toml: %s." table_path reason

open Result.Syntax

let configuration_of_text text =
  match Otoml.Parser.from_string_result text with
  | Error reason -> Error reason
  | Ok toml -> Browser_configuration.parse toml

let set_key ~(table : Browser_configuration.live_ego) text = function
  | Command ->
    Toml_line_editor.edit_table_scalar text ~path:table_path ~key:"command" ~value:(Some table.command)
  | Space ->
    (match table.space with
     | Browser_configuration.Named_space name ->
       Toml_line_editor.edit_table_scalar text ~path:table_path ~key:"space" ~value:(Some name)
     | Existing_space id -> Toml_line_editor.edit_table_int text ~path:table_path ~key:"space" ~value:id)

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

(* The worker opens its space by name, and ego refuses a name the operator's
   space holds; the worker would then fail to start. Every plan checks the
   space of the table it leaves, written or kept: a kept table may name a
   space the operator made after it was written. The spaces are listed by
   the ego-browser the table names; opening the space instead would make it. *)
let space_is_free ~(table : Browser_configuration.live_ego) =
  let unanswered detail = Error (Spaces_unanswered { path = table.command; space = table.space; detail }) in
  let failed failure = unanswered (Browser_ego_peer.run_failure_message failure) in
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ~timeout_sec:Browser_ego_peer.read_window_s
      ~env:(Env_keeper_scrub.filter_environment (Unix.environment ()))
      [ table.command; "nodejs"; "-e"; Browser_ego_peer.task_spaces_script ]
  with
  | Error refusal ->
    Error (Ego_unstartable { path = table.command; detail = Process_eio.spawn_refusal_to_string refusal })
  | Ok (status, stdout, stderr) ->
    let output = stdout ^ "\n" ^ stderr in
    (match status with
     (* [run_argv_with_status_split_or_refusal] synthesises 124 on its own timeout. *)
     | Unix.WEXITED 124 -> failed Browser_ego_peer.Timed_out
     | Unix.WEXITED 0 ->
       (match Browser_ego_peer.matching_spaces ~space:table.space output with
        | Error (Browser_ego_peer.Spaces_failed detail) -> unanswered detail
        | Error (Browser_ego_peer.Spaces_malformed detail) ->
          Error (Spaces_unreadable { path = table.command; space = table.space; detail })
        | Ok spaces ->
          (match
             List.find_map
               (fun (space_id, owner) ->
                  match owner with
                  | Browser_ego_peer.Operator_owner -> Some space_id
                  | Browser_ego_peer.Agent_owner | Browser_ego_peer.Handed_to_operator -> None)
               spaces
           with
           | Some space_id -> Error (Space_held_by_operator { space = table.space; space_id })
           | None -> Ok ()))
     | Unix.WEXITED code -> failed (Browser_ego_peer.Exited { code; output })
     | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> failed (Browser_ego_peer.Signaled signal))

(* A table that is not there is written whole, with the defaults for what was
   not named. A table that is there keeps its values and changes only what was
   named and differs from what it holds. The command written is started once
   to read its versions; a command the table keeps is not started for them.
   The space the table holds is checked against ego's spaces ([space_is_free]). *)
let decide ~find_ego request = function
  | None ->
    let* command, versions =
      match request.command with
      | Some path -> let* versions = named path in Ok (path, versions)
      | None -> discovered ~find_ego
    in
    let space = Browser_configuration.Named_space (Option.value request.space ~default:default_space) in
    Ok ({ Browser_configuration.command; space }, [ Command; Space ], Created, Some versions)
  | Some (current : Browser_configuration.live_ego) ->
    let command = Option.value request.command ~default:current.command in
    let space = match request.space with None -> current.space | Some name -> Browser_configuration.Named_space name in
    let set =
      List.filter_map
        Fun.id
        [ (if String.equal command current.command then None else Some Command)
        ; (if Browser_configuration.equal_ego_space space current.space then None else Some Space)
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
  ; versions : (string * string) option
  }

let table plan = plan.table
let change plan = plan.change
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
    let* () = space_is_free ~table in
    Ok
      { runtime_config_path = path
      ; revision = Runtime_table_edit.revision_of_observation observation
      ; existing
      ; table
      ; set
      ; change
      ; versions
      }

let replan previous =
  let path = previous.runtime_config_path in
  let* observation, configuration = observe path in
  let existing = configuration.Browser_configuration.live_ego in
  let* () = validated ~path ~existing ~table:previous.table ~set:previous.set observation.source_text in
  (* Another table of this run may have been written since the plan, not this
     one: a table that changed meanwhile is another writer's, and the plan's
     decisions were made without it. *)
  let* () =
    if Option.equal Browser_configuration.equal_live_ego existing previous.existing
    then Ok ()
    else Error Configuration_changed
  in
  Ok
    { previous with
      revision = Runtime_table_edit.revision_of_observation observation
    ; existing
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
