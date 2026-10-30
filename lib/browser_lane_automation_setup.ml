type request =
  { runtime_config_path : string
  ; geckodriver : string option
  ; browser : string option
  }

type key = Geckodriver | Browser

let key_name = function
  | Geckodriver -> "geckodriver"
  | Browser -> "binary"

type change =
  | Created
  | Updated of key list
  | Unchanged

type location =
  | New_table
  | Automation_table
  | Browser_table

type error =
  | Configuration_missing of string
  | Configuration_unreadable of { path : string; reason : string }
  | Configuration_refused of string
  | Geckodriver_not_found
  | Geckodriver_does_not_answer of { path : string; detail : string }
  | Not_executable of { key : key; path : string }
  | Table_refused of string
  | Configuration_changed
  | Not_written of string

let automation_table = [ "browser"; "automation" ]
let browser_table = [ "browser" ]

let error_message = function
  | Configuration_missing path ->
    Printf.sprintf
      "%s does not exist, so there is no workspace configuration to add to. Run masc init \
       first, then this again."
      path
  | Configuration_unreadable { path; reason } ->
    Printf.sprintf "%s cannot be read: %s." path reason
  | Configuration_refused reason ->
    Printf.sprintf "runtime.toml would not load, so the automation table was not written: %s." reason
  | Geckodriver_not_found ->
    "No geckodriver answered on PATH. Install it (masc prerequisite-actions geckodriver), or \
     name the executable with --geckodriver."
  | Geckodriver_does_not_answer { path; detail } ->
    Printf.sprintf
      "The geckodriver at %s did not answer --version: %s. Name another with --geckodriver."
      path detail
  | Not_executable { key; path } ->
    Printf.sprintf "%s must be an executable file, and %s is not one."
      (match key with Geckodriver -> "--geckodriver" | Browser -> "--browser")
      path
  | Table_refused reason ->
    Printf.sprintf "The automation configuration would not load as written, so it was not \
                    written: %s."
      reason
  | Configuration_changed ->
    "runtime.toml changed while this ran, so the automation table was not written. Run this \
     again."
  | Not_written reason -> Printf.sprintf "The automation table was not written to runtime.toml: %s." reason

open Result.Syntax

let configuration_of_text text =
  match Otoml.Parser.from_string_result text with
  | Error reason -> Error reason
  | Ok toml -> Browser_configuration.parse toml

(* Where the keys are written. A configuration that is there is edited where
   it is, so a [\[browser\]] that holds [geckodriver] is not given a second
   spelling beside it (the loader refuses a file that has both). *)
let location_of_text text =
  match Otoml.Parser.from_string_result text with
  | Error _ -> New_table
  | Ok toml ->
    let present path = Option.is_some (Otoml.find_opt toml Fun.id path) in
    if present automation_table
    then Automation_table
    else if present [ "browser"; "geckodriver" ] || present [ "browser"; "binary" ]
    then Browser_table
    else New_table

let table_path_of = function
  | New_table | Automation_table -> automation_table
  | Browser_table -> browser_table

let set_key ~location ~(table : Browser_configuration.automation) text = function
  | Geckodriver ->
    Toml_line_editor.edit_table_scalar
      text
      ~path:(String.concat "." (table_path_of location))
      ~key:"geckodriver"
      ~value:(Some table.driver)
  | Browser ->
    Toml_line_editor.edit_table_scalar
      text
      ~path:(String.concat "." (table_path_of location))
      ~key:"binary"
      ~value:table.binary

let edit_text ~location ~table ~set text =
  List.fold_left (set_key ~location ~table) text set

let reads_back ~table text =
  match configuration_of_text text with
  | Error reason -> Error (Table_refused reason)
  | Ok { Browser_configuration.automation = Some written; _ }
    when Browser_configuration.equal_automation written table -> Ok ()
  | Ok { Browser_configuration.automation = Some _ | None; _ } ->
    Error (Table_refused "the file loads with other values than the ones written")

let editable ~location text =
  let declared, ancestors =
    match location with
    | New_table -> false, [ browser_table ]
    | Automation_table -> true, [ browser_table ]
    | Browser_table -> true, []
  in
  Runtime_table_edit.check_editable
    ~table_path:(table_path_of location)
    ~ancestors
    ~declared
    text
  |> Result.map_error (fun unreachable ->
    Table_refused
      (Runtime_table_edit.unreachable_message
         ~table_path:(table_path_of location)
         unreachable))

let edited ~location ~table ~set text =
  let* () = editable ~location text in
  let text = edit_text ~location ~table ~set text in
  let* () = reads_back ~table text in
  Ok text

let installed_geckodriver () =
  Browser_runtime_dependencies.observe Browser_runtime_dependencies.Geckodriver

let discovered_geckodriver ~find_geckodriver =
  match find_geckodriver () with
  | Browser_runtime_dependencies.Started { path; _ } -> Ok path
  | Browser_runtime_dependencies.Missing _ -> Error Geckodriver_not_found
  | Browser_runtime_dependencies.Failed { path; detail; _ } ->
    Error (Geckodriver_does_not_answer { path; detail })

(* A configuration that is not there is written with what was found and named.
   One that is there keeps its values and changes only what was named and
   differs from what it holds. *)
let decide ~find_geckodriver request = function
  | None ->
    let* driver =
      match request.geckodriver with
      | Some path -> Ok path
      | None -> discovered_geckodriver ~find_geckodriver
    in
    let binary = request.browser in
    let set = Geckodriver :: (match binary with Some _ -> [ Browser ] | None -> []) in
    Ok ({ Browser_configuration.driver; binary }, set, Created)
  | Some (current : Browser_configuration.automation) ->
    let driver = Option.value request.geckodriver ~default:current.driver in
    let binary =
      match request.browser with
      | Some path -> Some path
      | None -> current.binary
    in
    let set =
      List.filter_map
        Fun.id
        [ (if String.equal driver current.driver then None else Some Geckodriver)
        ; (if Option.equal String.equal binary current.binary then None else Some Browser)
        ]
    in
    let change = match set with [] -> Unchanged | keys -> Updated keys in
    Ok ({ Browser_configuration.driver; binary }, set, change)

(* A program the operator names is not looked for: a fork or another edition
   may be what they want. It has to be a file that can run. One that is there
   and does not answer --version is written as named, with a note: the probe
   runs without the display variables a Firefox may need, so a refusal would
   turn away one that works. *)
let named_programs ~request ~set =
  let check key = function
    | Some path when List.mem key set && not (String.equal (String.trim path) path) ->
      (* The probe trims what it is given, so it would find a program the
         value written does not name. *)
      Error (Not_executable { key; path })
    | Some path when List.mem key set ->
      (match Browser_runtime_dependencies.probe path with
       | Browser_runtime_dependencies.Missing _ -> Error (Not_executable { key; path })
       | Browser_runtime_dependencies.Started _ -> Ok None
       | Browser_runtime_dependencies.Failed { detail; _ } ->
         Ok
           (Some
              (Printf.sprintf
                 "%s did not answer --version (%s), so it was written as named and is not \
                  verified."
                 path detail)))
    | Some _ | None -> Ok None
  in
  let* driver_note = check Geckodriver request.geckodriver in
  let* browser_note = check Browser request.browser in
  Ok (List.filter_map Fun.id [ driver_note; browser_note ])

(* A value that is already there is kept, and the program it names can be gone
   since it was written: a brew upgrade or a removed install. The server then
   fails on it, while this command (and the install wizard, which found a
   geckodriver on PATH) reports success. Keeping the value is the promise, so
   it is not changed; this only says it is not there. The program is located,
   not started: it is the operator's, a launcher may open a window, and the
   question is only whether the file is there. One that exists and does not
   answer --version is therefore not said either, and it may need variables
   the probe runs without. *)
let kept_programs ~set = function
  | None -> []
  | Some (current : Browser_configuration.automation) ->
    let flag = function
      | Geckodriver -> "--geckodriver"
      | Browser -> "--browser"
    in
    let check key path =
      if List.mem key set
      then []
      else (
        (* The lookup trims what it is given, so a value with a space around
           it would be found as a file the server cannot start. *)
        let located =
          if String.equal (String.trim path) path
          then Browser_runtime_dependencies.locate path
          else None
        in
        match located with
        | Some _ -> []
        | None ->
          [ Printf.sprintf
              "%s = %s is not an executable file now. It is left as it is; name %s to \
               change it."
              (key_name key) path (flag key)
          ])
    in
    check Geckodriver current.driver
    @ (match current.binary with
       | Some path -> check Browser path
       | None -> [])

type plan =
  { runtime_config_path : string
  ; revision : string
  ; location : location
  ; existing : Browser_configuration.automation option
  ; table : Browser_configuration.automation
  ; set : key list
  ; change : change
  ; notes : string list
  }

let table plan = plan.table
let change plan = plan.change
let location plan = plan.location
let notes plan = plan.notes

let plan ~find_geckodriver (request : request) =
  let path = request.runtime_config_path in
  if not (Sys.file_exists path)
  then Error (Configuration_missing path)
  else
    let* observation =
      Runtime.load_config_observation ~runtime_config_path:path ()
      |> Result.map_error (fun reason -> Configuration_unreadable { path; reason })
    in
    let text = observation.source_text in
    let* configuration =
      configuration_of_text text |> Result.map_error (fun reason -> Configuration_refused reason)
    in
    let location = location_of_text text in
    let* table, set, change =
      decide ~find_geckodriver request configuration.Browser_configuration.automation
    in
    let* named =
      match set with
      | [] -> Ok []
      | set ->
        let* edited = edited ~location ~table ~set text in
        let* notes = named_programs ~request ~set in
        let* () =
          Runtime.validate_config_text ~runtime_config_path:path edited
          |> Result.map_error (fun reason -> Configuration_refused reason)
        in
        Ok notes
    in
    let notes =
      named @ kept_programs ~set configuration.Browser_configuration.automation
    in
    Ok
      { runtime_config_path = path
      ; revision = Runtime_table_edit.revision_of_observation observation
      ; location
      ; existing = configuration.Browser_configuration.automation
      ; table
      ; set
      ; change
      ; notes
      }

let replan previous =
  let path = previous.runtime_config_path in
  let* observation =
    Runtime.load_config_observation ~runtime_config_path:path ()
    |> Result.map_error (fun reason -> Configuration_unreadable { path; reason })
  in
  let text = observation.source_text in
  let* configuration =
    configuration_of_text text |> Result.map_error (fun reason -> Configuration_refused reason)
  in
  let location = location_of_text text in
  let* () =
    match previous.set with
    | [] -> Ok ()
    | set ->
      let* edited = edited ~location ~table:previous.table ~set text in
      Runtime.validate_config_text ~runtime_config_path:path edited
      |> Result.map_error (fun reason -> Configuration_refused reason)
  in
  (* The write since the plan was another table's (the bidi table, in the
     same run). An automation table that changed meanwhile is another
     writer's, and the plan's decisions were made without it. *)
  let* () =
    if Option.equal Browser_configuration.equal_automation
         configuration.Browser_configuration.automation previous.existing
    then Ok ()
    else Error Configuration_changed
  in
  Ok
    { previous with
      revision = Runtime_table_edit.revision_of_observation observation
    ; location
    }

let apply plan =
  match plan.set with
  | [] -> Ok ()
  | set ->
    (match
       Runtime_table_edit.commit
         ~runtime_config_path:plan.runtime_config_path
         ~revision:plan.revision
         ~edit:(edited ~location:plan.location ~table:plan.table ~set)
     with
     | Ok () -> Ok ()
     | Error Runtime_table_edit.Changed_meanwhile -> Error Configuration_changed
     | Error (Runtime_table_edit.Edit_refused error) -> Error error
     | Error (Runtime_table_edit.Not_written reason) -> Error (Not_written reason))
