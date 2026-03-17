(** MASC Web Dashboard — SPA (Preact + HTM)

    The dashboard is now a TypeScript SPA built with Vite.
    Source: dashboard/src/
    Build output: assets/dashboard/

    This module is kept for backward compatibility.
    The actual serving logic is in bin/main_eio.ml (serve_dashboard_index).
*)

let assets_root () =
  let env_assets =
    match Sys.getenv_opt "MASC_ASSETS_ROOT" with
    | Some d when String.trim d <> "" -> Some d
    | _ ->
        (match Sys.getenv_opt "MASC_ASSETS_DIR" with
         | Some d when String.trim d <> "" -> Some d
         | _ -> None)
  in
  match env_assets with
  | Some d -> d
  | None ->
      let exe_dir = Filename.dirname Sys.executable_name in
      let exe_assets = Filename.concat exe_dir "assets" in
      let cwd_assets = Filename.concat (Sys.getcwd ()) "assets" in
      if Sys.file_exists exe_assets then exe_assets
      else if Sys.file_exists cwd_assets then cwd_assets
      else exe_assets

let index_path () =
  Filename.concat (Filename.concat (assets_root ()) "dashboard") "index.html"

let html () =
  try
    Fs_compat.load_file (index_path ())
  with Sys_error _ ->
    "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; npm run build</body></html>"

let etag () =
  try
    let st = Unix.stat (index_path ()) in
    let hash = Digest.string (string_of_float st.Unix.st_mtime) |> Digest.to_hex in
    String.sub hash 0 12
  with Unix.Unix_error _ -> "none"

let is_safe_asset_relative_path rel =
  String.length rel > 0
  && Filename.is_relative rel
  && not (String.contains rel '\\')
  && not (String.contains rel '\000')
  &&
  let segments = String.split_on_char '/' rel in
  List.for_all
    (fun seg ->
      String.length seg > 0
      && seg <> "."
      && seg <> "..")
    segments
