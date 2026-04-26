(** MASC Web Dashboard — SPA (Preact + HTM)

    The dashboard is now a TypeScript SPA built with Vite.
    Source: dashboard/src/
    Build output: assets/dashboard/

    This module is kept for backward compatibility.
    The actual serving logic is in bin/main_eio.ml (serve_dashboard_index).
*)

let assets_root () =
  let is_dir path = Sys.file_exists path && Sys.is_directory path in
  let exe_dir = Filename.dirname Sys.executable_name in
  let inferred_repo_assets =
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "assets"
  in
  (* MASC_BASE_PATH is the runtime data root for .masc, not a dashboard asset root. *)
  let candidates =
    List.fold_right
      (fun path acc ->
         match path with
         | Some value -> value :: acc
         | None -> acc)
      [ Some inferred_repo_assets
      ; Some (Filename.concat exe_dir "assets")
      ; Some (Filename.concat (Sys.getcwd ()) "assets")
      ]
      []
  in
  match Env_config_core.assets_dir_opt () with
  | Some d when is_dir d -> d
  | _ ->
    (match List.find_opt is_dir candidates with
     | Some path -> path
     | None ->
       (match candidates with
        | path :: _ -> path
        | [] -> Filename.concat (Sys.getcwd ()) "assets"))
;;

let index_path () =
  Filename.concat (Filename.concat (assets_root ()) "dashboard") "index.html"
;;

let html () =
  try Fs_compat.load_file (index_path ()) with
  | Sys_error _ ->
    "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; pnpm run \
     build</body></html>"
;;

let etag () =
  try
    let st = Unix.stat (index_path ()) in
    let hash = Digest.string (string_of_float st.Unix.st_mtime) |> Digest.to_hex in
    String.sub hash 0 12
  with
  | Unix.Unix_error _ -> "none"
;;

let is_safe_asset_relative_path rel =
  String.length rel > 0
  && Filename.is_relative rel
  && (not (String.contains rel '\\'))
  && (not (String.contains rel '\000'))
  &&
  let segments = String.split_on_char '/' rel in
  List.for_all (fun seg -> String.length seg > 0 && seg <> "." && seg <> "..") segments
;;
