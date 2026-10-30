module Launcher = Masc.Browser_lane_launcher
module Setup = Masc.Browser_lane_setup
module Bidi_setup = Masc.Browser_lane_bidi_setup
module Automation_setup = Masc.Browser_lane_automation_setup
module Addon_setup = Masc.Browser_addon_setup
module Ego_setup = Masc.Browser_lane_ego_setup
module Table_writes = Masc.Browser_lane_table_writes

type mode = Addon | Extension | Bidi | Ego | Host | Automation

let all_modes = [ Addon; Extension; Bidi; Ego; Host; Automation ]

let mode_name = function
  | Addon -> "addon"
  | Extension -> "extension"
  | Bidi -> "bidi"
  | Ego -> "ego"
  | Host -> "host"
  | Automation -> "automation"

(* These modes install the native host and launcher assets. Automation uses
   the attached browser Add-on's geckodriver and needs neither asset. *)
let host_modes = [ Extension; Bidi; Host ]
let installs_host modes = List.exists (fun mode -> List.mem mode modes) host_modes

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

let observation ~base_path = Launcher.observe ~base_path ~server:Launcher.Not_serving

(* What the lane says is left to do. It names this command whenever the lane is
   not installed. *)
let print_lane_state ~base_path = print_endline (Launcher.message (observation ~base_path))

let show ~base_path =
  Printf.printf "Browser lane for %s\n" base_path;
  print_lane_state ~base_path;
  0

let manifest_directory ~manifest_dir =
  match manifest_dir with
  | Some directory -> Ok directory
  | None ->
    (match Sys.getenv_opt "HOME", Setup.current_platform () with
     | (None | Some ""), _ ->
       Error "HOME is not set, so Firefox's manifest directory is unknown. Name it with --manifest-dir."
     | Some _, None ->
       Error
         "This installer supports macOS and Linux. Name Firefox's native messaging \
          directory with --manifest-dir."
     | Some home, Some platform -> Ok (Setup.default_manifest_directory ~home platform))

let host_name = function
  | None -> Ok Setup.Host_name.default
  | Some name ->
    Setup.Host_name.of_string name |> Result.map_error (fun message -> "--host-name: " ^ message)

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

let extension_route ~modes ~manifest_dir ~host_name:requested =
  if not (List.mem Extension modes)
  then Ok None
  else
    let* host_name = host_name requested in
    let* manifest_dir = manifest_directory ~manifest_dir in
    Ok (Some { Setup.manifest_dir; host_name })

let bidi_plan ~modes ~runtime_config_path ~firefox ~profile ~port =
  if not (List.mem Bidi modes)
  then Ok None
  else
    Bidi_setup.plan
      ~find_firefox:Bidi_setup.installed_firefox
      { Bidi_setup.runtime_config_path
      ; home = Sys.getenv_opt "HOME"
      ; firefox
      ; profile
      ; port
      }
    |> Result.map Option.some
    |> Result.map_error Bidi_setup.error_message

let automation_plan ~modes ~runtime_config_path ~geckodriver ~browser =
  if not (List.mem Automation modes)
  then Ok None
  else
    Automation_setup.plan
      ~find_geckodriver:Automation_setup.installed_geckodriver
      { Automation_setup.runtime_config_path; geckodriver; browser }
    |> Result.map Option.some
    |> Result.map_error Automation_setup.error_message

let ego_plan ~modes ~runtime_config_path ~ego_command ~ego_space =
  if not (List.mem Ego modes)
  then Ok None
  else
    Ego_setup.plan
      ~find_ego:Ego_setup.installed_ego
      { Ego_setup.runtime_config_path; command = ego_command; space = ego_space }
    |> Result.map Option.some
    |> Result.map_error Ego_setup.error_message

let print_installed ~base_path (installed : Setup.installed) =
  Printf.printf "Installed the browser lane host for %s\n" base_path;
  Printf.printf "  host        %s (copied from %s)\n" installed.host installed.host_source;
  Printf.printf "  launcher    %s\n" installed.launcher;
  Option.iter
    (fun (extension : Setup.extension_installed) ->
       Printf.printf "  manifest    %s\n" extension.native_manifest;
       Printf.printf "  extension   %s\n" extension.directory)
    installed.extension;
  Printf.printf "  lane token  %s\n" installed.token

let print_extension_steps (extension : Setup.extension_installed) =
  print_endline "";
  print_endline "Next, in Firefox:";
  print_endline "  1. Open about:debugging#/runtime/this-firefox";
  print_endline "  2. Choose \"Load Temporary Add-on...\"";
  Printf.printf "  3. Select %s\n" extension.load;
  print_endline
    "Firefox forgets a temporary add-on when it quits, so load it again after you restart \
     Firefox."

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

let print_bidi_state ~base_path ~runtime_config_path =
  let configuration = Result.to_option (Browser_configuration.of_file runtime_config_path) in
  print_endline
    (Masc.Browser_bidi_host_status.message
       (Masc.Browser_bidi_host_status.observe ~access:Masc.Lane_addon_sources.Operator_configuration
          ~base_path ~configuration))

let automation_key_names keys = String.concat ", " (List.map Automation_setup.key_name keys)

let print_automation ~runtime_config_path plan =
  let { Browser_configuration.driver; binary } = Automation_setup.table plan in
  let where =
    match Automation_setup.location plan with
    | Automation_setup.New_table | Automation_setup.Automation_table -> "[browser.automation]"
    | Automation_setup.Browser_table -> "[browser]"
  in
  print_endline "";
  (match Automation_setup.change plan with
   | Automation_setup.Created -> Printf.printf "Wrote %s to %s:\n" where runtime_config_path
   | Automation_setup.Updated keys ->
     Printf.printf "Changed %s in %s of %s:\n" (automation_key_names keys) where
       runtime_config_path
   | Automation_setup.Unchanged ->
     Printf.printf
       "%s in %s was already there and is left as it is. To change a value, name it with \
        --geckodriver or --browser:\n"
       where runtime_config_path);
  Printf.printf "  geckodriver  %s\n" driver;
  Printf.printf "  browser      %s\n"
    (match binary with
     | Some path -> path
     | None -> "(geckodriver finds it)");
  List.iter (Printf.printf "Note: %s\n") (Automation_setup.notes plan);
  print_endline "";
  print_endline "Next, for the automation lane:";
  print_endline
    "  Restart the MASC server to load the updated runtime.toml. A browser Add-on that was \
     attached before keeps its old settings until it is detached; the server attaches its \
     declaration again on the next maintenance pass. The attached Add-on owns this \
     geckodriver and stops it during detach. Each new automation session uses a fresh \
     profile; logins do not carry over to a new session.";
  print_endline
    "  A browser that needs a login is another route: --mode bidi or --mode extension."

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
      "No browser source runs here: runtime.toml has no browser table, and no native host is \
       installed. No browser Add-on was declared."
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
   whose table runtime.toml has or this run writes, and the external hosts
   when this run installs a host or one is installed. Whether a source runs
   is its declaration's enabled. The second list holds the sources that run
   only once this run writes their table. *)
let addon_sources ~base_path ~(configuration : Browser_configuration.t) ~modes =
  let host_installed = match (observation ~base_path).Launcher.launcher with
    | Launcher.Follows_workspace -> true
    | Launcher.Not_installed | Launcher.Undeclared | Launcher.Unreadable
    | Launcher.Describes_another_launcher -> false in
  let table_present : Browser_lane.Backend.t -> bool = function
    | Automation -> Option.is_some configuration.automation
    | Stagehand -> Option.is_some configuration.stagehand
    | Owned_firefox -> Option.is_some configuration.live_bidi
    | Ego -> Option.is_some configuration.live_ego
    | External_host -> false in
  let written_here : Browser_lane.Backend.t -> bool = function
    | Automation -> List.mem Automation modes
    | Owned_firefox -> List.mem Bidi modes
    | Ego -> List.mem Ego modes
    | Stagehand | External_host -> false in
  let sources = List.filter (fun (backend : Browser_lane.Backend.t) -> match backend with
      | External_host -> installs_host modes || host_installed
      | Automation | Stagehand | Owned_firefox | Ego -> table_present backend || written_here backend)
      Browser_lane.Backend.all in
  sources, List.filter (fun backend -> written_here backend && not (table_present backend)) sources

(* No runtime.toml configures no source. Which sources one that does not
   parse runs is not known. *)
let runtime_browser_configuration runtime_config_path =
  if not (Sys.file_exists runtime_config_path) then Ok Browser_configuration.none
  else
    Browser_configuration.of_file runtime_config_path
    |> Result.map_error (fun detail ->
      Printf.sprintf "%s does not parse, so which browser sources it runs is not known: %s"
        runtime_config_path detail)

let plan_addon ~base_path ~runtime_config_path ~modes choice =
  match choice with
  | Skip_addon -> Ok Not_run
  | Require_addon | Offer_addon ->
    (match runtime_browser_configuration runtime_config_path with
     | Error message -> step_refusal choice message |> Result.map_error (fun message -> 1, message)
     | Ok configuration ->
       let sources, awaiting = addon_sources ~base_path ~configuration ~modes in
       (match Addon_setup.plan ~base_path ~sources with
        | Ok plan -> Ok (Done (plan, awaiting))
        | Error error ->
          addon_refusal choice error
          |> Result.map_error (fun message -> addon_plan_status error, message)))

let print_addon_skipped message =
  prerr_endline ("The browser Add-on step stopped: " ^ message)

let print_host_only =
  "--mode host connects no browser: it installs the native host and launcher for a browser \
   you attach yourself. --mode extension installs the files to load the MASC extension \
   in Firefox. --mode bidi configures the Firefox owned by an attached browser Lane Add-on."

let print_both_routes =
  "Each connected route has its own clientId and capabilities. Discover them before use, \
   then keep the selected clientId for tab and document work; an explicit connection never \
   switches to another browser."

let install
      ~base_path
      ~runtime_config_path
      ~modes
      ~addon_choice
      ~binary
      ~token_file
      ~manifest_dir
      ~host_name
      ~firefox
      ~profile
      ~port
      ~geckodriver
      ~browser
      ~ego_command
      ~ego_space
  =
  (* Every refusal of the modes' own steps comes before the first write. The
     browser Add-on step refuses what it can there too, and the rest after it
     wrote a package ({!Addon_setup.apply}); see [addon_refusal]. *)
  let planned =
    let refused result = Result.map_error (fun message -> 1, message) result in
    let* addon = plan_addon ~base_path ~runtime_config_path ~modes addon_choice in
    let* extension = refused (extension_route ~modes ~manifest_dir ~host_name) in
    let* bidi = refused (bidi_plan ~modes ~runtime_config_path ~firefox ~profile ~port) in
    let* automation =
      refused (automation_plan ~modes ~runtime_config_path ~geckodriver ~browser)
    in
    let* ego = refused (ego_plan ~modes ~runtime_config_path ~ego_command ~ego_space) in
    Ok (addon, extension, bidi, automation, ego)
  in
  match planned with
  | Error (status, message) -> refuse_with status message
  | Ok (addon, extension, bidi, automation, ego) ->
    (* Install the requested host assets, then write the configuration
       tables, then each browser source's package and declaration. A source
       whose table this run writes is declared only once that table is
       written, since its worker fails without it. A later refusal retains
       what was completed before it. Setup does not attach the browser
       Add-ons or start their browsers. *)
    let installed =
      if installs_host modes
      then
        Setup.install { Setup.base_path; binary; token_file; extension }
        |> Result.map Option.some
        |> Result.map_error Setup.error_message
      else Ok None
    in
    (match installed with
     | Error message -> refuse message
     | Ok installed ->
       Option.iter (print_installed ~base_path) installed;
       (* The tables are committed one after another. A refusal leaves the
          ones before it written, so they are printed with their next steps
          before the refusal, and a run of the same command keeps them. A
          table planned against the file before an earlier table was written
          is planned again against the file as it is now: nothing is looked
          for or run again, and it is refused only if that file no longer
          takes the edit or the same table changed meanwhile. *)
       let bidi_step =
         Option.map
           (fun plan () ->
              Bidi_setup.apply plan
              |> Result.map (fun applied -> plan, applied)
              |> Result.map_error Bidi_setup.error_message)
           bidi
       in
       let automation_step =
         Option.map
           (fun plan ~after_write ->
              (let* plan = if after_write then Automation_setup.replan plan else Ok plan in
               Automation_setup.apply plan |> Result.map (fun () -> plan))
              |> Result.map_error Automation_setup.error_message)
           automation
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
         Table_writes.write ~bidi:bidi_step ~automation:automation_step ~ego:ego_step
       in
       Option.iter
         (fun (installed : Setup.installed) -> Option.iter print_extension_steps installed.extension)
         installed;
       Option.iter
         (fun (plan, applied) ->
            print_table ~runtime_config_path plan applied;
            print_bidi_steps plan)
         written.bidi;
       Option.iter (print_automation ~runtime_config_path) written.automation;
       Option.iter (print_ego ~runtime_config_path) written.ego;
       (* A source whose table this run was to write and did not is left out.
          The others are declared even after a table refusal, since their
          workers do not start from that table. *)
       let table_written : Browser_lane.Backend.t -> bool = function
         | Automation -> Option.is_some written.automation
         | Owned_firefox -> Option.is_some written.bidi
         | Ego -> Option.is_some written.ego
         | Stagehand | External_host -> false
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
          if modes = [ Host ] then (print_endline ""; print_endline print_host_only);
          if List.mem Extension modes && List.mem Bidi modes
          then (print_endline ""; print_endline print_both_routes);
          let extension_written =
            match installed with
            | Some { Setup.extension = Some _; _ } -> true
            | Some { Setup.extension = None; _ } | None -> false
          in
          if extension_written || List.mem Host modes
          then (print_endline ""; print_lane_state ~base_path);
          if Option.is_some written.bidi
          then (print_endline ""; print_bidi_state ~base_path ~runtime_config_path);
          0))

let run
      ~base_path
      ~runtime_config_path
      ~modes:requested
      ~no_addon
      ~binary
      ~token_file
      ~manifest_dir
      ~host_name
      ~firefox
      ~profile
      ~port
      ~geckodriver
      ~browser
      ~ego_command
      ~ego_space
  =
  let modes = List.filter (fun mode -> List.mem mode requested) all_modes in
  match
    misplaced
      ~modes
      [ "--binary", Option.is_some binary, host_modes
      ; "--token-file", Option.is_some token_file, host_modes
      ; "--manifest-dir", Option.is_some manifest_dir, [ Extension ]
      ; "--host-name", Option.is_some host_name, [ Extension ]
      ; "--firefox", Option.is_some firefox, [ Bidi ]
      ; "--profile", Option.is_some profile, [ Bidi ]
      ; "--port", Option.is_some port, [ Bidi ]
      ; "--geckodriver", Option.is_some geckodriver, [ Automation ]
      ; "--browser", Option.is_some browser, [ Automation ]
      ; "--ego-command", Option.is_some ego_command, [ Ego ]
      ; "--ego-space", Option.is_some ego_space, [ Ego ]
      ; "--no-addon", no_addon, [ Extension; Bidi; Ego; Host; Automation ]
      ]
  with
  | Some message -> refuse message
  | None ->
    (match modes with
     | [] -> show ~base_path
     | _ :: _ when List.mem Addon modes && no_addon ->
       refuse "--no-addon contradicts --mode addon."
     | _ :: _ ->
       install
         ~base_path
         ~runtime_config_path
         ~modes
         ~addon_choice:
           (if List.mem Addon modes then Require_addon
            else if no_addon then Skip_addon
            else Offer_addon)
         ~binary
         ~token_file
         ~manifest_dir
         ~host_name
         ~firefox
         ~profile
         ~port
         ~geckodriver
         ~browser
         ~ego_command
         ~ego_space)
