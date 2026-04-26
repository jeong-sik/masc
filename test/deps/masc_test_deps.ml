(* Shared dependency re-export for MASC test suite.
   Also hosts tiny test helpers that need a single SSOT across files. *)

(** Install the Eio clock + optional switch in every registry the lib
    code reads from.

    MASC stores clock state in two places: [Time_compat] (sleep/now) and
    [Eio_context] (Dashboard_cache and other lib/ code that needs the raw
    [float Eio.Time.clock_ty]). Historically harnesses called only
    [Time_compat.set_clock], so anything hitting [Eio_context.get_clock_opt]
    failed with [failwith "Eio clock unavailable"] on the first cache-compute
    path. Main CI skipped Build and Test for 100+ dashboard-only commits, so
    the regression was invisible.

    Call this once per harness after [Eio_main.run @@ fun env ->]
    (and [Eio.Switch.run @@ fun sw ->] if the test publishes a switch). *)
let init_eio_clock ?sw env =
  let clock = Eio.Stdenv.clock env in
  Time_compat.set_clock clock;
  Eio_context.set_clock clock;
  Option.iter Eio_context.set_switch sw
;;

let init_keeper_tool_registry () =
  if not (Masc_mcp.Tool_dispatch.is_tag_registry_initialized ())
  then (
    let _ = Masc_mcp.Mcp_server_eio.governance_defaults in
    ())
;;

(** Walk up the directory tree from [Sys.getcwd()] until
    [config/tool_policy.toml] is found, then return that directory.
    Raises [Failure] with a descriptive message if the marker file
    cannot be found by the time the filesystem root is reached. *)
let find_project_root () =
  let marker = "config/tool_policy.toml" in
  let start_dir = Sys.getcwd () in
  let rec walk dir =
    if Sys.file_exists (Filename.concat dir marker)
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then
        failwith
          (Printf.sprintf
             "Could not find %s when walking upward from %s"
             marker
             start_dir)
      else walk parent)
  in
  walk start_dir
;;
