module Launcher = Masc.Browser_lane_launcher
module Setup = Masc.Browser_lane_setup
module Bidi_setup = Masc.Browser_lane_bidi_setup
module Automation_setup = Masc.Browser_lane_automation_setup
module Addon_setup = Masc.Browser_addon_setup

type mode = Addon | Extension | Bidi | Host | Automation

let all_modes = [ Addon; Extension; Bidi; Host; Automation ]

let mode_name = function
  | Addon -> "addon"
  | Extension -> "extension"
  | Bidi -> "bidi"
  | Host -> "host"
  | Automation -> "automation"

(* These modes install the native host and launcher assets. Automation uses
   the attached browser Add-on's geckodriver and needs neither asset. *)
let host_modes = [ Extension; Bidi; Host ]
let installs_host modes = List.exists (fun mode -> List.mem mode modes) host_modes

let refuse message =
  prerr_endline message;
  1

let ( let* ) = Result.bind

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
  (* Setup writes the table; an attached browser Add-on uses the loaded
     configuration only while the live lane is enabled. *)
  if not (Bidi_setup.lane_enabled plan)
  then
    print_endline
      "  [browser.live] enabled = false in runtime.toml keeps the live lane off, so the \
       browser Add-on starts no Firefox. Turn it on first.";
  print_endline
    "  1. Restart the MASC server to load runtime.toml. A browser Add-on that was attached \
     before keeps its old settings until it is detached; the server attaches its declaration \
     again on the next maintenance pass. The Add-on owns this Firefox and its BiDi \
     connection; its observation reports readiness or the startup refusal.";
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
       (Masc.Browser_bidi_host_status.observe ~base_path ~configuration))

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
  if not (Automation_setup.lane_enabled plan)
  then
    print_endline
      "  [browser.automation] enabled = false in runtime.toml keeps the lane off, so the \
       browser Add-on starts no geckodriver. Turn it on first.";
  print_endline
    "  Restart the MASC server to load the updated runtime.toml. A browser Add-on that was \
     attached before keeps its old settings until it is detached; the server attaches its \
     declaration again on the next maintenance pass. The attached Add-on owns this \
     geckodriver and stops it during detach. Each new automation session uses a fresh \
     profile; logins do not carry over to a new session.";
  print_endline
    "  A browser that needs a login is another route: --mode bidi or --mode extension."

(* Every route runs in the browser Add-on, so every mode declares it. *)
let print_addon (installed : Addon_setup.installed) =
  Printf.printf "Browser Add-on package  %s (%s)\n" installed.package_directory
    (match installed.files_written, installed.files_removed with
     | 0, [] -> "already this build's"
     | written, [] -> Printf.sprintf "%d files written" written
     | written, removed ->
       Printf.sprintf "%d files written, %d removed" written (List.length removed));
  List.iter (Printf.printf "  removed %s\n") installed.files_removed;
  (match installed.declaration with
   | Addon_setup.Created { path } ->
     Printf.printf "Declared the browser Add-on in %s\n" path;
     print_endline
       "The MASC server attaches it when it starts and on its maintenance pass; set \
        enabled = false there to keep it detached."
   | Addon_setup.Present { path; manifest_path = named; this_build; enabled } ->
     Printf.printf "The browser Add-on is declared in %s\n" path;
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

(* Whether this command runs the browser Add-on step, and what its refusal
   means. --mode addon requires it: a refusal is the command's. Every other
   mode offers it: a refusal is reported and that mode's own steps go on, so
   a Lane directory problem never stops a host refresh or a table write.
   --no-addon skips it. *)
type addon_choice = Require_addon | Offer_addon | Skip_addon

type 'a addon_step = Not_run | Reported of string | Done of 'a

let addon_refusal choice error =
  let message = Addon_setup.error_message error in
  match choice with
  | Require_addon -> Error message
  | Offer_addon | Skip_addon -> Ok (Reported message)

let print_addon_skipped message =
  prerr_endline ("The browser Add-on was not set up: " ^ message)

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
  =
  (* Every refusal of the modes' own steps comes before the first write. The
     browser Add-on step refuses what it can there too, and the rest after it
     wrote its package ({!Addon_setup.apply}); see [addon_refusal]. *)
  let planned =
    let* addon =
      match addon_choice with
      | Skip_addon -> Ok Not_run
      | Require_addon | Offer_addon ->
        (match Addon_setup.plan ~base_path with
         | Ok plan -> Ok (Done plan)
         | Error error -> addon_refusal addon_choice error)
    in
    let* extension = extension_route ~modes ~manifest_dir ~host_name in
    let* bidi = bidi_plan ~modes ~runtime_config_path ~firefox ~profile ~port in
    let* automation = automation_plan ~modes ~runtime_config_path ~geckodriver ~browser in
    Ok (addon, extension, bidi, automation)
  in
  match planned with
  | Error message -> refuse message
  | Ok (addon, extension, bidi, automation) ->
    (* Install the requested host assets, then the browser Add-on package and
       its declaration, before writing configuration tables. A later refusal
       retains those completed assets. Setup does not attach the browser
       Add-on or start its browsers. *)
    let installed =
      if installs_host modes
      then
        Setup.install { Setup.base_path; binary; token_file; extension }
        |> Result.map Option.some
        |> Result.map_error Setup.error_message
      else Ok None
    in
    let installed =
      Result.bind installed (fun installed ->
        let* addon =
          match addon with
          | Not_run -> Ok Not_run
          | Reported message -> Ok (Reported message)
          | Done plan ->
            (match Addon_setup.apply plan with
             | Ok applied -> Ok (Done applied)
             | Error error -> addon_refusal addon_choice error)
        in
        Ok (installed, addon))
    in
    (match installed with
     | Error message -> refuse message
     | Ok (installed, addon) ->
       Option.iter (print_installed ~base_path) installed;
       (match addon with
        | Not_run -> ()
        | Reported message -> print_addon_skipped message
        | Done applied ->
          if Option.is_some installed then print_endline "";
          print_addon applied);
       let tabled =
         match bidi with
         | None -> Ok None
         | Some plan ->
           Bidi_setup.apply plan
           |> Result.map (fun applied -> Some (plan, applied))
           |> Result.map_error Bidi_setup.error_message
       in
       (match tabled with
        | Error message -> refuse message
        | Ok tabled ->
          (* Both tables were planned against the same runtime.toml. The bidi
             table has been written since, so the automation plan would be
             refused as stale: it keeps its decisions and takes the revision of
             what the file holds now. Nothing is looked for or run again, and
             it is refused here only if that file no longer takes the edit. *)
          let automation =
            match bidi, automation with
            | Some _, Some plan ->
              Automation_setup.replan plan
              |> Result.map Option.some
              |> Result.map_error Automation_setup.error_message
            | None, _ | _, None -> Ok automation
          in
          (match
             Result.bind automation (fun plan ->
               match plan with
               | None -> Ok None
               | Some plan ->
                 Automation_setup.apply plan
                 |> Result.map (fun () -> Some plan)
                 |> Result.map_error Automation_setup.error_message)
           with
           | Error message -> refuse message
           | Ok automation ->
             Option.iter
               (fun (installed : Setup.installed) ->
                  Option.iter print_extension_steps installed.extension)
               installed;
             Option.iter
               (fun (plan, applied) ->
                  print_table ~runtime_config_path plan applied;
                  print_bidi_steps plan)
               tabled;
             Option.iter (print_automation ~runtime_config_path) automation;
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
             if Option.is_some tabled
             then (print_endline ""; print_bidi_state ~base_path ~runtime_config_path);
             0)))

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
      ; "--no-addon", no_addon, [ Extension; Bidi; Host; Automation ]
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
         ~browser)
