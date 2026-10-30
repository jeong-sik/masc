type request =
  { runtime_config_path : string
  ; home : string option
  ; firefox : string option
  ; profile : string option
  ; port : int option
  }

type key = Firefox | Profile | Port

let key_name = function
  | Firefox -> "firefox"
  | Profile -> "profile"
  | Port -> "port"

type change =
  | Created
  | Updated of key list
  | Unchanged

type error =
  | Configuration_missing of string
  | Configuration_unreadable of { path : string; reason : string }
  | Configuration_refused of string
  | Home_unknown
  | Firefox_not_found
  | Firefox_does_not_answer of { path : string; detail : string }
  | Firefox_not_executable of string
  | Profile_not_a_directory of string
  | Profile_not_created of { path : string; reason : string }
  | Table_refused of string
  | Configuration_changed
  | Not_written of string

let table_path = "browser.live.bidi"
let default_profile_name = "masc-keeper-firefox-profile"
let profile_mode = 0o700

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
  | Home_unknown ->
    "HOME is not set, so the default profile has no place. Name the profile with --profile."
  | Firefox_not_found ->
    "No Firefox answered on PATH or in the macOS application folders. Install Firefox, or \
     name the executable with --firefox."
  | Firefox_does_not_answer { path; detail } ->
    Printf.sprintf
      "The Firefox at %s did not answer --version: %s. Name another with --firefox."
      path detail
  | Firefox_not_executable path ->
    Printf.sprintf "--firefox must be an executable file, and %s is not one." path
  | Profile_not_a_directory path ->
    Printf.sprintf "The profile %s exists and is not a directory." path
  | Profile_not_created { path; reason } ->
    Printf.sprintf "Could not create the profile directory %s: %s." path reason
  | Table_refused reason ->
    Printf.sprintf "The [%s] table would not load as written, so it was not written: %s." table_path
      reason
  | Configuration_changed ->
    Printf.sprintf "runtime.toml changed while this ran, so [%s] was not written. Run this again."
      table_path
  | Not_written reason -> Printf.sprintf "[%s] was not written to runtime.toml: %s." table_path reason

open Result.Syntax

let configuration_of_text text =
  match Otoml.Parser.from_string_result text with
  | Error reason -> Error reason
  | Ok toml -> Browser_configuration.parse toml

let set_key ~(table : Browser_configuration.live_bidi) text = function
  | Firefox ->
    Toml_line_editor.edit_table_scalar text ~path:table_path ~key:"firefox"
      ~value:(Some table.firefox)
  | Profile ->
    Toml_line_editor.edit_table_scalar text ~path:table_path ~key:"profile"
      ~value:(Some table.profile)
  | Port -> Toml_line_editor.edit_table_int text ~path:table_path ~key:"port" ~value:table.port

let edit_text ~table ~set text = List.fold_left (set_key ~table) text set

(* What the loader reads from the edited text is the table that was asked for.
   A last check on the edit: {!editable} has already refused the spellings a
   line editor cannot reach. *)
let reads_back ~table text =
  match configuration_of_text text with
  | Error reason -> Error (Table_refused reason)
  | Ok { Browser_configuration.live_bidi = Some written; _ }
    when Browser_configuration.equal_live_bidi written table -> Ok ()
  | Ok { Browser_configuration.live_bidi = Some _ | None; _ } ->
    Error (Table_refused "the file loads with other values than the ones written")

let table_path_list = [ "browser"; "live"; "bidi" ]
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

let installed_firefox () =
  Browser_runtime_dependencies.observe Browser_runtime_dependencies.Firefox

let discovered_firefox ~find_firefox =
  match find_firefox () with
  | Browser_runtime_dependencies.Started { path; _ } -> Ok path
  | Browser_runtime_dependencies.Missing _ -> Error Firefox_not_found
  | Browser_runtime_dependencies.Failed { path; detail; _ } ->
    Error (Firefox_does_not_answer { path; detail })

let default_profile ~home =
  match home with
  | Some home when not (String.equal home "") ->
    Ok (Filename.concat home default_profile_name)
  | Some _ | None -> Error Home_unknown

(* A table that is not there is written whole, with the defaults for what was
   not named. A table that is there keeps its values and changes only what was
   named and differs from what it holds. *)
let decide ~find_firefox request = function
  | None ->
    let* firefox =
      match request.firefox with
      | Some path -> Ok path
      | None -> discovered_firefox ~find_firefox
    in
    let* profile =
      match request.profile with
      | Some path -> Ok path
      | None -> default_profile ~home:request.home
    in
    let port = Option.value request.port ~default:Browser_configuration.default_live_bidi_port in
    let set =
      [ Firefox; Profile ] @ (match request.port with Some _ -> [ Port ] | None -> [])
    in
    Ok ({ Browser_configuration.firefox; profile; port }, set, Created)
  | Some (current : Browser_configuration.live_bidi) ->
    let firefox = Option.value request.firefox ~default:current.firefox in
    let profile = Option.value request.profile ~default:current.profile in
    let port = Option.value request.port ~default:current.port in
    let set =
      List.filter_map
        Fun.id
        [ (if String.equal firefox current.firefox then None else Some Firefox)
        ; (if String.equal profile current.profile then None else Some Profile)
        ; (if port = current.port then None else Some Port)
        ]
    in
    let change = match set with [] -> Unchanged | keys -> Updated keys in
    Ok ({ Browser_configuration.firefox; profile; port }, set, change)

(* A Firefox the operator names is not looked for: a Firefox of another
   edition or a fork may be what they want. It has to be a file that can run.
   One that is there and does not answer [--version] is written as named, with
   a note saying so: the probe runs without the display variables a Firefox may
   need to print its version, so a refusal would turn away one that works. *)
let named_firefox ~request ~set =
  match request.firefox with
  | Some path when List.mem Firefox set && not (String.equal (String.trim path) path) ->
    (* The probe trims what it is given, so it would find a program the value
       written does not name. *)
    Error (Firefox_not_executable path)
  | Some path when List.mem Firefox set ->
    (match Browser_runtime_dependencies.probe path with
     | Browser_runtime_dependencies.Missing _ -> Error (Firefox_not_executable path)
     | Browser_runtime_dependencies.Started _ -> Ok None
     | Browser_runtime_dependencies.Failed { detail; _ } ->
       Ok
         (Some
            (Printf.sprintf
               "%s did not answer --version (%s), so it was written as named and is not \
                verified."
               path detail)))
  | Some _ | None -> Ok None

type profile_state =
  | Missing
  | Directory
  | Not_a_directory

(* A symbolic link that points nowhere is something at the path, not a
   directory to make there. *)
let profile_state profile =
  match Unix.lstat profile with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Missing
  | exception Unix.Unix_error (code, _, _) ->
    Error (Profile_not_created { path = profile; reason = Unix.error_message code })
  | _ ->
    (match Unix.stat profile with
     | { Unix.st_kind = Unix.S_DIR; _ } -> Ok Directory
     | { Unix.st_kind = Unix.(S_REG | S_CHR | S_BLK | S_LNK | S_FIFO | S_SOCK); _ }
     | (exception Unix.Unix_error _) -> Ok Not_a_directory)

(* The directory that would hold the new profile is the nearest one that
   exists, and a profile is made there only when it can be written. Asked at
   the plan, so a profile that cannot be made refuses before the host is
   installed. *)
let creatable profile =
  let rec nearest path =
    if Sys.file_exists path || String.equal (Filename.dirname path) path
    then path
    else nearest (Filename.dirname path)
  in
  let holder = nearest (Filename.dirname profile) in
  match
    if not (Sys.is_directory holder)
    then Error (holder ^ " is not a directory")
    else (
      match Unix.access holder [ Unix.W_OK; Unix.X_OK ] with
      | () -> Ok ()
      | exception Unix.Unix_error (code, _, _) ->
        Error (Printf.sprintf "%s is not writable: %s" holder (Unix.error_message code)))
  with
  | Ok () -> Ok ()
  | Error reason -> Error (Profile_not_created { path = profile; reason })

let profile_usable profile =
  let* state = profile_state profile in
  match state with
  | Directory -> Ok ()
  | Not_a_directory -> Error (Profile_not_a_directory profile)
  | Missing -> creatable profile

(* A connect to a loopback port nobody listens on is refused at once, and one
   somebody listens on answers at once. A bound of a second keeps a full accept
   queue from holding the command, and an answer this cannot read says
   nothing. *)
let port_answers_now port =
  let socket = Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> try Unix.close socket with Unix.Unix_error _ -> ())
    (fun () ->
       Unix.set_nonblock socket;
       match Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port)) with
       | () -> true
       | exception Unix.Unix_error ((Unix.EINPROGRESS | Unix.EWOULDBLOCK | Unix.EAGAIN), _, _) ->
         (match Unix.select [] [ socket ] [] 1.0 with
          | _, _ :: _, _ -> Option.is_none (Unix.getsockopt_error socket)
          | _, [], _ -> false)
       | exception Unix.Unix_error _ -> false)

type plan =
  { runtime_config_path : string
  ; revision : string
  ; existing : Browser_configuration.live_bidi option
  ; table : Browser_configuration.live_bidi
  ; set : key list
  ; change : change
  ; port_answers : bool
  ; firefox_note : string option
  }

let table plan = plan.table
let change plan = plan.change
let port_answers plan = plan.port_answers
let firefox_note plan = plan.firefox_note

let revision_of = Runtime_table_edit.revision_of_observation

let plan ~find_firefox (request : request) =
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
    let existing = configuration.Browser_configuration.live_bidi in
    let* table, set, change = decide ~find_firefox request existing in
    let* () = profile_usable table.profile in
    let* firefox_note =
      match set with
      | [] -> Ok None
      | set ->
        let* edited = edited ~existing ~table ~set text in
        let* note = named_firefox ~request ~set in
        let* () =
          Runtime.validate_config_text ~runtime_config_path:path edited
          |> Result.map_error (fun reason -> Configuration_refused reason)
        in
        Ok note
    in
    Ok
      { runtime_config_path = path
      ; revision = revision_of observation
      ; existing
      ; table
      ; set
      ; change
      ; port_answers = port_answers_now table.port
      ; firefox_note
      }

type applied = { profile_created : bool }

let ensure_profile profile =
  let* state = profile_state profile in
  match state with
  | Directory -> Ok false
  | Not_a_directory -> Error (Profile_not_a_directory profile)
  | Missing ->
    (match
       Fs_compat.mkdir_p (Filename.dirname profile);
       Unix.mkdir profile profile_mode
     with
     | () -> Ok true
     | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok false
     | exception Unix.Unix_error (code, _, _) ->
       Error (Profile_not_created { path = profile; reason = Unix.error_message code })
     | exception Sys_error reason -> Error (Profile_not_created { path = profile; reason }))

(* Under the configuration lock the text is the one on disk now: the revision
   the plan was made from is compared again, and what the edit produces is read
   back before it is committed. *)
let commit plan =
  match
    Runtime_table_edit.commit
      ~runtime_config_path:plan.runtime_config_path
      ~revision:plan.revision
      ~edit:(edited ~existing:plan.existing ~table:plan.table ~set:plan.set)
  with
  | Ok () -> Ok ()
  | Error Runtime_table_edit.Changed_meanwhile -> Error Configuration_changed
  | Error (Runtime_table_edit.Edit_refused error) -> Error error
  | Error (Runtime_table_edit.Not_written reason) -> Error (Not_written reason)

let apply plan =
  let* profile_created = ensure_profile plan.table.profile in
  let* () = match plan.set with [] -> Ok () | _ :: _ -> commit plan in
  Ok { profile_created }
