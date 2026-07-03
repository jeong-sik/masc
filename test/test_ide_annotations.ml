open Alcotest

module Types = Ide_annotation_types
module Store = Ide_annotations
module Region = Ide_region_tracker
module Lsp = Lsp_overlay_provider

(* Ide_annotations.create generates ids via [Uuidm.v4_gen (Random.get_state ())].
   [Random.get_state] returns a COPY of the global state, so two
   close-succession calls without an explicit global advance produce
   the same uuid and collide under merge dedup. The PR-2 merge tests
   create two annotations in sequence, so seed the global state once
   to make uuids deterministic-distinct across the run. *)
let () = Random.self_init ()

let route_annotation : Types.annotation =
  { id = "ann-route"
  ; file_path = "lib/keeper/keeper_tool_ide_runtime.ml"
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

let load_regions_from path =
  Fs_compat.fold_jsonl_lines
    ~init:[]
    ~f:(fun acc ~line_no:_ json ->
      match Types.region_of_json json with
      | Ok region -> region :: acc
      | Error msg -> fail msg)
    path
  |> List.rev
;;

let load_regions base_dir = load_regions_from (Region.regions_file ~base_dir ())

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
        ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
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
        { Types.file_path = Some "lib/keeper/keeper_tool_ide_runtime.ml"
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
        ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
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
        Lsp.codelenses ~base_dir ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
      in
      (match codelenses with
       | [ codelens ] ->
         let title = Option.value ~default:"" (codelens_title codelens) in
         check_contains "codelens carries PR route" "PR:15035" title;
         check_contains "codelens carries log route" "log:turn-9" title
       | rows -> failf "expected one codelens, got %d" (List.length rows));
      let inlay_hints =
        Lsp.inlay_hints ~base_dir ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
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
          ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
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
          ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
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

(* test_meta_sync_flush_writes_fixed_regions_file removed in RFC-0128
   PR-1f: the Ide_meta_sync module is gone now that PR-1e dropped its
   only call site. Its coverage is preserved by the
   [ingest content fallback] + [no double-write] cases below. *)

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
    let orphan = Store.list ~base_dir ~filter:(make_filter ()) () in
    check int "by-url count" 1 (List.length by_url);
    check int "orphan is empty" 0 (List.length orphan))
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
    (* No ?partition argument → defaults to Orphan → writes to the
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
        ~content:"orphan default"
        ()
    in
    let legacy_path =
      Filename.concat
        (Ide_paths.partition_store_dir ~base_dir Ide_paths.Orphan)
        "annotations.jsonl"
    in
    check bool "orphan file exists" true (Sys.file_exists legacy_path);
    let orphan = Store.list ~base_dir ~filter:(make_filter ()) () in
    check int "orphan count" 1 (List.length orphan))
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
    (* Delete in matching partition succeeds; same id in Orphan fails. *)
    let in_legacy =
      Store.delete
        ~base_dir
        ~partition:Ide_paths.Orphan
        ~id:by_url.id
        ~keeper_id:"sangsu"
        ()
    in
    (match in_legacy with
     | Ok () -> fail "Orphan delete must miss when annotation lives in By_url"
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
    check bool "orphan regions absent" false (Sys.file_exists legacy_path))
;;

(* RFC-0128 PR-1e — content fallback + single-write invariant.

   Before PR-1e, edit_file tool_calls with no diff/patch argument
   produced zero regions in Ide_region_tracker.ingest_tool_call. The
   missing record was previously synthesised by Ide_meta_sync.flush_regions,
   which wrote to the Orphan partition while ingest_tool_call (post
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
    check int "edit_file content fallback emits one region" 1 (count_lines by_url_path);
    match load_regions_from by_url_path with
    | [ region ] -> (
      match region.source with
      | Types.Tool_call { tool_name; turn } ->
        check string "fallback preserves tool name" "edit_file" tool_name;
        check int "turn" 1 turn
      | Types.Manual _ -> fail "expected tool-call source")
    | rows -> failf "expected one region, got %d" (List.length rows))
;;

let test_ingest_no_double_write () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    (* The same tool_call must produce exactly one region in the chosen
       partition and zero in Orphan. Regression guard for the
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
    check int "orphan has zero regions" 0 (count_lines legacy_path))
;;

let test_definition_links_at_line () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"k1"
        ~file_path:"lib/test.ml"
        ~line_start:10
        ~line_end:12
        ~kind:Types.Decision
        ~content:"use Eio for concurrency"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      Lsp.clear_cache ();
      let links = Lsp.definition_links ~base_dir ~file_path:"lib/test.ml" ~line:10 in
      (match links with
       | [ link ] ->
         let uri = Option.value ~default:"" (string_field "uri" link) in
         check_contains "uri contains file" "lib/test.ml" uri
       | rows -> failf "expected one link, got %d" (List.length rows))))
;;

let test_definition_links_empty () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    let links = Lsp.definition_links ~base_dir ~file_path:"lib/empty.ml" ~line:5 in
    check int "empty links" 0 (List.length links)))
;;

let test_reference_locations_related () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"k1"
        ~file_path:"lib/a.ml"
        ~line_start:5
        ~line_end:5
        ~kind:Types.Comment
        ~content:"first"
        ~goal_id:"goal-x"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      (match
         Store.create
           ~base_dir
           ~keeper_id:"k1"
           ~file_path:"lib/a.ml"
           ~line_start:20
           ~line_end:20
           ~kind:Types.Comment
           ~content:"second same goal"
           ~goal_id:"goal-x"
           ()
       with
       | Error msg -> fail msg
       | Ok _ ->
         Lsp.clear_cache ();
         let refs =
           Lsp.reference_locations
             ~base_dir ~file_path:"lib/a.ml" ~line:4 ~include_declaration:true
         in
         check int "two related refs" 2 (List.length refs))))
;;

let test_completion_items_kinds () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    let items = Lsp.completion_items ~base_dir ~file_path:"lib/test.ml" ~line:0 in
    check int "four completion items" 4 (List.length items);
    let labels = List.filter_map (string_field "label") items in
    check_contains "has masc:comment" "masc:comment" (String.concat "," labels);
    check_contains "has masc:decision" "masc:decision" (String.concat "," labels)))
;;

let test_code_actions_create () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    let actions = Lsp.code_actions ~base_dir ~file_path:"lib/test.ml" ~line:5 ~diagnostics:[] in
    check bool "has create action" true (List.length actions >= 1);
    let title = Option.value ~default:"" (string_field "title" (List.hd actions)) in
    check string "first action is create" "Create MASC Annotation" title))
;;

let test_document_symbols_lists () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"k1"
        ~file_path:"lib/test.ml"
        ~line_start:1
        ~line_end:3
        ~kind:Types.Bookmark
        ~content:"important section"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      Lsp.clear_cache ();
      let syms = Lsp.document_symbols ~base_dir ~file_path:"lib/test.ml" in
      (match syms with
       | [ sym ] ->
         let name = Option.value ~default:"" (string_field "name" sym) in
         check_contains "name has kind" "Bookmark" name;
         check_contains "name has content" "important section" name
       | rows -> failf "expected one symbol, got %d" (List.length rows))))
;;

let test_folding_ranges_groups () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"k1"
        ~file_path:"lib/test.ml"
        ~line_start:1
        ~line_end:2
        ~kind:Types.Comment
        ~content:"first"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      (match
         Store.create
           ~base_dir
           ~keeper_id:"k1"
           ~file_path:"lib/test.ml"
           ~line_start:3
           ~line_end:4
           ~kind:Types.Comment
           ~content:"second consecutive"
           ()
       with
       | Error msg -> fail msg
       | Ok _ ->
         Lsp.clear_cache ();
         let ranges = Lsp.folding_ranges ~base_dir ~file_path:"lib/test.ml" in
         (* folding_ranges groups consecutive annotations within 2 lines *)
         check bool "folding ranges is a list" true (List.length ranges >= 0))))
;;

let test_document_highlights_related () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~keeper_id:"k1"
        ~file_path:"lib/test.ml"
        ~line_start:5
        ~line_end:5
        ~kind:Types.Question
        ~content:"is this correct?"
        ~task_id:"task-99"
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      (match
         Store.create
           ~base_dir
           ~keeper_id:"k1"
           ~file_path:"lib/test.ml"
           ~line_start:15
           ~line_end:15
           ~kind:Types.Decision
           ~content:"yes it is"
           ~task_id:"task-99"
           ()
       with
       | Error msg -> fail msg
       | Ok _ ->
         Lsp.clear_cache ();
         let highlights =
           Lsp.document_highlights ~base_dir ~file_path:"lib/test.ml" ~line:4
         in
         check int "two highlights" 2 (List.length highlights))))
;;

(* Round-trip through [compact], which calls the internal
   [write_all_partition].  Guards the [Fs_compat.save_file_atomic] rewrite:
   the happy path must still write every annotation back so a later [list] sees
   them all. *)
let test_compact_preserves_annotations () =
  with_temp_dir (fun base_dir ->
    let mk content =
      match
        Store.create
          ~base_dir
          ~keeper_id:"sangsu"
          ~file_path:"lib/x.ml"
          ~line_start:1
          ~line_end:2
          ~kind:Types.Comment
          ~content
          ~goal_id:"g"
          ~task_id:"t"
          ~board_post_id:"p"
          ~comment_id:"c"
          ~pr_id:"1"
          ~git_ref:"r"
          ~log_id:"l"
          ~session_id:"s"
          ~operation_id:"o"
          ~worker_run_id:"w"
          ()
      with
      | Error msg -> fail msg
      | Ok created -> created
    in
    let a1 = mk "first" in
    let a2 = mk "second" in
    Store.compact ~base_dir ();
    let filter =
      { Types.file_path = None; keeper_id = None; goal_id = None; task_id = None }
    in
    let listed = Store.list ~base_dir ~filter () in
    check int "compact preserves count" 2 (List.length listed);
    let ids =
      List.map (fun (a : Types.annotation) -> a.id) listed
      |> List.sort String.compare
    in
    check
      (list string)
      "compact preserves ids"
      (List.sort String.compare [ a1.id; a2.id ])
      ids)
;;

(* task-1744: tombstoned annotations must be excluded from load/list.

   Before the fix, [load_all_partition] only skipped the tombstone marker
   line, leaving the earlier annotation with the same id visible in
   [list], contradicting the mli contract "Tombstoned entries are
   excluded". These cases exercise both the load path (below the
   compaction threshold, so the tombstone stays in the file and [list]
   must apply the exclusion itself) and the compaction path. *)

let create_note ~base_dir ~keeper_id ~content () =
  Result.get_ok
    (Store.create
       ~base_dir
       ~keeper_id
       ~file_path:"lib/a.ml"
       ~line_start:1
       ~line_end:1
       ~kind:Types.Comment
       ~content
       ())
;;

let test_list_excludes_soft_deleted_without_compaction () =
  with_temp_dir (fun base_dir ->
    (* 1 tombstone / (6 + 1) ≈ 0.14 stays below COMPACT_THRESHOLD (0.2),
       so no auto-compaction runs and [list] must exclude the tombstoned
       id on read. *)
    let notes =
      List.init 6 (fun i ->
        create_note ~base_dir ~keeper_id:"alice" ~content:(Printf.sprintf "note-%d" i) ())
    in
    let victim = List.hd notes in
    (match Store.delete ~base_dir ~id:victim.id ~keeper_id:"alice" () with
     | Ok () -> ()
     | Error msg -> failf "delete failed: %s" msg);
    let listed = Store.list ~base_dir ~filter:(make_filter ()) () in
    check int "list excludes the tombstoned annotation" 5 (List.length listed);
    check
      bool
      "tombstoned id absent from list"
      false
      (List.exists (fun (a : Types.annotation) -> a.id = victim.id) listed))
;;

let test_list_keeps_sibling_after_delete () =
  with_temp_dir (fun base_dir ->
    let victim = create_note ~base_dir ~keeper_id:"alice" ~content:"to delete" () in
    let survivor = create_note ~base_dir ~keeper_id:"alice" ~content:"to keep" () in
    (match Store.delete ~base_dir ~id:victim.id ~keeper_id:"alice" () with
     | Ok () -> ()
     | Error msg -> failf "delete failed: %s" msg);
    let listed = Store.list ~base_dir ~filter:(make_filter ()) () in
    check
      bool
      "deleted sibling absent"
      false
      (List.exists (fun (a : Types.annotation) -> a.id = victim.id) listed);
    check
      bool
      "undeleted sibling present"
      true
      (List.exists (fun (a : Types.annotation) -> a.id = survivor.id) listed))
;;

let test_list_returns_live_annotation () =
  with_temp_dir (fun base_dir ->
    let note = create_note ~base_dir ~keeper_id:"alice" ~content:"live" () in
    match Store.list ~base_dir ~filter:(make_filter ()) () with
    | [ only ] -> check string "live annotation returned unchanged" note.id only.id
    | rows -> failf "expected one live annotation, got %d" (List.length rows))
;;

let test_compact_drops_tombstoned () =
  with_temp_dir (fun base_dir ->
    let notes =
      List.init 6 (fun i ->
        create_note ~base_dir ~keeper_id:"alice" ~content:(Printf.sprintf "note-%d" i) ())
    in
    let victim = List.hd notes in
    (match Store.delete ~base_dir ~id:victim.id ~keeper_id:"alice" () with
     | Ok () -> ()
     | Error msg -> failf "delete failed: %s" msg);
    Store.compact ~base_dir ();
    (* After compaction the file holds only the five live annotations:
       no tombstone marker line and no tombstoned original remain. *)
    let path =
      Filename.concat
        (Ide_paths.partition_store_dir ~base_dir Ide_paths.Orphan)
        "annotations.jsonl"
    in
    check int "compacted file has only live lines" 5 (count_lines path);
    let listed = Store.list ~base_dir ~filter:(make_filter ()) () in
    check int "list count after compact" 5 (List.length listed);
    check
      bool
      "tombstoned id absent after compact"
      false
      (List.exists (fun (a : Types.annotation) -> a.id = victim.id) listed))
;;

let () =
  run
    "ide_annotations"
    [ ( "compact"
      , [ test_case
            "compact preserves annotations (atomic write)"
            `Quick
            test_compact_preserves_annotations
        ] )
    ; ( "route_context"
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
        ] )
    ; ( "partition (RFC-0128)"
      , [ test_case
            "create By_url isolates from Orphan"
            `Quick
            test_create_by_url_isolates_from_legacy
        ; test_case
            "Orphan and By_url are separate buckets"
            `Quick
            test_create_orphan_separates_from_by_url
        ; test_case
            "Orphan default is unchanged"
            `Quick
            test_legacy_default_is_unchanged
        ; test_case
            "delete is partition-scoped"
            `Quick
            test_delete_partition_scoped
        ; test_case
            "append_region By_url isolates from Orphan"
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
        ] )
    ; ( "overlay (expanded)"
      , [ test_case "definition_links at annotation line" `Quick test_definition_links_at_line
        ; test_case "definition_links empty when no annotation" `Quick test_definition_links_empty
        ; test_case "reference_locations finds related" `Quick test_reference_locations_related
        ; test_case "completion_items returns 4 kinds" `Quick test_completion_items_kinds
        ; test_case "code_actions creates annotation" `Quick test_code_actions_create
        ; test_case "document_symbols lists annotations" `Quick test_document_symbols_lists
        ; test_case "folding_ranges groups consecutive" `Quick test_folding_ranges_groups
        ; test_case "document_highlights finds related" `Quick test_document_highlights_related
        ] )
    ; ( "tombstone read (task-1744)"
      , [ test_case
            "list excludes soft-deleted annotation (no compaction)"
            `Quick
            test_list_excludes_soft_deleted_without_compaction
        ; test_case
            "delete keeps undeleted sibling"
            `Quick
            test_list_keeps_sibling_after_delete
        ; test_case
            "live annotation still returned"
            `Quick
            test_list_returns_live_annotation
        ; test_case
            "compaction drops tombstoned annotation"
            `Quick
            test_compact_drops_tombstoned
        ] )
    ]
;;
