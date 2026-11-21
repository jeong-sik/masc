open Alcotest
open Masc
module Setup = Exact_addon_setup
module Carried = Lane_addon_carried

let write path bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let read path = In_channel.with_open_bin path In_channel.input_all
let state_variable = "MASC_TEST_DOCKER_STATE"

(* A Docker stand-in. [build] records the label it was given, under the
   tag, and the names of the files in its context; [image inspect] answers
   that label as Docker prints labels, or fails as for an absent image. Every
   call is logged. *)
let fake_docker = Printf.sprintf {|#!/bin/sh
state="$%s"
printf '%%s\n' "$1" >> "$state/calls"
key() { printf '%%s' "$1" | tr '/:' '__'; }
case "$1" in
  image)
    file="$state/$(key "$5")"
    [ -f "$file" ] || exit 1
    pair="$(cat "$file")"
    printf '{"%%s":"%%s"}\n' "${pair%%%%=*}" "${pair#*=}"
    ;;
  build)
    file="$state/$(key "$6")"
    printf '%%s' "$4" > "$file"
    ls "$7" > "$file.context"
    ;;
  *) exit 2 ;;
esac
|} state_variable

let state_key image = String.map (function '/' | ':' -> '_' | c -> c) image

let with_workspace f =
  let root = Filename.temp_dir "exact-addon-setup-" "" in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
    let state = Filename.concat root "docker-state" in
    Unix.mkdir state 0o700;
    let docker = Filename.concat root "docker" in
    write docker fake_docker;
    Unix.chmod docker 0o755;
    Unix.putenv state_variable state;
    f ~base_path:root ~docker ~state)

let reports ~base_path ~docker =
  match Setup.run ~base_path ~docker ~scope:Setup.Every_carried with
  | Ok outcome -> outcome.Setup.reports
  | Error error -> fail (Setup.error_message error)

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect ~finally:(fun () -> match previous with
    | Some value -> Unix.putenv name value | None -> Unix.unsetenv name) f

let installed (report : Setup.report) =
  match report.result with
  | Ok installed -> installed
  | Error _ -> fail (Setup.report_line report)

let builds state =
  read (Filename.concat state "calls") |> String.split_on_char '\n'
  |> List.filter (String.equal "build") |> List.length

let installs_every_package_once () = with_workspace (fun ~base_path ~docker ~state ->
  let first = reports ~base_path ~docker in
  check (list string) "one report per carried package, in order"
    (List.map Carried.name Carried.all) (List.map (fun (r : Setup.report) -> Carried.name r.package) first);
  let packages = Config_dir_resolver.packages_dir ~base_path in
  List.iter (fun (report : Setup.report) ->
      let name = Carried.name report.package in
      let done_ = installed report in
      check bool (name ^ " folder is written") true (done_.folder = Carried.Written);
      check bool (name ^ " image is built") true (done_.image_outcome = Setup.Built);
      check bool (name ^ " is the folder a declaration reads") true
        (Carried.installed_manifest ~packages report.package = Ok done_.manifest_path);
      let recorded = Filename.concat state (state_key done_.image) in
      check string (name ^ " image is labelled with its inputs")
        (Carried.image_label ^ "=" ^ Carried.image_digest report.package) (read recorded);
      check (list string) (name ^ " context holds exactly the image inputs")
        (List.map (fun (file : Carried.file) -> file.path) (Carried.image_inputs report.package))
        (read (recorded ^ ".context") |> String.split_on_char '\n' |> List.filter (( <> ) "")))
    first;
  check int "every package was built once" (List.length Carried.all) (builds state);
  List.iter (fun (report : Setup.report) ->
      let name = Carried.name report.package in
      let done_ = installed report in
      check bool (name ^ " folder is already installed") true (done_.folder = Carried.Already_installed);
      check bool (name ^ " image is already built") true (done_.image_outcome = Setup.Already_built))
    (reports ~base_path ~docker);
  check int "a second run builds nothing" (List.length Carried.all) (builds state))

let a_changed_folder_is_left_as_it_is () = with_workspace (fun ~base_path ~docker ~state:_ ->
  ignore (reports ~base_path ~docker);
  let packages = Config_dir_resolver.packages_dir ~base_path in
  let folder = match Carried.folder ~packages Carried.Hitl_auto_judge with
    | Ok folder -> folder | Error message -> fail message in
  let server = Filename.concat folder "server.py" in
  let changed = "# another worker\n" in
  write server changed;
  List.iter (fun (report : Setup.report) ->
      match report.package, report.result with
      | Carried.Hitl_auto_judge, Error (Setup.Folder (Carried.Folder_differs { detail; _ })) ->
          check string "the difference is named" "server.py has other bytes" detail
      | Carried.Hitl_auto_judge, (Ok _ | Error _) -> fail (Setup.report_line report)
      | (Carried.Workspace_curator | Carried.Candle_appraiser), _ ->
          ignore (installed report))
    (reports ~base_path ~docker);
  check string "the folder is not rewritten" changed (read server))

let without_docker_the_folders_are_still_written () = with_workspace (fun ~base_path ~docker:_ ~state:_ ->
  let packages = Config_dir_resolver.packages_dir ~base_path in
  List.iter (fun (report : Setup.report) ->
      let name = Carried.name report.package in
      (match report.result with
       | Error (Setup.Image_not_built _) -> ()
       | Ok _ | Error (Setup.Folder _ | Setup.Manifest_unloadable _) -> fail (Setup.report_line report));
      check bool (name ^ " folder is written") true
        (Result.is_ok (Carried.installed_manifest ~packages report.package)))
    (reports ~base_path ~docker:(Filename.concat base_path "no-docker-here")))

let declared_installs_only_what_the_declarations_name () =
  with_workspace (fun ~base_path ~docker ~state:_ ->
  let config_root = Filename.concat base_path "configuration" in
  let directory = Lane_addon_config.directory ~config_root in
  Fs_compat.mkdir_p directory;
  let declare file keys =
    write (Filename.concat directory file)
      (Printf.sprintf "id = %S\nrun_id = \"memory\"\n%s[binding]\nsources = []\n" file keys) in
  declare "judge.toml" "package = \"hitl-auto-judge\"\n";
  declare "placed.toml" "manifest_path = \"../elsewhere/lane.toml\"\n";
  declare "broken.toml" "package = 1\n";
  with_env "MASC_CONFIG_DIR" config_root (fun () ->
    match Setup.run ~base_path ~docker ~scope:Setup.Declared with
    | Error error -> fail (Setup.error_message error)
    | Ok { Setup.reports; unread } ->
        check (list string) "only the carried package a declaration names"
          [Carried.name Carried.Hitl_auto_judge]
          (List.map (fun (report : Setup.report) -> Carried.name report.package) reports);
        List.iter (fun report -> ignore (installed report)) reports;
        check (list string) "a declaration whose package choice does not read is named"
          [Filename.concat directory "broken.toml"]
          (List.map (fun (issue : Lane_addon_config.issue) -> issue.source_path) unread)))

let a_relative_base_path_is_refused () =
  match Setup.run ~base_path:"relative/workspace" ~docker:"docker" ~scope:Setup.Every_carried with
  | Error (Setup.Base_path_not_absolute _) -> ()
  | Error (Setup.Config_root_invalid _) | Ok _ -> fail "a relative base path was used"

let () =
  run "Exact_addon_setup"
    [ ( "setup",
        [ test_case "installs every package once" `Quick installs_every_package_once;
          test_case "a changed folder is left as it is" `Quick a_changed_folder_is_left_as_it_is;
          test_case "without docker the folders are still written" `Quick
            without_docker_the_folders_are_still_written;
          test_case "declared installs only what the declarations name" `Quick
            declared_installs_only_what_the_declarations_name;
          test_case "a relative base path is refused" `Quick a_relative_base_path_is_refused ] ) ]
