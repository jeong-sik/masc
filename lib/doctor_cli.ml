(** Doctor_cli — pure helpers for top-level doctor command routing.

    Keeps target parsing, repo-root discovery, and sidecar subprocess
    spec assembly out of [bin/main_eio.ml] so the command shape is
    testable without booting the server. *)

type sidecar =
  | Discord

type sidecar_request =
  | All
  | Named of sidecar

type sidecar_run_spec = {
  sidecar : sidecar;
  script_path : string;
  argv : string list;
}

let sidecar_name = function
  | Discord -> "discord"

let sidecar_display_name = function
  | Discord -> "Discord"

let known_sidecars = [ Discord ]

let sidecar_names () =
  List.map sidecar_name known_sidecars

let sidecar_request_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "all" -> Ok All
  | "discord" -> Ok (Named Discord)
  | other ->
      Error
        (Printf.sprintf
           "unknown sidecar '%s' (expected one of: %s, all)"
           other
           (String.concat ", " (sidecar_names ())))

let sidecar_request_to_string = function
  | All -> "all"
  | Named sidecar -> sidecar_name sidecar

let sidecars_of_request = function
  | None | Some All -> known_sidecars
  | Some (Named sidecar) -> [ sidecar ]

let sidecar_rel_dir = function
  | Discord -> "sidecars/discord-bot"

let sidecar_rel_script sidecar =
  Filename.concat (sidecar_rel_dir sidecar) "run.sh"

let ancestor_paths start =
  let normalized =
    Env_config.strip_path_trailing_slashes
      (Env_config.normalize_masc_base_path_input start)
  in
  let rec loop path acc =
    let next = Filename.dirname path in
    if String.equal next path then
      List.rev (path :: acc)
    else
      loop next (path :: acc)
  in
  if normalized = "" then [] else loop normalized []

let uniq_keep_order paths =
  let seen = Hashtbl.create 8 in
  List.filter
    (fun path ->
      if path = "" || Hashtbl.mem seen path then
        false
      else (
        Hashtbl.add seen path ();
        true))
    paths

let absolute_path ~cwd path =
  if Filename.is_relative path then Filename.concat cwd path else path

let find_repo_root_with ~cwd ~exe_path ~file_exists () =
  let exe_abs = absolute_path ~cwd exe_path in
  let starts =
    uniq_keep_order
      [ cwd; Filename.dirname exe_abs ]
  in
  let has_sidecar_marker root =
    file_exists (Filename.concat root (sidecar_rel_script Discord))
  in
  let rec find = function
    | [] -> None
    | root :: rest ->
        if has_sidecar_marker root then Some root else find rest
  in
  starts
  |> List.concat_map ancestor_paths
  |> uniq_keep_order
  |> find
  |> function
  | Some root -> Ok root
  | None ->
      Error
        "doctor sidecar/all requires a repo checkout with sidecars/<name>/run.sh available"

let find_repo_root ~cwd ~exe_path () =
  find_repo_root_with ~cwd ~exe_path ~file_exists:Sys.file_exists ()

let sidecar_run_spec ~repo_root ~sidecar ~json ~fix =
  let script_path = Filename.concat repo_root (sidecar_rel_script sidecar) in
  let argv =
    [ "/bin/bash"; script_path; "doctor" ]
    @ (if json then [ "--json" ] else [])
    @ (if fix then [ "--fix" ] else [])
  in
  { sidecar; script_path; argv }
