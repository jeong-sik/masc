(** MASC Web Dashboard — SPA (Preact + HTM)

    The dashboard is now a TypeScript SPA built with Vite.
    Source: dashboard/src/
    Build output: assets/dashboard/

    This module is kept for backward compatibility.
    The actual serving logic is in bin/main_eio.ml (serve_dashboard_index).
*)

let assets_root () =
  let is_dir path =
    try (Unix.stat path).Unix.st_kind = Unix.S_DIR with
    | Unix.Unix_error _ -> false
  in
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
      [
        Some inferred_repo_assets;
        Some (Filename.concat exe_dir "assets");
        Some (Filename.concat (Config_dir_resolver.current_working_dir ()) "assets");
      ]
      []
  in
  match (Host_config.from_env ()).assets_dir with
  | Some d when is_dir d -> d
  | _ ->
      match List.find_opt is_dir candidates with
      | Some path -> path
      | None ->
          (match candidates with
           | path :: _ -> path
           | [] -> Filename.concat (Config_dir_resolver.current_working_dir ()) "assets")

let index_path () =
  Filename.concat (Filename.concat (assets_root ()) "dashboard") "index.html"

let build_stamp_path () =
  Filename.concat (Filename.concat (assets_root ()) "dashboard") ".build-stamp"

let mtime_of path =
  try Some (Unix.stat path).Unix.st_mtime with
  | Unix.Unix_error _ -> None

(* Same "%04d-%02d-%02dT%02d:%02d:%02dZ" idiom as
   Types_core.iso8601_of_unix_seconds / Log.timestamp_iso — duplicated here
   rather than depended on to keep this module's dependency footprint
   unchanged. *)
let iso8601_of_unix_seconds ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

type bundle_freshness =
  | Fresh
  | Stale of { stamp_mtime : float; binary_mtime : float }
  | Missing_stamp

(** Compare the dashboard bundle's [.build-stamp] mtime (touched by
    [scripts/build-dashboard-if-needed.sh] on every successful build) against
    the running server binary's mtime. A stamp older than the binary means a
    new server was shipped without rebuilding the SPA — the exact drift that
    let a removed HTTP route (#24332) keep getting called by a still-stale
    bundle. [Missing_stamp] covers both "never built" and any stat failure on
    the stamp path, so a broken assets_root resolution is never silently
    treated as fresh. *)
let bundle_freshness () =
  match mtime_of (build_stamp_path ()) with
  | None -> Missing_stamp
  | Some stamp_mtime ->
    (match mtime_of Sys.executable_name with
     | None ->
       (* Can't stat our own binary (unusual, e.g. exec'd via a symlink the
          OS deleted from under us) — nothing to compare against, so this is
          not evidence of staleness either way. *)
       Fresh
     | Some binary_mtime ->
       if stamp_mtime < binary_mtime then Stale { stamp_mtime; binary_mtime }
       else Fresh)

(** Log a boot-time WARN when the served bundle is stale or missing. Never
    silent: a missing stamp warns just as loudly as a stale one. Intended to
    be called once during server startup (see
    Server_runtime_bootstrap.run). *)
let log_bundle_freshness_warning () =
  match bundle_freshness () with
  | Fresh -> ()
  | Missing_stamp ->
    Log.Dashboard.warn
      "bundle build-stamp not found at %s — dashboard assets may be missing \
       or unbuilt; run: cd dashboard && pnpm run build"
      (build_stamp_path ())
  | Stale { stamp_mtime; binary_mtime } ->
    Log.Dashboard.warn
      "bundle build-stamp %s older than server binary %s — run: cd dashboard \
       && pnpm run build"
      (iso8601_of_unix_seconds stamp_mtime)
      (iso8601_of_unix_seconds binary_mtime)

let html () =
  try
    Fs_compat.load_file (index_path ())
  with Sys_error _ ->
    "<html><body>Dashboard build not found. Run: cd dashboard &amp;&amp; pnpm run build</body></html>"

let etag () =
  try
    let hash = Digest.file (index_path ()) |> Digest.to_hex in
    String.sub hash 0 12
  with
  | Unix.Unix_error _ | Sys_error _ -> "none"

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
