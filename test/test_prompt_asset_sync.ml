(** Tests for [Managed_asset_sync] (#20929) — converging the runtime prompt
    markdown and tool definition dirs onto binary-embedded assets. *)

open Alcotest
module Managed_asset_sync = Masc.Managed_asset_sync

let manifest_rel = "prompts/managed-assets.json"

let manifest ?(schema = "masc.prompt-managed-assets.v1") paths =
  Yojson.Safe.to_string
    (`Assoc
       [ "schema", `String schema
       ; "paths", `List (List.map (fun path -> `String path) paths)
       ])
;;

let embedded =
  [
    ( "prompts/keeper.example.md"
    , "---\ndescription: example\n---\nbody v2\n" )
  ; ( "prompts/behavior/contract.md"
    , "---\ndescription: contract\n---\nrules\n" )
  ; ( manifest_rel
    , manifest
        [ "keeper.example.md"; "behavior/contract.md" ] )
  ; "runtime.toml", "[runtime]\n"
  ]

let read_embedded rel = List.assoc_opt rel embedded
let embedded_files = List.map fst embedded

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun entry -> remove_tree (Filename.concat path entry))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Sys.remove path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_prompts_dir f =
  let dir = Filename.temp_dir "prompt-asset-sync" "test" in
  Fun.protect
    ~finally:(fun () ->
      (* best-effort cleanup; leftover temp dirs are harmless *)
      try remove_tree dir with
      | Sys_error _ | Unix.Unix_error _ -> ())
    (fun () -> f dir)

let read_file path = In_channel.with_open_text path In_channel.input_all

let write_runtime_manifest dir paths =
  Out_channel.with_open_text (Filename.concat dir "managed-assets.json") (fun oc ->
      Out_channel.output_string oc (manifest paths))

let sync ~prompts_dir =
  Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~read:read_embedded
    ~files:embedded_files ~dest_dir:prompts_dir ()

let test_copies_missing_and_scopes_to_prompts () =
  with_temp_prompts_dir (fun dir ->
      let result = sync ~prompts_dir:dir in
      check (list string) "copied"
        [ "prompts/behavior/contract.md"; "prompts/keeper.example.md" ]
        (List.sort compare result.Managed_asset_sync.copied);
      check (list string) "overwritten" [] result.Managed_asset_sync.overwritten;
      check (list string) "removed" [] result.Managed_asset_sync.removed;
      check int "failed" 0 (List.length result.Managed_asset_sync.failed);
      check string "subdir content" "---\ndescription: contract\n---\nrules\n"
        (read_file (Filename.concat dir "behavior/contract.md"));
      check bool "non-prompts asset not written" false
        (Sys.file_exists (Filename.concat dir "runtime.toml")))

let test_second_run_is_noop () =
  with_temp_prompts_dir (fun dir ->
      let (_ : Managed_asset_sync.sync_result) = sync ~prompts_dir:dir in
      let again = sync ~prompts_dir:dir in
      check (list string) "copied" [] again.Managed_asset_sync.copied;
      check (list string) "overwritten" [] again.Managed_asset_sync.overwritten)

let test_overwrites_stale_copy () =
  with_temp_prompts_dir (fun dir ->
      let (_ : Managed_asset_sync.sync_result) = sync ~prompts_dir:dir in
      let stale = Filename.concat dir "keeper.example.md" in
      Out_channel.with_open_text stale (fun oc ->
          Out_channel.output_string oc "body v1 (stale)\n");
      let result = sync ~prompts_dir:dir in
      check (list string) "overwritten" [ "prompts/keeper.example.md" ]
        result.Managed_asset_sync.overwritten;
      check (list string) "copied" [] result.Managed_asset_sync.copied;
      check string "converged content"
        "---\ndescription: example\n---\nbody v2\n" (read_file stale))

let test_runtime_extra_files_are_removed () =
  with_temp_prompts_dir (fun dir ->
      let extra = Filename.concat dir "operator.custom.md" in
      Out_channel.with_open_text extra (fun oc ->
          Out_channel.output_string oc "local-only\n");
      let (_ : Managed_asset_sync.sync_result) = sync ~prompts_dir:dir in
      check bool "runtime extra removed" false (Sys.file_exists extra))

(* A readable manifest that lists assets the embedded tree does not carry is
   the crunch-lost-the-tree state: fail closed, delete nothing. *)
let test_missing_embedded_assets_fail_closed () =
  with_temp_prompts_dir (fun dir ->
      let existing = Filename.concat dir "keeper.existing.md" in
      Out_channel.with_open_text existing (fun oc ->
          Out_channel.output_string oc "must survive a lost embedded tree\n");
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
          ~read:(function
            | rel when String.equal rel manifest_rel ->
              Some (manifest [ "keeper.example.md" ])
            | _ -> None)
          ~files:[ manifest_rel ]
          ~dest_dir:dir
          ()
      in
      check (list string) "removed" [] result.Managed_asset_sync.removed;
      check bool "runtime tree preserved" true (Sys.file_exists existing);
      check bool "empty set failure visible" true
        (List.exists
           (fun (rel, msg) ->
             String.equal rel manifest_rel
             && String.equal msg "embedded prompt asset set is empty")
           result.Managed_asset_sync.failed))

(* An empty manifest over an empty embedded set is the valid state of a
   domain before its first migrated asset: the runtime dir is projected to
   exactly that emptiness. *)
let test_empty_manifest_with_empty_set_projects_exactly () =
  with_temp_prompts_dir (fun dir ->
      let stale = Filename.concat dir "keeper.stale.md" in
      Out_channel.with_open_text stale (fun oc ->
          Out_channel.output_string oc "stale distribution copy\n");
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
          ~read:(function
            | rel when String.equal rel manifest_rel -> Some (manifest [])
            | _ -> None)
          ~files:[ manifest_rel ]
          ~dest_dir:dir
          ()
      in
      check (list string) "removed" [ "prompts/keeper.stale.md" ]
        result.Managed_asset_sync.removed;
      check bool "stale copy purged" false (Sys.file_exists stale);
      check int "failed" 0 (List.length result.Managed_asset_sync.failed))

let test_removed_managed_file_is_deleted () =
  with_temp_prompts_dir (fun dir ->
      let removed = Filename.concat dir "keeper.removed.md" in
      Out_channel.with_open_text removed (fun oc ->
          Out_channel.output_string oc "distribution copy\n");
      write_runtime_manifest dir
        [ "keeper.example.md"; "behavior/contract.md"; "keeper.removed.md" ];
      let result = sync ~prompts_dir:dir in
      check (list string) "removed" [ "prompts/keeper.removed.md" ]
        result.Managed_asset_sync.removed;
      check bool "removed asset absent" false (Sys.file_exists removed))

let test_current_managed_leaf_symlink_is_replaced_without_following () =
  with_temp_prompts_dir (fun dir ->
      let outside = Filename.temp_file "prompt-asset-sync-outside" ".md" in
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove outside with
          | Sys_error _ -> ())
        (fun () ->
          Out_channel.with_open_text outside (fun oc ->
              Out_channel.output_string oc "outside must survive\n");
          let current = Filename.concat dir "keeper.example.md" in
          Unix.symlink outside current;
          let result = sync ~prompts_dir:dir in
          check (list string) "symlink replaced"
            [ "prompts/keeper.example.md" ]
            result.Managed_asset_sync.overwritten;
          check bool "replacement is a regular file" true
            ((Unix.lstat current).Unix.st_kind = Unix.S_REG);
          check string "embedded content installed"
            "---\ndescription: example\n---\nbody v2\n"
            (read_file current);
          check string "outside content unchanged" "outside must survive\n"
            (read_file outside)))

let test_removed_managed_leaf_symlink_is_deleted_without_following () =
  with_temp_prompts_dir (fun dir ->
      let outside = Filename.temp_file "prompt-asset-sync-outside" ".md" in
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove outside with
          | Sys_error _ -> ())
        (fun () ->
          Out_channel.with_open_text outside (fun oc ->
              Out_channel.output_string oc "outside must survive\n");
          let removed = Filename.concat dir "keeper.removed.md" in
          Unix.symlink outside removed;
          write_runtime_manifest dir
            [ "keeper.example.md"; "behavior/contract.md"; "keeper.removed.md" ];
          let result = sync ~prompts_dir:dir in
          check (list string) "managed symlink removed"
            [ "prompts/keeper.removed.md" ]
            result.Managed_asset_sync.removed;
          check bool "removed link absent" false (Sys.file_exists removed);
          check string "outside content unchanged" "outside must survive\n"
            (read_file outside)))

let test_invalid_manifest_preserves_managed_file () =
  with_temp_prompts_dir (fun dir ->
      let removed = Filename.concat dir "keeper.removed.md" in
      Out_channel.with_open_text removed (fun oc ->
          Out_channel.output_string oc "must survive invalid manifest\n");
      let read = function
        | rel when String.equal rel manifest_rel -> Some "{not-json"
        | rel -> read_embedded rel
      in
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~read
          ~files:embedded_files ~dest_dir:dir ()
      in
      check (list string) "removed" [] result.Managed_asset_sync.removed;
      check bool "managed asset preserved" true (Sys.file_exists removed);
      check bool "manifest failure visible" true
        (List.exists
           (fun (rel, _) -> String.equal rel manifest_rel)
           result.Managed_asset_sync.failed))

let test_incomplete_embedded_manifest_preserves_managed_file () =
  with_temp_prompts_dir (fun dir ->
      let removed = Filename.concat dir "keeper.removed.md" in
      Out_channel.with_open_text removed (fun oc ->
          Out_channel.output_string oc "must survive incomplete manifest\n");
      let read = function
        | rel when String.equal rel manifest_rel ->
          Some (manifest [ "keeper.removed.md" ])
        | rel -> read_embedded rel
      in
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~read
          ~files:embedded_files ~dest_dir:dir ()
      in
      check (list string) "removed" [] result.Managed_asset_sync.removed;
      check bool "managed asset preserved" true (Sys.file_exists removed);
      check bool "manifest coverage failure visible" true
        (List.exists
           (fun (rel, _) -> String.equal rel manifest_rel)
           result.Managed_asset_sync.failed))

let test_symlink_ancestor_cannot_escape_prompt_root () =
  with_temp_prompts_dir (fun dir ->
      let outside = Filename.temp_dir "prompt-asset-sync-outside" "test" in
      Fun.protect
        ~finally:(fun () ->
          try remove_tree outside with
          | Sys_error _ | Unix.Unix_error _ -> ())
        (fun () ->
          let outside_old = Filename.concat outside "old.md" in
          Out_channel.with_open_text outside_old (fun oc ->
              Out_channel.output_string oc "outside must survive\n");
          Unix.symlink outside (Filename.concat dir "link");
          let assets =
            [ "prompts/link/current.md", "current embedded body\n"
            ; ( manifest_rel, manifest [ "link/current.md" ] )
            ]
          in
          write_runtime_manifest dir [ "link/current.md"; "link/old.md" ];
          let result =
            Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
              ~read:(fun rel -> List.assoc_opt rel assets)
              ~files:(List.map fst assets)
              ~dest_dir:dir
              ()
          in
          check (list string) "ancestor symlink removed"
            [ "prompts/link" ]
            result.Managed_asset_sync.removed;
          check bool "outside managed file survives" true
            (Sys.file_exists outside_old);
          check string "outside content unchanged" "outside must survive\n"
            (read_file outside_old);
          check int "no boundary failure after exact-tree purge" 0
            (List.length result.Managed_asset_sync.failed)))

let test_unreadable_embedded_entry_is_failed () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
          ~read:(function
            | rel when String.equal rel manifest_rel ->
              Some (manifest [ "ghost.md" ])
            | _ -> None)
          ~files:[ "prompts/ghost.md"; manifest_rel ]
          ~dest_dir:dir ()
      in
      check int "failed count" 1 (List.length result.Managed_asset_sync.failed);
      match result.Managed_asset_sync.failed with
      | [ (rel, _) ] -> check string "failed entry" "prompts/ghost.md" rel
      | _ -> fail "expected exactly one failure")

let test_binary_manifest_covers_current_assets () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
          ~read:Embedded_config.read
          ~files:Embedded_config.file_list
          ~dest_dir:dir
          ()
      in
      check (list (pair string string)) "all embedded prompt assets managed" []
        result.Managed_asset_sync.failed)

(* ── Tools domain ─────────────────────────────────────────────────────── *)

let tools_manifest_rel = "tools/managed-assets.json"

let tools_embedded =
  [ ( "tools/masc_board_vote.toml"
    , "name = \"masc_board_vote\"\ndescription = \"Vote.\"\n" )
  ; ( tools_manifest_rel
    , manifest ~schema:"masc.tool-managed-assets.v1" [ "masc_board_vote.toml" ] )
  ; ( "prompts/keeper.example.md"
    , "---\ndescription: example\n---\nbody v2\n" )
  ]

let test_tools_domain_scopes_to_tools () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools
          ~read:(fun rel -> List.assoc_opt rel tools_embedded)
          ~files:(List.map fst tools_embedded)
          ~dest_dir:dir
          ()
      in
      check (list string) "copied" [ "tools/masc_board_vote.toml" ]
        result.Managed_asset_sync.copied;
      check int "failed" 0 (List.length result.Managed_asset_sync.failed);
      check string "tool definition content"
        "name = \"masc_board_vote\"\ndescription = \"Vote.\"\n"
        (read_file (Filename.concat dir "masc_board_vote.toml"));
      check bool "prompt asset not written" false
        (Sys.file_exists (Filename.concat dir "keeper.example.md")))

let test_tools_domain_rejects_prompt_manifest_schema () =
  with_temp_prompts_dir (fun dir ->
      let mixed_schema =
        [ ( tools_manifest_rel
          , manifest ~schema:"masc.prompt-managed-assets.v1" [] )
        ]
      in
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools
          ~read:(fun rel -> List.assoc_opt rel mixed_schema)
          ~files:(List.map fst mixed_schema)
          ~dest_dir:dir
          ()
      in
      check bool "schema failure visible" true
        (List.exists
           (fun (rel, msg) ->
             String.equal rel tools_manifest_rel
             && String.equal msg
                  "unsupported managed tool asset schema: masc.prompt-managed-assets.v1")
           result.Managed_asset_sync.failed))

let test_binary_manifest_covers_current_tool_assets () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools
          ~read:Embedded_config.read
          ~files:Embedded_config.file_list
          ~dest_dir:dir
          ()
      in
      check (list (pair string string)) "all embedded tool assets managed" []
        result.Managed_asset_sync.failed)

let () =
  run "prompt_asset_sync"
    [
      ( "sync",
        [
          test_case "copies missing, scopes to prompts/" `Quick
            test_copies_missing_and_scopes_to_prompts;
          test_case "second run is a no-op" `Quick test_second_run_is_noop;
          test_case "overwrites stale runtime copy" `Quick
            test_overwrites_stale_copy;
          test_case "runtime extra files are removed" `Quick
            test_runtime_extra_files_are_removed;
          test_case "missing embedded assets fail closed" `Quick
            test_missing_embedded_assets_fail_closed;
          test_case "empty manifest with empty set projects exactly" `Quick
            test_empty_manifest_with_empty_set_projects_exactly;
          test_case "removed managed file is deleted" `Quick
            test_removed_managed_file_is_deleted;
          test_case "current managed leaf symlink is replaced without following"
            `Quick
            test_current_managed_leaf_symlink_is_replaced_without_following;
          test_case "removed managed leaf symlink is deleted without following"
            `Quick
            test_removed_managed_leaf_symlink_is_deleted_without_following;
          test_case "invalid manifest preserves managed files" `Quick
            test_invalid_manifest_preserves_managed_file;
          test_case "incomplete manifest preserves managed files" `Quick
            test_incomplete_embedded_manifest_preserves_managed_file;
          test_case "ancestor symlink cannot escape prompt root" `Quick
            test_symlink_ancestor_cannot_escape_prompt_root;
          test_case "unreadable embedded entry recorded as failure" `Quick
            test_unreadable_embedded_entry_is_failed;
          test_case "binary manifest covers current prompt assets" `Quick
            test_binary_manifest_covers_current_assets;
        ] );
      ( "tools",
        [
          test_case "copies missing, scopes to tools/" `Quick
            test_tools_domain_scopes_to_tools;
          test_case "rejects a prompt manifest schema under tools/" `Quick
            test_tools_domain_rejects_prompt_manifest_schema;
          test_case "binary manifest covers current tool assets" `Quick
            test_binary_manifest_covers_current_tool_assets;
        ] );
    ]
