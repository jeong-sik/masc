(* Shared dependency re-export for MASC test suite.
   Also hosts tiny test helpers that need a single SSOT across files. *)

let init_keeper_tool_registry () =
  if not (Masc_mcp.Tool_dispatch.is_tag_registry_initialized ()) then
    let _ = Masc_mcp.Mcp_server_eio.governance_defaults in
    ()

(** Walk up the directory tree from [Sys.getcwd()] until
    [config/tool_policy.toml] is found, then return that directory.
    Raises [Failure] with a descriptive message if the marker file
    cannot be found by the time the filesystem root is reached. *)
let find_project_root () =
  let marker = "config/tool_policy.toml" in
  let start_dir = Sys.getcwd () in
  let rec walk dir =
    if Sys.file_exists (Filename.concat dir marker) then dir
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir then
        failwith
          (Printf.sprintf
             "Could not find %s when walking upward from %s"
             marker start_dir)
      else
        walk parent
  in
  walk start_dir
