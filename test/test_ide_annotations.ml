open Alcotest

module Types = Ide_annotation_types
module Store = Ide_annotations
module Region = Ide_region_tracker
module Sync = Ide_meta_sync
module Lsp = Masc_mcp.Lsp_overlay_provider

(* Ide_annotations.create generates ids via [Uuidm.v4_gen (Random.get_state ())].
   [Random.get_state] returns a COPY of the global state, so two
   close-succession calls without an explicit global advance produce
   the same uuid and collide under merge dedup. The PR-2 merge tests
   create two annotations in sequence, so seed the global state once
   to make uuids deterministic-distinct across the run. *)
let () = Random.self_init ()

let route_annotation : Types.annotation =
  { id = "ann-route"
  ; file_path = "lib/keeper/keeper_exec_ide.ml"
  ; line_start = 12
  ; line_end = 14
  ; keeper_id = "sangsu"
  ; kind = Types.Comment
  ; content = "Connect this line to the active review context."
  ; goal_id = Some "goal-ide"
  ; task_id = Some "task-42"
  ; board_post_id = Some "post-1"
  ; comment_id = Some "comment-1"
  ; pr_id = Some "15035"
  ; git_ref = Some "feat/context-lens"
  ; log_id = Some "turn-9"
  ; session_id = Some "sess-9"
  ; operation_id = Some "op-9"
  ; worker_run_id = Some "wr-9"
  ; created_at_ms = 1L
  ; updated_at_ms = 2L
  }
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_file "masc-ide-annotations" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let load_regions base_dir =
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no:_ json ->
      match Types.region_of_json json with
      | Ok region -> region :: acc
      | Error msg -> fail msg)
    (Region.regions_file ~base_dir ())
  |> List.rev
;;

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    idx + needle_len <= haystack_len
    && (String.equal (String.sub haystack idx needle_len) needle || loop (idx + 1))
  in
  needle_len = 0 || loop 0
;;

let check_contains label needle haystack =
  check bool label true (contains ~needle haystack)
;;

let assoc key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_field key json =
  match assoc key json with
  | Some (`String value) -> Some value
  | _ -> None
;;

let codelens_title = function
  | `Assoc fields ->
    (match List.assoc_opt "command" fields with
     | Some (`Assoc command) ->
       (match List.assoc_opt "title" command with
        | Some (`String title) -> Some title
        | _ -> None)
     | _ -> None)
  | _ -> None
;;

let hover_value = function
  | `Assoc fields ->
    (match List.assoc_opt "contents" fields with
     | Some contents -> string_field "value" contents
     | None -> None)
  | _ -> None
;;

let test_annotation_json_preserves_route_context () =
  match Types.annotation_of_json (Types.annotation_to_json route_annotation) with
  | Error msg -> fail msg
  | Ok decoded ->
    check (option string) "board post" route_annotation.board_post_id decoded.board_post_id;
    check (option string) "comment" route_annotation.comment_id decoded.comment_id;
    check (option string) "pr" route_annotation.pr_id decoded.pr_id;
    check (option string) "git" route_annotation.git_ref decoded.git_ref;
    check (option string) "log" route_annotation.log_id decoded.log_id;
    check (option string) "session" route_annotation.session_id decoded.session_id;
    check (option string) "operation" route_annotation.operation_id decoded.operation_id;
    check (option string) "worker" route_annotation.worker_run_id decoded.worker_run_id
;;

let test_create_lists_route_context () =
  with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"sangsu"
        ~file_path:"lib/keeper/keeper_exec_ide.ml"
        ~line_start:12
        ~line_end:14
        ~kind:Types.Question
        ~content:"Should this trace be attached to the PR review?"
        ~goal_id:"goal-ide"
        ~task_id:"task-42"
        ~board_post_id:"post-1"
        ~comment_id:"comment-1"
        ~pr_id:"15035"
        ~git_ref:"feat/context-lens"
        ~log_id:"turn-9"
        ~session_id:"sess-9"
        ~operation_id:"op-9"
        ~worker_run_id:"wr-9"
        ()
    with
    | Error msg -> fail msg
    | Ok created ->
      check (option string) "created pr" (Some "15035") created.pr_id;
      let filter =
        { Types.file_path = Some "lib/keeper/keeper_exec_ide.ml"
        ; keeper_id = None
        ; goal_id = None
        ; task_id = None
        }
      in
      (match Store.list ~base_dir ~filter () with
       | [ listed ] ->
         check string "id" created.id listed.id;
         check (option string) "listed comment" (Some "comment-1") listed.comment_id;
         check (option string) "listed log" (Some "turn-9") listed.log_id
       | rows -> failf "expected one listed annotation, got %d" (List.length rows)))
;;

let test_lsp_overlay_exposes_route_context () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"sangsu"
        ~file_path:"lib/keeper/keeper_exec_ide.ml"
        ~line_start:12
        ~line_end:14
        ~kind:Types.Question
        ~content:"Should this trace be attached to the PR review?"
        ~goal_id:"goal-ide"
        ~task_id:"task-42"
        ~board_post_id:"post-1"
        ~comment_id:"comment-1"
        ~pr_id:"15035"
        ~git_ref:"feat/context-lens"
        ~log_id:"turn-9"
        ~session_id:"sess-9"
        ~operation_id:"op-9"
        ~worker_run_id:"wr-9"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      Lsp.clear_cache ();
      let codelenses =
        Lsp.codelenses ~base_dir ~file_path:"lib/keeper/keeper_exec_ide.ml"
      in
      (match codelenses with
       | [ codelens ] ->
         let title = Option.value ~default:"" (codelens_title codelens) in
         check_contains "codelens carries PR route" "PR:15035" title;
         check_contains "codelens carries log route" "log:turn-9" title
       | rows -> failf "expected one codelens, got %d" (List.length rows));
      let inlay_hints =
        Lsp.inlay_hints ~base_dir ~file_path:"lib/keeper/keeper_exec_ide.ml"
      in
      (match inlay_hints with
       | [ hint ] ->
         let label = Option.value ~default:"" (string_field "label" hint) in
         let tooltip = Option.value ~default:"" (string_field "tooltip" hint) in
         check_contains "inlay carries task route" "task:task-42" label;
         check_contains "inlay carries telemetry route" "worker:wr-9" label;
         check_contains "inlay tooltip carries comment route" "comment:comment-1" tooltip
       | rows -> failf "expected one inlay hint, got %d" (List.length rows));
      let diagnostics =
        Lsp.diagnostics
          ~base_dir
          ~file_path:"lib/keeper/keeper_exec_ide.ml"
          ~lsp_diagnostics:[]
      in
      (match diagnostics with
       | [ diagnostic ] ->
         let message = Option.value ~default:"" (string_field "message" diagnostic) in
         check_contains "diagnostic carries git route" "git:feat/context-lens" message
       | rows -> failf "expected one diagnostic, got %d" (List.length rows));
      let hover =
        Lsp.enrich_hover
          ~base_dir
          ~file_path:"lib/keeper/keeper_exec_ide.ml"
          ~line:11
          (`Assoc
             [ "contents"
             , `Assoc [ "kind", `String "markdown"; "value", `String "Base hover" ]
             ])
      in
      let value = Option.value ~default:"" (hover_value hover) in
      check_contains "hover carries board route" "board:post-1" value;
      check_contains "hover carries operation route" "op:op-9" value))
;;

let test_region_tracker_writes_fixed_regions_file () =
  with_temp_dir (fun base_dir ->
    Region.ingest_tool_call
      ~base_dir
      ~keeper_id:"sangsu"
      ~turn:7
      (`Assoc
        [ "name", `String "write_file"
        ; ( "arguments"
          , `Assoc
              [ "path", `String "lib/a.ml"
              ; "content", `String "let x = 1\n"
              ] )
        ]);
    check bool "fixed regions file exists" true (Sys.file_exists (Region.regions_file ~base_dir ()));
    match load_regions base_dir with
    | [ region ] ->
      check string "file path" "lib/a.ml" region.Types.file_path;
      check int "line start" 1 region.line_start;
      check int "line end" 1 region.line_end;
      check string "keeper" "sangsu" region.keeper_id;
      (match region.source with
       | Types.Tool_call { tool_name; turn } ->
         check string "tool name" "write_file" tool_name;
         check int "turn" 7 turn
       | Types.Manual _ -> fail "expected tool-call source")
    | rows -> failf "expected one region, got %d" (List.length rows))
;;

let test_meta_sync_flush_writes_fixed_regions_file () =
  with_temp_dir (fun base_dir ->
    let config = { Sync.default_config with base_path = base_dir } in
    let state =
      Sync.on_tool_call_complete
        config
        Sync.initial_state
        ~keeper_id:"sangsu"
        ~turn:8
        ~tool_name:"write_file"
        ~file_path:"lib/b.ml"
        ~diff_text:None
        ~full_content:(Some "let y = 2\n")
    in
    let state = Sync.flush_regions config state in
    let stats = Sync.get_stats state in
    check int "pending regions cleared" 0 stats.pending_region_count;
    check bool "fixed regions file exists" true (Sys.file_exists (Region.regions_file ~base_dir ()));
    match load_regions base_dir with
    | [ region ] ->
      check string "file path" "lib/b.ml" region.Types.file_path;
      check string "keeper" "sangsu" region.keeper_id;
      (match region.source with
       | Types.Tool_call { tool_name; turn } ->
         check string "tool name" "write_file" tool_name;
         check int "turn" 8 turn
       | Types.Manual _ -> fail "expected tool-call source")
    | rows -> failf "expected one region, got %d" (List.length rows))
;;

(* RFC-0128 §4.2 — partition-aware store routing. *)

let make_filter () : Types.annotation_filter =
  { file_path = None; keeper_id = None; goal_id = None; task_id = None }

let create_in_partition ~base_dir ~partition ~kind ~content () =
  Store.create
    ~base_dir
    ~partition
    ~keeper_id:"sangsu"
    ~file_path:"lib/foo.ml"
    ~line_start:1
    ~line_end:3
    ~kind
    ~content
    ()
;;

let test_create_by_url_isolates_from_legacy () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let _ =
      create_in_partition
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~kind:Types.Comment
        ~content:"in by-url"
        ()
    in
    let by_url =
      Store.list
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~filter:(make_filter ())
        ()
    in
    let legacy = Store.list ~base_dir ~filter:(make_filter ()) () in
    check int "by-url count" 1 (List.length by_url);
    check int "legacy is empty" 0 (List.length legacy))
;;

let test_create_orphan_separates_from_by_url () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let _ =
      create_in_partition
        ~base_dir
        ~partition:Ide_paths.Orphan
        ~kind:Types.Comment
        ~content:"orphan record"
        ()
    in
    let _ =
      create_in_partition
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~kind:Types.Comment
        ~content:"by-url record"
        ()
    in
    let by_url =
      Store.list
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~filter:(make_filter ())
        ()
    in
    let orphan =
      Store.list ~base_dir ~partition:Ide_paths.Orphan ~filter:(make_filter ()) ()
    in
    check int "by-url count" 1 (List.length by_url);
    check int "orphan count" 1 (List.length orphan);
    let by_url_content = (List.hd by_url).content in
    let orphan_content = (List.hd orphan).content in
    check string "by-url content" "by-url record" by_url_content;
    check string "orphan content" "orphan record" orphan_content)
;;

let test_legacy_default_is_unchanged () =
  with_temp_dir (fun base_dir ->
    (* No ?partition argument → defaults to Legacy → writes to the
       historical flat path. PR-1c will flip the keeper write path,
       but until then existing behaviour MUST remain. *)
    let _ =
      Store.create
        ~base_dir
        ~keeper_id:"sangsu"
        ~file_path:"lib/foo.ml"
        ~line_start:1
        ~line_end:3
        ~kind:Types.Comment
        ~content:"legacy default"
        ()
    in
    let legacy_path =
      Filename.concat
        (Ide_paths.partition_store_dir ~base_dir Ide_paths.Legacy)
        "annotations.jsonl"
    in
    check bool "legacy file exists" true (Sys.file_exists legacy_path);
    let legacy = Store.list ~base_dir ~filter:(make_filter ()) () in
    check int "legacy count" 1 (List.length legacy))
;;

let test_delete_partition_scoped () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let by_url =
      Result.get_ok
        (create_in_partition
           ~base_dir
           ~partition:(Ide_paths.By_url slug)
           ~kind:Types.Comment
           ~content:"to delete"
           ())
    in
    (* Delete in matching partition succeeds; same id in Legacy fails. *)
    let in_legacy =
      Store.delete
        ~base_dir
        ~partition:Ide_paths.Legacy
        ~id:by_url.id
        ~keeper_id:"sangsu"
        ()
    in
    (match in_legacy with
     | Ok () -> fail "Legacy delete must miss when annotation lives in By_url"
     | Error _ -> ());
    let in_by_url =
      Store.delete
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~id:by_url.id
        ~keeper_id:"sangsu"
        ()
    in
    (match in_by_url with
     | Ok () -> ()
     | Error msg -> failf "By_url delete failed: %s" msg))
;;

let test_region_append_by_url_isolates_from_legacy () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let region : Types.code_region =
      { keeper_id = "sangsu"
      ; file_path = "lib/foo.ml"
      ; line_start = 1
      ; line_end = 5
      ; source = Types.Tool_call { tool_name = "write_file"; turn = 0 }
      ; timestamp_ms = 1L
      }
    in
    Region.append_region ~base_dir ~partition:(Ide_paths.By_url slug) region;
    let by_url_path = Region.regions_file ~base_dir ~partition:(Ide_paths.By_url slug) () in
    let legacy_path = Region.regions_file ~base_dir () in
    check bool "by-url regions exists" true (Sys.file_exists by_url_path);
    check bool "legacy regions absent" false (Sys.file_exists legacy_path))
;;

(* RFC-0128 PR-1e — content fallback + single-write invariant.

   Before PR-1e, edit_file tool_calls with no diff/patch argument
   produced zero regions in Ide_region_tracker.ingest_tool_call. The
   missing record was previously synthesised by Ide_meta_sync.flush_regions,
   which wrote to the Legacy partition while ingest_tool_call (post
   PR-1c) wrote to the resolved partition — a double-write of the
   same region across two buckets. PR-1e moves the content fallback
   into ingest_tool_call itself and removes the meta_sync call site
   from track_write_region, restoring a single source of truth. *)

let count_lines path =
  if not (Sys.file_exists path) then 0
  else (
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let n = ref 0 in
        try
          while true do
            ignore (input_line ic);
            incr n
          done;
          !n
        with End_of_file -> !n))
;;

let test_ingest_edit_file_content_fallback () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    (* edit_file with only path + content (no diff, no patch). Before
       PR-1e this dropped regions silently. *)
    let json =
      `Assoc
        [ "name", `String "edit_file"
        ; "arguments"
        , `Assoc
            [ "path", `String "lib/foo.ml"
            ; "content", `String "line one\nline two\nline three\n"
            ; "old_string", `String "line one"
            ; "new_string", `String "LINE ONE"
            ]
        ]
    in
    Region.ingest_tool_call
      ~base_dir
      ~partition:(Ide_paths.By_url slug)
      ~keeper_id:"sangsu"
      ~turn:1
      json;
    let by_url_path =
      Region.regions_file ~base_dir ~partition:(Ide_paths.By_url slug) ()
    in
    check int "edit_file content fallback emits one region" 1 (count_lines by_url_path))
;;

(* RFC-0128 §5 PR-2 — read-side multi-source merge. *)

let test_list_merge_legacy_surfaces_old_records () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let _ =
      create_in_partition
        ~base_dir
        ~partition:Ide_paths.Legacy
        ~kind:Types.Comment
        ~content:"legacy record"
        ()
    in
    let _ =
      create_in_partition
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~kind:Types.Comment
        ~content:"by-url record"
        ()
    in
    let no_merge =
      Store.list
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~filter:(make_filter ())
        ()
    in
    check int "no-merge sees only by-url" 1 (List.length no_merge);
    let merged =
      Store.list
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~merge_legacy:true
        ~filter:(make_filter ())
        ()
    in
    check int "merge surfaces legacy + by-url" 2 (List.length merged))
;;

let test_list_merge_dedup_primary_wins () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let by_url =
      Result.get_ok
        (create_in_partition
           ~base_dir
           ~partition:(Ide_paths.By_url slug)
           ~kind:Types.Comment
           ~content:"primary content"
           ())
    in
    let legacy_clone =
      Types.{ by_url with content = "legacy content (older)"; created_at_ms = 0L }
    in
    Fs_compat.append_jsonl
      (Filename.concat
         (Ide_paths.partition_store_dir ~base_dir Ide_paths.Legacy)
         "annotations.jsonl")
      (Types.annotation_to_json legacy_clone);
    let merged =
      Store.list
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~merge_legacy:true
        ~filter:(make_filter ())
        ()
    in
    check int "no duplicate on id collision" 1 (List.length merged);
    let winner = List.hd merged in
    check string "primary content wins" "primary content" winner.content)
;;

let test_list_merge_noop_when_partition_is_legacy () =
  with_temp_dir (fun base_dir ->
    let _ =
      create_in_partition
        ~base_dir
        ~partition:Ide_paths.Legacy
        ~kind:Types.Comment
        ~content:"only legacy"
        ()
    in
    let merged =
      Store.list
        ~base_dir
        ~partition:Ide_paths.Legacy
        ~merge_legacy:true
        ~filter:(make_filter ())
        ()
    in
    check int "Legacy + merge is a single read" 1 (List.length merged))
;;

let test_read_regions_merge_legacy_surfaces_old () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let mk_region ~ts ~src : Types.code_region =
      { keeper_id = "sangsu"
      ; file_path = "lib/foo.ml"
      ; line_start = 1
      ; line_end = 3
      ; source = Types.Tool_call { tool_name = src; turn = 0 }
      ; timestamp_ms = ts
      }
    in
    Region.append_region
      ~base_dir
      ~partition:Ide_paths.Legacy
      (mk_region ~ts:1L ~src:"write_file");
    Region.append_region
      ~base_dir
      ~partition:(Ide_paths.By_url slug)
      (mk_region ~ts:2L ~src:"edit_file");
    let primary_only =
      Region.read_regions ~base_dir ~partition:(Ide_paths.By_url slug) ()
    in
    let merged =
      Region.read_regions
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~merge_legacy:true
        ()
    in
    check int "primary-only sees by-url only" 1 (List.length primary_only);
    check int "merge sees both" 2 (List.length merged))
;;

let test_read_regions_dedup_structural_key () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let region : Types.code_region =
      { keeper_id = "sangsu"
      ; file_path = "lib/foo.ml"
      ; line_start = 1
      ; line_end = 5
      ; source = Types.Tool_call { tool_name = "write_file"; turn = 0 }
      ; timestamp_ms = 1L
      }
    in
    Region.append_region ~base_dir ~partition:Ide_paths.Legacy region;
    Region.append_region ~base_dir ~partition:(Ide_paths.By_url slug) region;
    let merged =
      Region.read_regions
        ~base_dir
        ~partition:(Ide_paths.By_url slug)
        ~merge_legacy:true
        ()
    in
    check int "structural dedup collapses duplicates" 1 (List.length merged))
;;

let test_ingest_no_double_write () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    (* The same tool_call must produce exactly one region in the chosen
       partition and zero in Legacy. Regression guard for the
       meta_sync/ingest double-write that PR-1e closed. *)
    let json =
      `Assoc
        [ "name", `String "write_file"
        ; "arguments"
        , `Assoc
            [ "path", `String "lib/foo.ml"
            ; "content", `String "alpha\nbeta\ngamma\n"
            ]
        ]
    in
    Region.ingest_tool_call
      ~base_dir
      ~partition:(Ide_paths.By_url slug)
      ~keeper_id:"sangsu"
      ~turn:0
      json;
    let by_url_path =
      Region.regions_file ~base_dir ~partition:(Ide_paths.By_url slug) ()
    in
    let legacy_path = Region.regions_file ~base_dir () in
    check int "by-url has one region" 1 (count_lines by_url_path);
    check int "legacy has zero regions" 0 (count_lines legacy_path))
;;

let () =
  run
    "ide_annotations"
    [ ( "route_context"
      , [ test_case
            "annotation json preserves route context"
            `Quick
            test_annotation_json_preserves_route_context
        ; test_case "create/list preserves route context" `Quick test_create_lists_route_context
        ; test_case
            "LSP overlays expose route context"
            `Quick
            test_lsp_overlay_exposes_route_context
        ; test_case
            "region tracker writes fixed regions.jsonl"
            `Quick
            test_region_tracker_writes_fixed_regions_file
        ; test_case
            "meta sync flush writes fixed regions.jsonl"
            `Quick
            test_meta_sync_flush_writes_fixed_regions_file
        ] )
    ; ( "partition (RFC-0128)"
      , [ test_case
            "create By_url isolates from Legacy"
            `Quick
            test_create_by_url_isolates_from_legacy
        ; test_case
            "Orphan and By_url are separate buckets"
            `Quick
            test_create_orphan_separates_from_by_url
        ; test_case
            "Legacy default is unchanged"
            `Quick
            test_legacy_default_is_unchanged
        ; test_case
            "delete is partition-scoped"
            `Quick
            test_delete_partition_scoped
        ; test_case
            "append_region By_url isolates from Legacy"
            `Quick
            test_region_append_by_url_isolates_from_legacy
        ; test_case
            "edit_file ingest content fallback emits one region (PR-1e)"
            `Quick
            test_ingest_edit_file_content_fallback
        ; test_case
            "ingest no double-write across partitions (PR-1e)"
            `Quick
            test_ingest_no_double_write
        ; test_case
            "list merge_legacy surfaces old records (PR-2)"
            `Quick
            test_list_merge_legacy_surfaces_old_records
        ; test_case
            "list merge dedup — primary wins (PR-2)"
            `Quick
            test_list_merge_dedup_primary_wins
        ; test_case
            "list merge is no-op when partition=Legacy (PR-2)"
            `Quick
            test_list_merge_noop_when_partition_is_legacy
        ; test_case
            "read_regions merge_legacy surfaces old (PR-2)"
            `Quick
            test_read_regions_merge_legacy_surfaces_old
        ; test_case
            "read_regions structural dedup (PR-2)"
            `Quick
            test_read_regions_dedup_structural_key
        ] )
    ]
;;
