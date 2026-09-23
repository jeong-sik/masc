(** Tests for [Managed_asset_sync] (#20929) — converging the runtime prompt
    markdown and tool definition dirs onto binary-embedded assets. *)

open Alcotest
module Managed_asset_sync = Masc.Managed_asset_sync

(* The runtime manifest a previous sync would have left behind. No embedded
   fixture carries one: the embedded tree is the managed set (#31283). *)
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
  Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~edit_layer:Managed_asset_sync.No_edit_layer ~read:read_embedded
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

(* The previous binary shipped v1 and this pass wrote it; the file still
   holds exactly those bytes, so it is the distribution's stale copy. *)
let test_overwrites_stale_copy () =
  with_temp_prompts_dir (fun dir ->
      let v1 rel =
        if String.equal rel "prompts/keeper.example.md"
        then Some "---\ndescription: example\n---\nbody v1\n"
        else read_embedded rel
      in
      let (_ : Managed_asset_sync.sync_result) =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
          ~edit_layer:Managed_asset_sync.No_edit_layer ~read:v1
          ~files:embedded_files ~dest_dir:dir ()
      in
      let stale = Filename.concat dir "keeper.example.md" in
      let result = sync ~prompts_dir:dir in
      check (list string) "overwritten" [ "prompts/keeper.example.md" ]
        result.Managed_asset_sync.overwritten;
      check int "not an operator edit" 0
        (List.length result.Managed_asset_sync.operator_edits);
      check (list string) "copied" [] result.Managed_asset_sync.copied;
      check string "converged content"
        "---\ndescription: example\n---\nbody v2\n" (read_file stale))

let mentions ~line needle =
  let nl = String.length needle and hl = String.length line in
  let rec scan i = i + nl <= hl && (String.sub line i nl = needle || scan (i + 1)) in
  scan 0

(* A prompt file the operator wrote into the runtime directory was in no
   manifest, so it is not the distribution's to remove. It survives the
   first pass (no manifest yet), a pass with a manifest that lists only the
   managed files, and a pass on which a managed asset retires beside it. *)
let test_an_operator_file_survives_every_pass () =
  with_temp_prompts_dir (fun dir ->
      let extra = Filename.concat dir "operator.custom.md" in
      Out_channel.with_open_text extra (fun oc ->
          Out_channel.output_string oc "local-only\n");
      let first = sync ~prompts_dir:dir in
      check (list string) "first pass removes nothing" [] first.Managed_asset_sync.removed;
      check bool "first pass leaves it" true (Sys.file_exists extra);
      let second = sync ~prompts_dir:dir in
      check (list string) "a pass with a manifest removes nothing" []
        second.Managed_asset_sync.removed;
      check bool "no log line for a file that stayed" true
        (Option.is_none (Managed_asset_sync.removed_line ~label:"prompt" second));
      let retired = Filename.concat dir "keeper.retired.md" in
      Out_channel.with_open_text retired (fun oc ->
          Out_channel.output_string oc "distribution copy\n");
      write_runtime_manifest dir
        [ "keeper.example.md"; "behavior/contract.md"; "keeper.retired.md" ];
      let third = sync ~prompts_dir:dir in
      check (list string) "only the retired asset goes" [ "prompts/keeper.retired.md" ]
        third.Managed_asset_sync.removed;
      check bool "the operator's file is still there" true (Sys.file_exists extra);
      check string "with its content" "local-only\n" (read_file extra))

(* The boot log is the only place a retirement is announced. That log
   reads [removed], so the two are checked together: asserting on the
   filesystem alone passes just as well when [removed] comes back empty and
   the operator is told nothing. *)
let test_a_retired_asset_reaches_the_log_line () =
  with_temp_prompts_dir (fun dir ->
      let retired = Filename.concat dir "keeper.retired.md" in
      Out_channel.with_open_text retired (fun oc ->
          Out_channel.output_string oc "distribution copy\n");
      write_runtime_manifest dir
        [ "keeper.example.md"; "behavior/contract.md"; "keeper.retired.md" ];
      let result = sync ~prompts_dir:dir in
      check (list string) "removed names the retired asset"
        [ "prompts/keeper.retired.md" ] result.Managed_asset_sync.removed;
      match Managed_asset_sync.removed_line ~label:"prompt" result with
      | None -> failf "a deleted file produced no log line"
      | Some line ->
          check bool "the line names the file" true (mentions ~line "keeper.retired.md");
          check bool "and says why it went" true (mentions ~line "no longer embedded"))

(* A manifest another domain wrote, or one that does not read, owns
   nothing here: the pass copies and overwrites as usual, deletes nothing,
   and says what was wrong with the manifest. *)
let test_a_foreign_or_broken_manifest_retires_nothing () =
  List.iter
    (fun (name, content, expected_reason) ->
      with_temp_prompts_dir (fun dir ->
          let stray = Filename.concat dir "keeper.stray.md" in
          Out_channel.with_open_text stray (fun oc ->
              Out_channel.output_string oc "whatever was here\n");
          Out_channel.with_open_text (Filename.concat dir "managed-assets.json")
            (fun oc -> Out_channel.output_string oc content);
          let result = sync ~prompts_dir:dir in
          check (list string) (name ^ ": removed") [] result.Managed_asset_sync.removed;
          check bool (name ^ ": the stray file stays") true (Sys.file_exists stray);
          check (list string) (name ^ ": managed assets still copied")
            [ "prompts/behavior/contract.md"; "prompts/keeper.example.md" ]
            (List.sort compare result.Managed_asset_sync.copied);
          (match
             List.filter
               (fun (rel, _) -> String.equal rel "prompts/managed-assets.json")
               result.Managed_asset_sync.failed
           with
           | [ (_, reason) ] ->
             check bool (name ^ ": the report says what was wrong") true
               (mentions ~line:reason expected_reason)
           | reports ->
             failf "%s: expected one manifest report, found %d" name (List.length reports));
          (* The evidence stays: a rewrite would make the next boot read
             clean and the report would have shown once. *)
          check string (name ^ ": the manifest is left as it was") content
            (read_file (Filename.concat dir "managed-assets.json"))))
    [ ( "tool-domain manifest"
      , manifest ~schema:"masc.tool-managed-assets.v1" [ "keeper.stray.md" ]
      , "is not" )
    ; "not JSON", "{ this is not json", "not JSON"
    ; "no paths", {|{"schema":"masc.prompt-managed-assets.v1"}|}, "lacks"
    ; "unsafe path", manifest [ "../keeper.stray.md" ], "unsafe path"
    ]

(* A manifest that exists and cannot be read is the same case with a
   different cause: reported, nothing retired, and the file untouched. This
   used to escape as Sys_error and end the boot. Root reads any file, so
   the case is skipped there rather than reported as passing. *)
let test_an_unreadable_manifest_retires_nothing () =
  if Unix.geteuid () = 0 then ()
  else
    with_temp_prompts_dir (fun dir ->
        let stray = Filename.concat dir "keeper.stray.md" in
        Out_channel.with_open_text stray (fun oc ->
            Out_channel.output_string oc "whatever was here\n");
        let manifest_file = Filename.concat dir "managed-assets.json" in
        write_runtime_manifest dir [ "keeper.stray.md" ];
        Unix.chmod manifest_file 0o000;
        Fun.protect
          ~finally:(fun () -> try Unix.chmod manifest_file 0o600 with Unix.Unix_error _ -> ())
          (fun () ->
            let result = sync ~prompts_dir:dir in
            check (list string) "removed" [] result.Managed_asset_sync.removed;
            check bool "the stray file stays" true (Sys.file_exists stray);
            match result.Managed_asset_sync.failed with
            | [ ("prompts/managed-assets.json", reason) ] ->
              check bool "the report names the read failure" true
                (mentions ~line:reason "unreadable")
            | failed ->
              failf "expected the manifest report alone, found %d" (List.length failed)))

(* An embedded tree with nothing under prompts/ is the crunch-lost-the-tree
   state. Every domain ships assets, so the sync refuses to project the
   emptiness: fail closed, delete nothing. *)
let test_empty_embedded_set_fails_closed () =
  with_temp_prompts_dir (fun dir ->
      let existing = Filename.concat dir "keeper.existing.md" in
      Out_channel.with_open_text existing (fun oc ->
          Out_channel.output_string oc "must survive a lost embedded tree\n");
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:(fun (_ : string) -> None)
          ~files:[ "runtime.toml"; "tools/masc_board_vote.toml" ]
          ~dest_dir:dir
          ()
      in
      check (list string) "removed" [] result.Managed_asset_sync.removed;
      check bool "runtime tree preserved" true (Sys.file_exists existing);
      check bool "empty set failure visible" true
        (List.exists
           (fun (rel, msg) ->
             String.equal rel "prompts/"
             && String.equal msg
                  "embedded prompt asset set is empty; refusing to project an empty tree")
           result.Managed_asset_sync.failed))

let test_unsafe_embedded_paths_preserve_runtime_tree () =
  List.iter
    (fun unsafe_path ->
      with_temp_prompts_dir (fun dir ->
        let existing = Filename.concat dir "keeper.existing.md" in
        Out_channel.with_open_text existing (fun oc ->
          Out_channel.output_string oc "existing runtime content\n");
        write_runtime_manifest dir [ "keeper.existing.md" ];
        let manifest_path = Filename.concat dir "managed-assets.json" in
        let before_manifest = read_file manifest_path in
        let read_called = ref false in
        let result =
          Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~edit_layer:Managed_asset_sync.No_edit_layer
            ~read:(fun _ -> read_called := true; Some "new embedded content\n")
            ~files:[ "prompts/new.md"; "prompts/" ^ unsafe_path ]
            ~dest_dir:dir ()
        in
        check (list string) "nothing copied" [] result.Managed_asset_sync.copied;
        check (list string) "nothing overwritten" [] result.Managed_asset_sync.overwritten;
        check (list string) "nothing removed" [] result.Managed_asset_sync.removed;
        check (list (pair string string)) "unsafe path is reported"
          [ "prompts/" ^ unsafe_path, "unsafe embedded prompt asset path" ]
          result.Managed_asset_sync.failed;
        check bool "no embedded reads before complete path validation" false !read_called;
        check bool "existing asset remains" true (Sys.file_exists existing);
        check string "existing content is unchanged" "existing runtime content\n"
          (read_file existing);
        check string "runtime manifest is unchanged" before_manifest
          (read_file manifest_path);
        check bool "valid preceding asset is not written" false
          (Sys.file_exists (Filename.concat dir "new.md"))))
    [ "../outside.md"; "/absolute.md"; "nested/../outside.md"; "."; "nested//file.md"; "" ]

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
          let link = Filename.concat dir "link" in
          Unix.symlink outside link;
          let assets = [ "prompts/link/current.md", "current embedded body\n" ] in
          write_runtime_manifest dir [ "link/current.md"; "link/old.md" ];
          let result =
            Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~edit_layer:Managed_asset_sync.No_edit_layer
              ~read:(fun rel -> List.assoc_opt rel assets)
              ~files:(List.map fst assets)
              ~dest_dir:dir
              ()
          in
          (* The link is the operator's: no manifest placed it, so the sync
             neither follows it nor removes it. The managed asset under it
             cannot be written without crossing the link, and that is
             reported rather than done. *)
          check (list string) "nothing removed" [] result.Managed_asset_sync.removed;
          check bool "the link stays" true
            ((Unix.lstat link).Unix.st_kind = Unix.S_LNK);
          check bool "outside managed file survives" true
            (Sys.file_exists outside_old);
          check string "outside content unchanged" "outside must survive\n"
            (read_file outside_old);
          check bool "nothing written through the link" false
            (Sys.file_exists (Filename.concat outside "current.md"));
          check (list string) "the asset behind the link is reported, not written"
            [ "prompts/link/current.md" ]
            (List.map fst result.Managed_asset_sync.failed)))

let test_unreadable_embedded_entry_is_failed () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:(fun (_ : string) -> None)
          ~files:[ "prompts/ghost.md" ]
          ~dest_dir:dir ()
      in
      check int "failed count" 1 (List.length result.Managed_asset_sync.failed);
      match result.Managed_asset_sync.failed with
      | [ (rel, _) ] -> check string "failed entry" "prompts/ghost.md" rel
      | _ -> fail "expected exactly one failure")

let test_binary_prompt_assets_sync_without_failure () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:Embedded_config.read
          ~files:Embedded_config.file_list
          ~dest_dir:dir
          ()
      in
      check (list (pair string string)) "every embedded prompt asset synced" []
        result.Managed_asset_sync.failed)

(* ── Tools domain ─────────────────────────────────────────────────────── *)

let tools_embedded =
  [ ( "tools/masc_board_vote.toml"
    , "name = \"masc_board_vote\"\ndescription = \"Vote.\"\n" )
  ; ( "prompts/keeper.example.md"
    , "---\ndescription: example\n---\nbody v2\n" )
  ]

let test_tools_domain_scopes_to_tools () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools ~edit_layer:Managed_asset_sync.No_edit_layer
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

(* The runtime manifest is a projection of the embedded set. No source file
   declares that set any more (#31283: the hand-written copy drifted from the
   tree five releases running), so the only way the runtime file can be
   wrong is for the sync to have written something other than what it
   embedded. This reads it back and pins it to the fixture, then drops one
   embedded asset and checks that exactly that file and that line go. *)
let runtime_manifest dir =
  match Yojson.Safe.from_file (Filename.concat dir "managed-assets.json") with
  | `Assoc fields ->
    (match
       ( List.assoc_opt "managed_by" fields
       , List.assoc_opt "schema" fields
       , List.assoc_opt "paths" fields )
     with
     | Some (`String managed_by), Some (`String schema), Some (`List paths) ->
       ( managed_by
       , schema
       , List.map
           (function
             | `String path -> path
             | _ -> failwith "runtime manifest path is not a string")
           paths )
     | _ -> failwith "runtime manifest is missing managed_by, schema, or paths")
  | _ -> failwith "runtime manifest is not a JSON object"

let test_runtime_manifest_projects_the_embedded_set () =
  with_temp_prompts_dir (fun dir ->
      let three =
        [ "tools/masc_alpha.toml", "name = \"masc_alpha\"\n"
        ; "tools/masc_beta.toml", "name = \"masc_beta\"\n"
        ; "tools/masc_gamma.toml", "name = \"masc_gamma\"\n"
        ; "prompts/keeper.example.md", "not a tool\n"
        ]
      in
      let run assets =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:(fun rel -> List.assoc_opt rel assets)
          ~files:(List.map fst assets)
          ~dest_dir:dir
          ()
      in
      let first = run three in
      check int "failed" 0 (List.length first.Managed_asset_sync.failed);
      let managed_by, schema, paths = runtime_manifest dir in
      check string "managed_by" "MASC" managed_by;
      check string "schema" "masc.tool-managed-assets.v2" schema;
      check (list string) "paths are exactly the embedded tool files"
        [ "masc_alpha.toml"; "masc_beta.toml"; "masc_gamma.toml" ]
        paths;
      let without_beta =
        List.filter (fun (rel, _) -> not (String.equal rel "tools/masc_beta.toml")) three
      in
      let second = run without_beta in
      check (list string) "the dropped asset is removed"
        [ "tools/masc_beta.toml" ] second.Managed_asset_sync.removed;
      check int "nothing else failed" 0 (List.length second.Managed_asset_sync.failed);
      check bool "the others survive" true
        (Sys.file_exists (Filename.concat dir "masc_alpha.toml")
        && Sys.file_exists (Filename.concat dir "masc_gamma.toml"));
      let _, _, paths = runtime_manifest dir in
      check (list string) "the manifest shrank with the set"
        [ "masc_alpha.toml"; "masc_gamma.toml" ]
        paths)

let test_binary_tool_assets_sync_without_failure () =
  with_temp_prompts_dir (fun dir ->
      let result =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:Embedded_config.read
          ~files:Embedded_config.file_list
          ~dest_dir:dir
          ()
      in
      check (list (pair string string)) "every embedded tool asset synced" []
        result.Managed_asset_sync.failed)

let outcome_testable =
  testable
    (fun ppf (outcome : Managed_asset_sync.operator_edit_outcome) ->
      Format.pp_print_string ppf
        (match outcome with
         | Managed_asset_sync.Promoted_to_override { key } -> "promoted " ^ key
         | Managed_asset_sync.Kept_override_exists { key } -> "kept, override exists " ^ key
         | Managed_asset_sync.Kept_not_promotable { reason } -> "kept: " ^ reason
         | Managed_asset_sync.Discarded -> "discarded"))
    ( = )

let edits result =
  List.map
    (fun { Managed_asset_sync.path; outcome } -> path, outcome)
    result.Managed_asset_sync.operator_edits

let write_file path content =
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc content)

let prompt_embedded =
  [ ( "prompts/curator.md"
    , "---\ndescription: curator\ntemplate_variables: [memory]\n---\nKeep what \
       matters in {{memory}}.\n" )
  ]

let with_workspace f =
  with_temp_prompts_dir (fun base ->
      let prompts = Filename.concat base "prompts" in
      Unix.mkdir prompts 0o700;
      f ~base ~prompts)

let prompt_sync ~base ~prompts =
  Managed_asset_sync.sync ~domain:Managed_asset_sync.Prompts
    ~edit_layer:
      (Managed_asset_sync.Prompt_overrides
         (Prompt_registry.promote_file_edit ~base_path:base))
    ~read:(fun rel -> List.assoc_opt rel prompt_embedded)
    ~files:(List.map fst prompt_embedded)
    ~dest_dir:prompts ()

let edited_curator = "---\ndescription: curator\ntemplate_variables: [memory]\n---\nKeep \
                      only decisions from {{memory}}.\n"

let overrides_path base = Filename.concat (Filename.concat base ".masc") "prompt_overrides.json"

(* The live case: an operator changed a prompt's behaviour by editing its
   runtime file. The edit becomes the prompt's override, the file goes back
   to the distribution copy, and the registry serves the edited text. *)
let test_edited_prompt_becomes_its_override () =
  with_workspace (fun ~base ~prompts ->
      let (_ : Managed_asset_sync.sync_result) = prompt_sync ~base ~prompts in
      let file = Filename.concat prompts "curator.md" in
      write_file file edited_curator;
      let result = prompt_sync ~base ~prompts in
      check (list (pair string outcome_testable)) "the edit is promoted"
        [ "prompts/curator.md", Managed_asset_sync.Promoted_to_override { key = "curator" } ]
        (edits result);
      check (list string) "not counted as a stale overwrite" []
        result.Managed_asset_sync.overwritten;
      check string "the file is the distribution copy again"
        (List.assoc "prompts/curator.md" prompt_embedded) (read_file file);
      (match Prompt_override_persistence.load ~path:(overrides_path base) with
       | Ok [ entry ] ->
         check string "saved key" "curator" entry.Prompt_override_persistence.key;
         check string "saved text" "Keep only decisions from {{memory}}."
           entry.Prompt_override_persistence.value
       | Ok entries -> failf "expected one saved override, found %d" (List.length entries)
       | Error error ->
         failf "override file: %s" (Prompt_override_persistence.error_to_string error));
      Prompt_registry.clear ();
      Fun.protect ~finally:Prompt_registry.clear (fun () ->
          Prompt_registry.set_markdown_dir prompts;
          Prompt_registry.restore_overrides base;
          check string "the registry serves the edited text"
            "Keep only decisions from {{memory}}."
            (Prompt_registry.get_prompt "curator"));
      let again = prompt_sync ~base ~prompts in
      check int "the next pass finds nothing edited" 0
        (List.length again.Managed_asset_sync.operator_edits))

(* The operator already saved an override for the key. Which text they
   mean is theirs to say, so the edited file stays and is reported, pass
   after pass, until they resolve it. *)
let test_edited_prompt_with_an_override_is_kept () =
  with_workspace (fun ~base ~prompts ->
      let (_ : Managed_asset_sync.sync_result) = prompt_sync ~base ~prompts in
      Unix.mkdir (Filename.concat base ".masc") 0o700;
      let saved =
        Prompt_override_persistence.
          { key = "curator"
          ; value = "Saved earlier from {{memory}}."
          ; authored_against = "0"
          ; template_variables = [ "memory" ]
          }
      in
      (match Prompt_override_persistence.save ~path:(overrides_path base) [ saved ] with
       | Ok () -> ()
       | Error error -> failf "%s" (Prompt_override_persistence.error_to_string error));
      let file = Filename.concat prompts "curator.md" in
      write_file file edited_curator;
      List.iter
        (fun pass ->
          let result = prompt_sync ~base ~prompts in
          check (list (pair string outcome_testable)) (pass ^ ": a conflict is reported")
            [ ( "prompts/curator.md"
              , Managed_asset_sync.Kept_override_exists { key = "curator" } )
            ]
            (edits result);
          check string (pass ^ ": the edited file is untouched") edited_curator
            (read_file file))
        [ "first pass"; "second pass" ];
      match Prompt_override_persistence.load ~path:(overrides_path base) with
      | Ok [ entry ] ->
        check string "the saved override is unchanged" "Saved earlier from {{memory}}."
          entry.Prompt_override_persistence.value
      | Ok _ | Error _ -> fail "the saved override changed")

(* Tool definitions have no edit layer. The edit is overwritten, and the
   operator is told which file lost it. *)
let test_edited_tool_is_overwritten_and_reported () =
  with_temp_prompts_dir (fun dir ->
      let run () =
        Managed_asset_sync.sync ~domain:Managed_asset_sync.Tools
          ~edit_layer:Managed_asset_sync.No_edit_layer
          ~read:(fun rel -> List.assoc_opt rel tools_embedded)
          ~files:(List.map fst tools_embedded)
          ~dest_dir:dir ()
      in
      let (_ : Managed_asset_sync.sync_result) = run () in
      let file = Filename.concat dir "masc_board_vote.toml" in
      write_file file "name = \"masc_board_vote\"\ndescription = \"Mine.\"\n";
      let result = run () in
      check (list (pair string outcome_testable)) "the edit is reported"
        [ "tools/masc_board_vote.toml", Managed_asset_sync.Discarded ]
        (edits result);
      check string "and overwritten" (List.assoc "tools/masc_board_vote.toml" tools_embedded)
        (read_file file);
      match Managed_asset_sync.operator_edit_lines ~label:"tool" result with
      | [ line ] ->
        check bool "the line names the file" true (mentions ~line "tools/masc_board_vote.toml")
      | lines -> failf "expected one line, found %d" (List.length lines))

(* A manifest from before digests were recorded lists paths only. Every
   differing file is overwritten as stale, as it always was, and the
   rewritten manifest carries a digest for each path. *)
let test_a_digestless_manifest_overwrites_and_gains_digests () =
  with_temp_prompts_dir (fun dir ->
      let file = Filename.concat dir "keeper.example.md" in
      write_file file "an edit nobody recorded\n";
      write_runtime_manifest dir [ "keeper.example.md"; "behavior/contract.md" ];
      let result = sync ~prompts_dir:dir in
      check (list string) "overwritten as stale" [ "prompts/keeper.example.md" ]
        result.Managed_asset_sync.overwritten;
      check int "no operator edit" 0 (List.length result.Managed_asset_sync.operator_edits);
      check int "no failure" 0 (List.length result.Managed_asset_sync.failed);
      match Yojson.Safe.from_file (Filename.concat dir "managed-assets.json") with
      | `Assoc fields ->
        check (option string) "schema" (Some "masc.prompt-managed-assets.v2")
          (match List.assoc_opt "schema" fields with
           | Some (`String schema) -> Some schema
           | Some _ | None -> None);
        (match List.assoc_opt "sha256" fields with
         | Some (`Assoc digests) ->
           check (list string) "a digest per path"
             [ "behavior/contract.md"; "keeper.example.md" ]
             (List.sort compare (List.map fst digests));
           check (option string) "the digest is of the bytes written"
             (Some
                (Digestif.SHA256.(
                   digest_string (List.assoc "prompts/keeper.example.md" embedded)
                   |> to_hex)))
             (match List.assoc_opt "keeper.example.md" digests with
              | Some (`String digest) -> Some digest
              | Some _ | None -> None)
         | Some _ | None -> fail "the rewritten manifest has no sha256 object")
      | _ -> fail "the rewritten manifest is not an object")

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
          test_case "an operator's file survives every pass" `Quick
            test_an_operator_file_survives_every_pass;
          test_case "a retired asset reaches the log line" `Quick
            test_a_retired_asset_reaches_the_log_line;
          test_case "a foreign or broken manifest retires nothing" `Quick
            test_a_foreign_or_broken_manifest_retires_nothing;
          test_case "an unreadable manifest retires nothing" `Quick
            test_an_unreadable_manifest_retires_nothing;
          test_case "empty embedded set fails closed" `Quick
            test_empty_embedded_set_fails_closed;
          test_case "unsafe embedded paths preserve runtime assets and manifest" `Quick
            test_unsafe_embedded_paths_preserve_runtime_tree;
          test_case "removed managed file is deleted" `Quick
            test_removed_managed_file_is_deleted;
          test_case "current managed leaf symlink is replaced without following"
            `Quick
            test_current_managed_leaf_symlink_is_replaced_without_following;
          test_case "removed managed leaf symlink is deleted without following"
            `Quick
            test_removed_managed_leaf_symlink_is_deleted_without_following;
          test_case "ancestor symlink cannot escape prompt root" `Quick
            test_symlink_ancestor_cannot_escape_prompt_root;
          test_case "unreadable embedded entry recorded as failure" `Quick
            test_unreadable_embedded_entry_is_failed;
          test_case "binary prompt assets sync without failure" `Quick
            test_binary_prompt_assets_sync_without_failure;
        ] );
      ( "tools",
        [
          test_case "copies missing, scopes to tools/" `Quick
            test_tools_domain_scopes_to_tools;
          test_case "runtime manifest projects the embedded set" `Quick
            test_runtime_manifest_projects_the_embedded_set;
          test_case "binary tool assets sync without failure" `Quick
            test_binary_tool_assets_sync_without_failure;
        ] );
      ( "operator edits",
        [
          test_case "an edited prompt becomes its override" `Quick
            test_edited_prompt_becomes_its_override;
          test_case "an edited prompt with an override is kept" `Quick
            test_edited_prompt_with_an_override_is_kept;
          test_case "an edited tool is overwritten and reported" `Quick
            test_edited_tool_is_overwritten_and_reported;
          test_case "a digestless manifest overwrites and gains digests" `Quick
            test_a_digestless_manifest_overwrites_and_gains_digests;
        ] );
    ]
