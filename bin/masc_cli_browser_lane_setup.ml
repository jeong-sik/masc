module Bidi_setup = Masc.Browser_lane_bidi_setup
module Addon_setup = Masc.Browser_addon_setup
module Ego_setup = Masc.Browser_lane_ego_setup
module Table_writes = Masc.Browser_lane_table_writes

type mode = Addon | Bidi | Ego

let all_modes = [ Addon; Bidi; Ego ]

let mode_name = function
  | Addon -> "addon"
  | Bidi -> "bidi"
  | Ego -> "ego"

let refuse_with status message =
  prerr_endline message;
  status

let refuse message = refuse_with 1 message

(* A workspace whose config root is not there yet: nothing in the request was
   wrong, and the first server start writes the root, so a run after it
   declares the Add-on. scripts/install-local-build.sh tells this status apart
   from a refusal. *)
let no_config_root_status = 3

open Result.Syntax

(* An option only some modes use. Naming one where no chosen mode uses it is
   refused: it would otherwise be accepted and do nothing. *)
let misplaced ~modes options =
  List.find_map
    (fun (flag, given, applies_to) ->
       if given && not (List.exists (fun mode -> List.mem mode modes) applies_to)
       then
         Some
           (Printf.sprintf "%s only applies with %s." flag
              (String.concat " or " (List.map (fun mode -> "--mode " ^ mode_name mode) applies_to)))
       else None)
    options

let bidi_plan ~modes ~store ~firefox ~profile ~port =
  if not (List.mem Bidi modes)
  then Ok None
  else
    Bidi_setup.plan
      ~find_firefox:Bidi_setup.installed_firefox
      { Bidi_setup.store
      ; home = Sys.getenv_opt "HOME"
      ; firefox
      ; profile
      ; port
      }
    |> Result.map Option.some
    |> Result.map_error Bidi_setup.error_message

let ego_plan ~modes ~store ~ego_command ~ego_space =
  if not (List.mem Ego modes)
  then Ok None
  else
    Ego_setup.plan
      ~find_ego:Ego_setup.installed_ego
      { Ego_setup.store; command = ego_command; space = ego_space }
    |> Result.map Option.some
    |> Result.map_error Ego_setup.error_message

let key_names keys = String.concat ", " (List.map Bidi_setup.key_name keys)

let print_table ~runtime_config_path plan (applied : Bidi_setup.applied) =
  let { Browser_configuration.firefox; profile; port } = Bidi_setup.table plan in
  print_endline "";
  (match Bidi_setup.change plan with
   | Bidi_setup.Created ->
     Printf.printf "Wrote [browser.live.bidi] to %s:\n" runtime_config_path
   | Bidi_setup.Updated keys ->
     Printf.printf "Changed %s in [browser.live.bidi] of %s:\n" (key_names keys)
       runtime_config_path
   | Bidi_setup.Unchanged ->
     Printf.printf
       "[browser.live.bidi] in %s was already there and is left as it is. To change a value, \
        name it with --firefox, --profile or --port:\n"
       runtime_config_path);
  Printf.printf "  firefox  %s\n" firefox;
  Printf.printf "  profile  %s%s\n" profile (if applied.profile_created then " (created)" else "");
  Printf.printf "  port     %d\n" port;
  Option.iter (Printf.printf "Note: %s\n") (Bidi_setup.firefox_note plan)

let print_bidi_steps plan =
  let { Browser_configuration.port; _ } = Bidi_setup.table plan in
  print_endline "";
  print_endline "Next, for the Firefox MASC starts:";
  print_endline
    "  1. Restart the MASC server to load runtime.toml. A browser Add-on that was attached \
     before keeps its old settings until it is detached; the server attaches its declaration \
     again on the next maintenance pass. While an enabled browser-firefox declaration runs \
     it, the Add-on owns this Firefox and its BiDi connection, and its observation reports \
     readiness or the startup refusal.";
  print_endline
    "  2. In that Firefox, log in once to the sites the Keepers work on. The profile keeps \
     the logins.";
  if Bidi_setup.port_answers plan
  then
    Printf.printf
      "Something already answers on 127.0.0.1:%d. Close the browser using that port before \
       attaching the Add-on. The Add-on starts its own Firefox and preserves the profile.\n"
      port;
  print_endline
    "Firefox's remote debugging port has no authentication: any program on this computer \
     can drive that browser and read its cookies. Keep this profile to the logins the \
     Keepers need."

let print_bidi_state ~base_path ~(store : Masc.Runtime_table_edit.store) =
  let configuration =
    match store.observe () with
    | Ok observation -> Result.to_option (Browser_configuration.of_text observation.Runtime.source_text)
    | Error (Masc.Runtime_table_edit.Missing _ | Masc.Runtime_table_edit.Unreadable _) -> None
  in
  print_endline
    (Masc.Browser_bidi_host_status.message
       (Masc.Browser_bidi_host_status.observe ~base_path ~configuration))

(* Without a mode nothing is written: this says who starts the live Firefox. *)
let show ~base_path ~store =
  Printf.printf "Browser lane for %s\n" base_path;
  print_bidi_state ~base_path ~store;
  0

let ego_key_names keys = String.concat ", " (List.map Ego_setup.key_name keys)

let print_ego ~runtime_config_path plan =
  let { Browser_configuration.command; space } = Ego_setup.table plan in
  print_endline "";
  (match Ego_setup.change plan with
   | Ego_setup.Created -> Printf.printf "Wrote [browser.live.ego] to %s:\n" runtime_config_path
   | Ego_setup.Updated keys ->
     Printf.printf "Changed %s in [browser.live.ego] of %s:\n" (ego_key_names keys) runtime_config_path
   | Ego_setup.Unchanged ->
     Printf.printf
       "[browser.live.ego] in %s was already there and is left as it is. To change a value, \
        name it with --ego-command or --ego-space:\n"
       runtime_config_path);
  Printf.printf "  command  %s\n" command;
  (match space with
   | Browser_configuration.Named_space name -> Printf.printf "  space    %s\n" name
   | Existing_space id -> Printf.printf "  space    #%d (existing ID)\n" id);
  Option.iter (fun (version, engine) -> Printf.printf "  answered ego lite %s, Chromium %s\n" version engine)
    (Ego_setup.versions plan);
  print_endline "";
  print_endline "Next, for the ego lite task space:";
  print_endline
    "  Restart the MASC server to load runtime.toml. A browser Add-on that was attached \
     before keeps its old settings until it is detached; the server attaches its declaration \
     again on the next maintenance pass. The Add-on then opens the task space and lists it as \
     ego lite among the live connections. Detaching stops the SDK session without finishing \
     the Space or discarding browser-backed files. Complete a successful task explicitly \
     with the finish_space browser action.";
  let reference=match space with
    | Browser_configuration.Named_space name -> Printf.sprintf "named %S" name
    | Existing_space id -> Printf.sprintf "with ID %d" id in
  Printf.printf
    "  If ego lite holds a task space %s that you opened yourself, the Add-on does not \
     start; name another with --ego-space.\n"
    reference;
  print_endline
    "Keepers act only on the pages the space opens, with the cookies of your ego lite \
     profile: they can read and post as you on the sites you are logged in to there."

(* Every route runs in a browser Add-on, one per source, so every mode
   declares the sources the workspace runs. *)
let print_addon (installed : Addon_setup.installed) =
  let source = Browser_lane.Backend.to_wire installed.backend in
  Printf.printf "Browser Add-on package (%s)  %s (%s)\n" source installed.package_directory
    (match installed.files_written, installed.files_removed with
     | 0, [] -> "already this build's"
     | written, [] -> Printf.sprintf "%d files written" written
     | written, removed ->
       Printf.sprintf "%d files written, %d removed" written (List.length removed));
  List.iter (Printf.printf "  removed %s\n") installed.files_removed;
  (match installed.declaration with
   | Addon_setup.Created { path } ->
     Printf.printf "Declared the %s browser Add-on in %s\n" source path
   | Addon_setup.Present { path; manifest_path = named; this_build; enabled } ->
     Printf.printf "The %s browser Add-on is declared in %s\n" source path;
     if not this_build
     then
       Printf.printf
         "It names the package %s, not the one this masc carries, and is left as it is. To \
          use this build's package, write %s there.\n"
         named
         (Toml_line_editor.scalar_line ~key:"manifest_path" ~value:installed.manifest_path);
     if not enabled then print_endline "Its enabled = false keeps it detached.");
  match installed.missing_programs with
  | [] -> ()
  | missing ->
    Printf.printf
      "Not found beside masc or on PATH: %s. scripts/install-local-build.sh installs them \
       beside masc; the server looks for them the same way.\n"
      (String.concat ", " missing)

let print_addons (installed : Addon_setup.installed list) =
  match installed with
  | [] ->
    print_endline
      "No browser source runs here: runtime.toml has no browser table. No browser Add-on was \
       declared."
  | _ :: _ ->
    List.iter print_addon installed;
    if List.exists (fun (one : Addon_setup.installed) ->
        match one.declaration with Addon_setup.Created _ -> true | Addon_setup.Present _ -> false) installed
    then print_endline
        "The MASC server attaches a declared Add-on when it starts and on its maintenance pass; \
         set enabled = false in its declaration to keep it detached."

(* Whether this command runs the browser Add-on step, and what its refusal
   means. --mode addon requires it: a refusal is the command's. Every other
   mode offers it: a refusal is reported and that mode's own steps go on, so
   a Lane directory problem never stops a host refresh or a table write.
   --no-addon skips it. *)
type addon_choice = Require_addon | Offer_addon | Skip_addon

type 'a addon_step = Not_run | Reported of string | Done of 'a

let step_refusal choice message =
  match choice with
  | Require_addon -> Error message
  | Offer_addon | Skip_addon -> Ok (Reported message)

let addon_refusal choice error = step_refusal choice (Addon_setup.error_message error)

let addon_plan_status : Addon_setup.error -> int = function
  | Addon_setup.Config_root_missing _ -> no_config_root_status
  | Addon_setup.Base_path_not_absolute _
  | Addon_setup.Embedded_package_invalid _
  | Addon_setup.Package_unwritable _
  | Addon_setup.Package_unloadable _
  | Addon_setup.Config_root_invalid _
  | Addon_setup.Inventory_unreadable _
  | Addon_setup.Declared_more_than_once _
  | Addon_setup.Declaration_unloadable _
  | Addon_setup.Declaration_refused _ -> 1

(* The browser sources this workspace runs, one package each: a source
   whose table runtime.toml has or this run writes. Whether a source runs is
   its declaration's enabled. The second list holds the sources that run
   only once this run writes their table. *)
let addon_sources ~(configuration : Browser_configuration.t) ~modes =
  let table_present : Browser_lane.Backend.t -> bool = function
    | Owned_firefox -> Option.is_some configuration.live_bidi
    | Ego -> Option.is_some configuration.live_ego in
  let written_here : Browser_lane.Backend.t -> bool = function
    | Owned_firefox -> List.mem Bidi modes
    | Ego -> List.mem Ego modes in
  let sources = List.filter (fun backend -> table_present backend || written_here backend)
      Browser_lane.Backend.all in
  sources, List.filter (fun backend -> written_here backend && not (table_present backend)) sources

(* No runtime.toml configures no source. Which sources one that does not
   parse runs is not known. *)
let runtime_browser_configuration (store : Masc.Runtime_table_edit.store) =
  let unknown detail =
    Printf.sprintf "%s does not parse, so which browser sources it runs is not known: %s"
      store.path detail
  in
  match store.observe () with
  | Error (Masc.Runtime_table_edit.Missing _) -> Ok Browser_configuration.none
  | Error (Masc.Runtime_table_edit.Unreadable { reason; _ }) -> Error (unknown reason)
  | Ok observation ->
    Browser_configuration.of_text observation.Runtime.source_text |> Result.map_error unknown

let plan_addon ~base_path ~store ~modes choice =
  match choice with
  | Skip_addon -> Ok Not_run
  | Require_addon | Offer_addon ->
    (match runtime_browser_configuration store with
     | Error message -> step_refusal choice message |> Result.map_error (fun message -> 1, message)
     | Ok configuration ->
       let sources, awaiting = addon_sources ~configuration ~modes in
       (match Addon_setup.plan ~base_path ~sources with
        | Ok plan -> Ok (Done (plan, awaiting))
        | Error error ->
          addon_refusal choice error
          |> Result.map_error (fun message -> addon_plan_status error, message)))

let print_addon_skipped message =
  prerr_endline ("The browser Add-on step stopped: " ^ message)

let install
      ~base_path
      ~(store : Masc.Runtime_table_edit.store)
      ~modes
      ~addon_choice
      ~firefox
      ~profile
      ~port
      ~ego_command
      ~ego_space
  =
  (* Every refusal of the modes' own steps comes before the first write. The
     browser Add-on step refuses what it can there too, and the rest after it
     wrote a package ({!Addon_setup.apply}); see [addon_refusal]. *)
  let planned =
    let refused result = Result.map_error (fun message -> 1, message) result in
    let* addon = plan_addon ~base_path ~store ~modes addon_choice in
    let* bidi = refused (bidi_plan ~modes ~store ~firefox ~profile ~port) in
    let* ego = refused (ego_plan ~modes ~store ~ego_command ~ego_space) in
    Ok (addon, bidi, ego)
  in
  match planned with
  | Error (status, message) -> refuse_with status message
  | Ok (addon, bidi, ego) ->
    (* Write the configuration tables, then each browser source's package and
       declaration. A source whose table this run writes is declared only once
       that table is written, since its worker fails without it. A later
       refusal retains what was completed before it. Setup does not attach the
       browser Add-ons or start their browsers.

       The tables are committed one after another. A refusal leaves the ones
       before it written, so they are printed with their next steps before the
       refusal, and a run of the same command keeps them. A table planned
       against the file before an earlier table was written is planned again
       against the file as it is now: nothing is looked for or run again, and
       it is refused only if that file no longer takes the edit or the same
       table changed meanwhile. *)
    let bidi_step =
      Option.map
        (fun plan () ->
           Bidi_setup.apply plan
           |> Result.map (fun applied -> plan, applied)
           |> Result.map_error Bidi_setup.error_message)
        bidi
    in
    let ego_step =
      Option.map
        (fun plan ~after_write ->
           (let* plan = if after_write then Ego_setup.replan plan else Ok plan in
            Ego_setup.apply plan |> Result.map (fun () -> plan))
           |> Result.map_error Ego_setup.error_message)
        ego
    in
    let { Table_writes.written; refusal } =
      Table_writes.write ~bidi:bidi_step ~ego:ego_step
    in
    Option.iter
      (fun (plan, applied) ->
         print_table ~runtime_config_path:store.path plan applied;
         print_bidi_steps plan)
      written.bidi;
    Option.iter (print_ego ~runtime_config_path:store.path) written.ego;
    (* A source whose table this run was to write and did not is left out.
       The others are declared even after a table refusal, since their
       workers do not start from that table. *)
    let table_written : Browser_lane.Backend.t -> bool = function
      | Owned_firefox -> Option.is_some written.bidi
      | Ego -> Option.is_some written.ego
    in
    let addon =
      match addon with
      | Not_run -> Ok ()
      | Reported message -> Ok (print_addon_skipped message)
      | Done (plan, awaiting) ->
        let unwritten = List.filter (fun backend -> not (table_written backend)) awaiting in
        let { Addon_setup.installed = applied; refusal = stopped } =
          Addon_setup.apply (Addon_setup.without unwritten plan)
        in
        print_endline "";
        (match applied, stopped, unwritten with
         | [], Some _, ([] | _ :: _) | [], None, _ :: _ -> ()
         | [], None, [] | _ :: _, (None | Some _), ([] | _ :: _) -> print_addons applied);
        (match unwritten with
         | [] -> ()
         | _ :: _ ->
           Printf.printf "Not declared, since its table was not written: %s\n"
             (String.concat ", " (List.map Browser_lane.Backend.to_wire unwritten)));
        (match stopped with
         | None -> Ok ()
         | Some error ->
           addon_refusal addon_choice error
           |> Result.map (function
             | Reported message -> print_addon_skipped message
             | Not_run | Done _ -> ()))
    in
    (match refusal, addon with
     | Some message, Ok () -> refuse message
     | Some message, Error addon_message ->
       prerr_endline addon_message;
       refuse message
     | None, Error message -> refuse message
     | None, Ok () ->
       if Option.is_some written.bidi
       then (print_endline ""; print_bidi_state ~base_path ~store);
       0)

(* The modes that write a table of runtime.toml. *)
let writes_a_table = function
  | Bidi | Ego -> true
  | Addon -> false

let run
      ~base_path
      ~runtime_config_path
      ~server_port
      ~agent
      ~agent_named
      ~modes:requested
      ~no_addon
      ~firefox
      ~profile
      ~port
      ~ego_command
      ~ego_space
  =
  let modes = List.filter (fun mode -> List.mem mode requested) all_modes in
  match
    misplaced
      ~modes
      [ "--firefox", Option.is_some firefox, [ Bidi ]
      ; "--profile", Option.is_some profile, [ Bidi ]
      ; "--port", Option.is_some port, [ Bidi ]
      ; "--ego-command", Option.is_some ego_command, [ Ego ]
      ; "--ego-space", Option.is_some ego_space, [ Ego ]
      ; "--no-addon", no_addon, [ Bidi; Ego ]
      ; "--agent", agent_named, [ Bidi; Ego ]
      ]
  with
  | Some message -> refuse message
  | None ->
    (match modes with
     | [] -> show ~base_path ~store:(Masc.Runtime_table_edit.file_store ~runtime_config_path)
     | _ :: _ when List.mem Addon modes && no_addon ->
       refuse "--no-addon contradicts --mode addon."
     | _ :: _ ->
       let install_with store =
         install
           ~base_path
           ~store
           ~modes
           ~addon_choice:
             (if List.mem Addon modes then Require_addon
              else if no_addon then Skip_addon
              else Offer_addon)
           ~firefox
           ~profile
           ~port
           ~ego_command
           ~ego_space
       in
       let file = Masc.Runtime_table_edit.file_store ~runtime_config_path in
       if not (List.exists writes_a_table modes)
       then install_with file
       else
         (* RFC-0482 §3.2: while this workspace's server answers, it is the
            writer. The tables are planned against the text it holds and
            committed through its text route; with no server answering, the
            command reads and writes the file itself. *)
         (match server_port with
          | Error message -> refuse message
          | Ok server_port ->
            (match Unix.realpath base_path with
             | exception Unix.Unix_error _ -> install_with file
             | real_base_path ->
            let routed =
              Masc_cli_runtime_config_remote.with_client (fun ~clock ->
                match
                  Masc_cli_runtime_config_remote.find ~clock ~base_path:real_base_path
                    ~port:server_port ~agent
                with
                | Error message -> `Refused message
                | Ok Masc_cli_runtime_config_remote.No_server -> `Local
                | Ok (Masc_cli_runtime_config_remote.Running_server server) ->
                  (match Masc_cli_runtime_config_remote.table_store ~clock server with
                   | Error message -> `Refused message
                   | Ok store -> `Installed (install_with store)))
            in
            (match routed with
             | `Refused message -> refuse message
             | `Local -> install_with file
             | `Installed code -> code))))
