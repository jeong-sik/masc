(* Grep operation handler.

   The Grep tool (tool_search_files) is ripgrep pattern search only.
   Directory listing, file reads, find, and git views are done with the
   Execute tool. The rg search implementation lives in
   Keeper_workspace_read_ops. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

include Keeper_workspace_ops_setup

(* TEL-OK: handler rename only; [render_completed_process_result] records
   command history and failure telemetry through Keeper_workspace_ops_setup. *)
let handle_tool_search_files
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:(_exec_cache : Masc_exec.Exec_cache.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  match
    Keeper_workspace_read_ops.try_handle ~turn_sandbox_factory ~config ~meta ~args
      ~op:"rg" ~raw_path
  with
  | Some response -> response
  | None ->
    (* Unreachable: search_files is rg-only and try_handle always handles
       rg. Kept as a typed guard rather than an assert so a future routing
       change degrades to a clear message instead of a crash. *)
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; ( "error"
            , `String
                "search_files supports only rg (pattern search); use Execute \
                 for directory listing, file reads, find, or git" )
          ])
;;
