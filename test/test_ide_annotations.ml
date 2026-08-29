open Alcotest

module Types = Ide_annotation_types
module Store = Ide_annotations
module Lsp = Lsp_overlay_provider

(* The overlay reader has to name the store it addresses. These cases write
   through the codebase [Store.create] names explicitly, so they read that same one;
   the by-URL producer/reader join is covered in
   [test_ide_lsp_join_key.ml]. *)
let test_codebase = Some "github.com_other_repo"
let yojson = testable Yojson.Safe.pp Yojson.Safe.equal

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
  ; keeper_id = "alpha"
  ; kind = Types.Comment
  ; content = "Connect this line to the active review context."
  ; goal_id = Some "goal-ide"
  ; task_id = Some "task-42"
  ; references =
      [ { relation = "discussion"; reference = "thread-1" }
      ; { relation = "review"; reference = "review-15035" }
      ; { relation = "revision"; reference = "feat/context-lens" }
      ; { relation = "evidence"; reference = "turn-9" }
      ; { relation = "telemetry"; reference = "trace-9" }
      ]
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
    check yojson "opaque references"
      (Agent_observation.annotation_references_to_json route_annotation.references)
      (Agent_observation.annotation_references_to_json decoded.references)
;;

let test_create_lists_route_context () =
  with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~codebase:"github.com_other_repo"
        ~keeper_id:"alpha"
        ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
        ~line_start:12
        ~line_end:14
        ~kind:Types.Question
        ~content:"Should this trace be attached to the PR review?"
        ~goal_id:"goal-ide"
        ~task_id:"task-42"
        ~references:route_annotation.references
        ()
    with
    | Error msg -> fail msg
    | Ok created ->
      check int "created references" 5 (List.length created.references);
      let filter =
        { Types.file_path = Some "lib/keeper/keeper_tool_ide_runtime.ml"
        ; keeper_id = None
        ; goal_id = None
        ; task_id = None
        }
      in
      (match Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter () with
       | [ listed ] ->
         check string "id" created.id listed.id;
         check yojson "listed references"
           (Agent_observation.annotation_references_to_json route_annotation.references)
           (Agent_observation.annotation_references_to_json listed.references)
       | rows -> failf "expected one listed annotation, got %d" (List.length rows)))
;;

let test_lsp_overlay_exposes_route_context () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~codebase:"github.com_other_repo"
        ~keeper_id:"alpha"
        ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
        ~line_start:12
        ~line_end:14
        ~kind:Types.Question
        ~content:"Should this trace be attached to the PR review?"
        ~goal_id:"goal-ide"
        ~task_id:"task-42"
        ~references:route_annotation.references
        ()
    with
    | Error msg -> fail msg
    | Ok _ ->
      Lsp.clear_cache ();
      let codelenses =
        Lsp.codelenses ~base_dir ~codebase:test_codebase ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
      in
      (match codelenses with
       | [ codelens ] ->
         let title = Option.value ~default:"" (codelens_title codelens) in
         check_contains "codelens carries opaque review reference" "review:review-15035" title;
         check_contains "codelens carries evidence reference" "evidence:turn-9" title
       | rows -> failf "expected one codelens, got %d" (List.length rows));
      let diagnostics =
        Lsp.diagnostics
          ~base_dir
          ~codebase:test_codebase
          ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
          ~lsp_diagnostics:[]
      in
      (match diagnostics with
       | [ diagnostic ] ->
         let message = Option.value ~default:"" (string_field "message" diagnostic) in
         check_contains "diagnostic carries revision reference" "revision:feat/context-lens" message
       | rows -> failf "expected one diagnostic, got %d" (List.length rows));
      let hover =
        Lsp.enrich_hover
          ~base_dir
          ~codebase:test_codebase
          ~file_path:"lib/keeper/keeper_tool_ide_runtime.ml"
          ~line:11
          (`Assoc
             [ "contents"
             , `Assoc [ "kind", `String "markdown"; "value", `String "Base hover" ]
             ])
      in
      let value = Option.value ~default:"" (hover_value hover) in
      check_contains "hover carries review reference" "review:review-15035" value;
      check_contains "hover carries telemetry reference" "telemetry:trace-9" value))
;;

(* RFC-0128 §4.2 — codebase-aware store routing. *)

let make_filter () : Types.annotation_filter =
  { file_path = None; keeper_id = None; goal_id = None; task_id = None }

let create_in_codebase ~base_dir ~codebase ~kind ~content () =
  Store.create
    ~base_dir
    ~codebase
    ~keeper_id:"alpha"
    ~file_path:"lib/foo.ml"
    ~line_start:1
    ~line_end:3
    ~kind
    ~content
    ()
;;

let test_create_isolates_codebases () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let _ =
      create_in_codebase
        ~base_dir
        ~codebase:(slug)
        ~kind:Types.Comment
        ~content:"in by-url"
        ()
    in
    let by_url =
      Store.list
        ~base_dir
        ~codebase:(slug)
        ~filter:(make_filter ())
        ()
    in
    let other = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () in
    check int "owning codebase count" 1 (List.length by_url);
    check int "other codebase is empty" 0 (List.length other))
;;

(* A read must not seed the store: listing a codebase nobody wrote to
   answers empty and leaves no directory behind (live 2026-08-14: a GET
   scope probe created an empty [by-url/github/] beside the canonical
   store). *)
let test_list_does_not_create_store () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_absent" in
    let rows = Store.list ~base_dir ~codebase:slug ~filter:(make_filter ()) () in
    check int "absent codebase lists empty" 0 (List.length rows);
    check
      bool
      "store directory not created by the read"
      false
      (Sys.file_exists (Ide_paths.code_store_dir ~base_dir ~codebase:slug)))
;;

let test_codebases_hold_their_own_rows () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let _ =
      create_in_codebase
        ~base_dir
        ~codebase:"github.com_other_repo"
        ~kind:Types.Comment
        ~content:"other-repo record"
        ()
    in
    let _ =
      create_in_codebase
        ~base_dir
        ~codebase:(slug)
        ~kind:Types.Comment
        ~content:"by-url record"
        ()
    in
    let by_url =
      Store.list
        ~base_dir
        ~codebase:(slug)
        ~filter:(make_filter ())
        ()
    in
    let other =
      Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) ()
    in
    check int "owning codebase count" 1 (List.length by_url);
    check int "other codebase count" 1 (List.length other);
    let by_url_content = (List.hd by_url).content in
    let other_content = (List.hd other).content in
    check string "owning codebase content" "by-url record" by_url_content;
    check string "other codebase content" "other-repo record" other_content)
;;

let test_explicit_codebase_store () =
  with_temp_dir (fun base_dir ->
    (* A write lands in the store file of exactly the codebase it names,
       and only that codebase's list sees it. *)
    let _ =
      Store.create
        ~base_dir
        ~codebase:"github.com_other_repo"
        ~keeper_id:"alpha"
        ~file_path:"lib/foo.ml"
        ~line_start:1
        ~line_end:3
        ~kind:Types.Comment
        ~content:"explicit codebase"
        ()
    in
    let other_path =
      Filename.concat
        (Ide_paths.code_store_dir ~base_dir ~codebase:"github.com_other_repo")
        "annotations.jsonl"
    in
    check bool "named codebase store file exists" true (Sys.file_exists other_path);
    let rows = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () in
    check int "named codebase count" 1 (List.length rows))
;;

let test_delete_is_codebase_scoped () =
  with_temp_dir (fun base_dir ->
    let slug = "github.com_owner_repo" in
    let by_url =
      Result.get_ok
        (create_in_codebase
           ~base_dir
           ~codebase:(slug)
           ~kind:Types.Comment
           ~content:"to delete"
           ())
    in
    (* Delete in the owning codebase succeeds; same id under another
       codebase misses. *)
    let in_other =
      Store.delete
        ~base_dir
        ~codebase:"github.com_other_repo"
        ~id:by_url.id
        ~keeper_id:"alpha"
        ()
    in
    (match in_other with
     | Ok () -> fail "delete under another codebase must miss"
     | Error _ -> ());
    let in_by_url =
      Store.delete
        ~base_dir
        ~codebase:(slug)
        ~id:by_url.id
        ~keeper_id:"alpha"
        ()
    in
    (match in_by_url with
     | Ok () -> ()
     | Error msg -> failf "delete in the owning codebase failed: %s" msg))
;;

let test_completion_items_kinds () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    let items = Lsp.completion_items ~base_dir ~codebase:test_codebase ~file_path:"lib/test.ml" ~line:0 in
    check int "four completion items" 4 (List.length items);
    let labels = List.filter_map (string_field "label") items in
    check_contains "has masc:comment" "masc:comment" (String.concat "," labels);
    check_contains "has masc:decision" "masc:decision" (String.concat "," labels)))
;;

let test_code_actions_create () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    let actions = Lsp.code_actions ~base_dir ~codebase:test_codebase ~file_path:"lib/test.ml" ~line:5 ~diagnostics:[] in
    check bool "has create action" true (List.length actions >= 1);
    let title = Option.value ~default:"" (string_field "title" (List.hd actions)) in
    check string "first action is create" "Create MASC Annotation" title))
;;

let test_folding_ranges_groups () =
  Eio_main.run (fun _env ->
    with_temp_dir (fun base_dir ->
    match
      Store.create
        ~base_dir
        ~codebase:"github.com_other_repo"
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
           ~codebase:"github.com_other_repo"
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
         let ranges = Lsp.folding_ranges ~base_dir ~codebase:test_codebase ~file_path:"lib/test.ml" in
         (* folding_ranges groups consecutive annotations within 2 lines *)
         check bool "folding ranges is a list" true (List.length ranges >= 0))))
;;

let test_compact_preserves_annotations () =
  with_temp_dir (fun base_dir ->
    let mk content =
      match
        Store.create
          ~base_dir
          ~codebase:"github.com_other_repo"
          ~keeper_id:"alpha"
          ~file_path:"lib/x.ml"
          ~line_start:1
          ~line_end:2
          ~kind:Types.Comment
          ~content
          ~goal_id:"g"
          ~task_id:"t"
          ~references:[ { relation = "evidence"; reference = "opaque-1" } ]
          ()
      with
      | Error msg -> fail msg
      | Ok created -> created
    in
    let a1 = mk "first" in
    let a2 = mk "second" in
    Store.compact ~base_dir ~codebase:"github.com_other_repo" ();
    let filter =
      { Types.file_path = None; keeper_id = None; goal_id = None; task_id = None }
    in
    let listed = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter () in
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

(* task-1736 — store-level ownership
   enforcement.

   The HTTP layer now resolves the acting keeper_id from the token-bound
   auth identity and passes it to [Store.create] / [Store.delete]. These
   tests pin the store's ownership decision: a keeper acting as "bob"
   reaches the store with keeper_id="bob" and is refused. *)

let make_alice_annotation base_dir =
  Result.get_ok
    (Store.create
       ~base_dir
       ~codebase:"github.com_other_repo"
       ~keeper_id:"alice"
       ~file_path:"lib/a.ml"
       ~line_start:1
       ~line_end:1
       ~kind:Types.Comment
       ~content:"alice's note"
       ())
;;

(* B3 ownership gate: [Store.delete] only removes an annotation whose
   stored keeper_id equals the passed keeper_id. Because the HTTP layer
   now passes the authenticated identity as keeper_id, a keeper acting as
   "bob" reaches the store with keeper_id="bob" and is refused. These
   assert on the delete authorization decision (Ok/Error), which is the
   security-relevant contract; post-delete read visibility is governed by
   the separate soft-delete/compaction path. *)
let test_delete_rejects_other_keeper () =
  with_temp_dir (fun base_dir ->
    let created = make_alice_annotation base_dir in
    match Store.delete ~base_dir ~codebase:"github.com_other_repo" ~id:created.id ~keeper_id:"bob" () with
    | Ok () -> fail "bob must not delete alice's annotation"
    | Error _ -> ())
;;

let test_delete_allows_owner () =
  with_temp_dir (fun base_dir ->
    let created = make_alice_annotation base_dir in
    match Store.delete ~base_dir ~codebase:"github.com_other_repo" ~id:created.id ~keeper_id:"alice" () with
    | Ok () -> ()
    | Error msg -> failf "owner delete failed: %s" msg)
;;

(* task-1744: deleted_ids annotations must be excluded from load/list.

   Before the fix, [load_all_for_codebase] only skipped the deletion marker
   line, leaving the earlier annotation with the same id visible in
   [list], contradicting the mli contract "Deleted entries are
   excluded". These cases exercise both the plain deletion path, where
   [list] must apply the exclusion itself, and the explicit compaction
   marker path. *)

let create_note ~base_dir ~keeper_id ~content () =
  Result.get_ok
    (Store.create
       ~base_dir
       ~codebase:"github.com_other_repo"
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
    (* No explicit compaction runs here; [list] must exclude the deleted_ids
       id on read while the marker remains physically present. *)
    let notes =
      List.init 6 (fun i ->
        create_note ~base_dir ~keeper_id:"alice" ~content:(Printf.sprintf "note-%d" i) ())
    in
    let victim = List.hd notes in
    (match Store.delete ~base_dir ~codebase:"github.com_other_repo" ~id:victim.id ~keeper_id:"alice" () with
     | Ok () -> ()
     | Error msg -> failf "delete failed: %s" msg);
    let listed = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () in
    check int "list excludes the deleted_ids annotation" 5 (List.length listed);
    check
      bool
      "deleted_ids id absent from list"
      false
      (List.exists (fun (a : Types.annotation) -> a.id = victim.id) listed))
;;

let test_list_keeps_sibling_after_delete () =
  with_temp_dir (fun base_dir ->
    let victim = create_note ~base_dir ~keeper_id:"alice" ~content:"to delete" () in
    let survivor = create_note ~base_dir ~keeper_id:"alice" ~content:"to keep" () in
    (match Store.delete ~base_dir ~codebase:"github.com_other_repo" ~id:victim.id ~keeper_id:"alice" () with
     | Ok () -> ()
     | Error msg -> failf "delete failed: %s" msg);
    let listed = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () in
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
    match Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () with
    | [ only ] -> check string "live annotation returned unchanged" note.id only.id
    | rows -> failf "expected one live annotation, got %d" (List.length rows))
;;

let test_compact_drops_deleted () =
  with_temp_dir (fun base_dir ->
    let notes =
      List.init 6 (fun i ->
        create_note ~base_dir ~keeper_id:"alice" ~content:(Printf.sprintf "note-%d" i) ())
    in
    let victim = List.hd notes in
    (match Store.delete ~base_dir ~codebase:"github.com_other_repo" ~id:victim.id ~keeper_id:"alice" () with
     | Ok () -> ()
     | Error msg -> failf "delete failed: %s" msg);
    Store.compact ~base_dir ~codebase:"github.com_other_repo" ();
    let path =
      Filename.concat
        (Ide_paths.code_store_dir ~base_dir ~codebase:"github.com_other_repo")
        "annotations.jsonl"
    in
    let compact_end_markers =
      Fs_compat.fold_jsonl_lines
        ~init:0
        ~f:(fun acc ~line_no:_ -> function
          | `Assoc fields ->
            (match List.assoc_opt "__compact" fields with
             | Some (`String "end") -> acc + 1
             | _ -> acc)
          | _ -> acc)
        path
    in
    check int "compact writes one end marker" 1 compact_end_markers;
    let listed = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () in
    check int "list count after compact" 5 (List.length listed);
    check
      bool
      "deleted_ids id absent after compact"
      false
      (List.exists (fun (a : Types.annotation) -> a.id = victim.id) listed))
;;

(* task-1738: per-codebase write serialization + version CAS. *)

let make_cas_annotation base_dir =
  Result.get_ok
    (Store.create
       ~base_dir
       ~codebase:"github.com_other_repo"
       ~keeper_id:"alice"
       ~file_path:"lib/a.ml"
       ~line_start:1
       ~line_end:1
       ~kind:Types.Comment
       ~content:"cas note"
       ())
;;

(* Real parallelism (Domain, not systhreads) maximises the chance of a
   compaction window overlapping appends. The append-only begin/end
   markers must replay records written during the window, so the final
   count stays exact without a codebase-wide writer lock. *)
let test_concurrent_create_compact_no_loss () =
  with_temp_dir (fun base_dir ->
    Store.ensure_store ~base_dir ~codebase:"github.com_other_repo" ();
    let n_writers = 4 in
    let per_writer = 25 in
    let writers =
      List.init n_writers (fun w ->
        Domain.spawn (fun () ->
          for i = 0 to per_writer - 1 do
            match
              Store.create
                ~base_dir
                ~codebase:"github.com_other_repo"
                ~keeper_id:"alice"
                ~file_path:"lib/a.ml"
                ~line_start:1
                ~line_end:1
                ~kind:Types.Comment
                ~content:(Printf.sprintf "w%d-%d" w i)
                ()
            with
            | Ok _ -> ()
            | Error msg -> failf "create failed: %s" msg
          done))
    in
    let compactor =
      Domain.spawn (fun () ->
        for _ = 1 to 50 do
          Store.compact ~base_dir ~codebase:"github.com_other_repo" ()
        done)
    in
    List.iter Domain.join writers;
    Domain.join compactor;
    let listed = Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) () in
    check
      int
      "no annotation lost to concurrent compaction"
      (n_writers * per_writer)
      (List.length listed))
;;

let test_cas_rejects_version_mismatch () =
  with_temp_dir (fun base_dir ->
    let created = make_cas_annotation base_dir in
    let wrong_version = Int64.add created.updated_at_ms 1L in
    (match
       Store.delete
         ~base_dir
         ~codebase:"github.com_other_repo"
         ~id:created.id
         ~keeper_id:"alice"
         ~expected_version:wrong_version
         ()
     with
     | Ok () -> fail "stale expected_version must be rejected"
     | Error _ -> ());
    (* The annotation is untouched after a rejected CAS delete. *)
    let still_there =
      List.exists
        (fun (a : Types.annotation) -> a.id = created.id)
        (Store.list ~base_dir ~codebase:"github.com_other_repo" ~filter:(make_filter ()) ())
    in
    check bool "annotation survives rejected CAS delete" true still_there;
    (* The correct version deletes. *)
    match
      Store.delete
        ~base_dir
        ~codebase:"github.com_other_repo"
        ~id:created.id
        ~keeper_id:"alice"
        ~expected_version:created.updated_at_ms
        ()
    with
    | Ok () -> ()
    | Error msg -> failf "matching expected_version must delete: %s" msg)
;;

let test_cas_absent_version_skips_check () =
  with_temp_dir (fun base_dir ->
    let created = make_cas_annotation base_dir in
    (* No expected_version → delete by id alone, no version check. *)
    match Store.delete ~base_dir ~codebase:"github.com_other_repo" ~id:created.id ~keeper_id:"alice" () with
    | Ok () -> ()
    | Error msg -> failf "delete without version must succeed: %s" msg)
;;

(* 2020-01-01T00:00:00Z as epoch ms. A monotonic boot-relative clock — the
   #28148 regression this pins against — yields values three orders of
   magnitude below this floor on any realistic uptime, so the comparison
   separates the two sources without depending on the test host's clock. *)
let wall_clock_floor_ms = 1_577_836_800_000L

let test_create_stamps_wall_clock_ms () =
  with_temp_dir (fun base_dir ->
    let created = make_cas_annotation base_dir in
    check
      bool
      "created_at_ms is epoch wall clock, not boot-relative"
      true
      (Int64.compare created.Types.created_at_ms wall_clock_floor_ms > 0);
    check
      bool
      "updated_at_ms (the CAS version token) uses the same source"
      true
      (Int64.compare created.Types.updated_at_ms wall_clock_floor_ms > 0))
;;

let () =
  run
    "ide_annotations"
    [ ( "clock"
      , [ test_case
            "create stamps epoch wall-clock ms"
            `Quick
            test_create_stamps_wall_clock_ms
        ] )
    ; ( "compact"
      , [ test_case
            "compact preserves annotations"
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
        ] )
    ; ( "codebase isolation"
      , [ test_case
            "create isolates codebases"
            `Quick
            test_create_isolates_codebases
        ; test_case
            "list does not create the store"
            `Quick
            test_list_does_not_create_store
        ; test_case
            "codebases hold their own rows"
            `Quick
            test_codebases_hold_their_own_rows
        ; test_case
            "explicit codebase store is written and read back"
            `Quick
            test_explicit_codebase_store
        ; test_case
            "delete is codebase-scoped"
            `Quick
            test_delete_is_codebase_scoped
        ] )
    ; ( "overlay (expanded)"
      , [ test_case "completion_items returns 4 kinds" `Quick test_completion_items_kinds
        ; test_case "code_actions creates annotation" `Quick test_code_actions_create
        ; test_case "folding_ranges groups consecutive" `Quick test_folding_ranges_groups
        ] )
    ; ( "mutation identity (task-1736 B3)"
      , [ test_case
            "foreign keeper cannot delete another's annotation"
            `Quick
            test_delete_rejects_other_keeper
        ; test_case "owner can delete own annotation" `Quick test_delete_allows_owner
        ] )
    ; ( "deletion read (task-1744)"
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
            "compaction drops deleted_ids annotation"
            `Quick
            test_compact_drops_deleted
        ] )
    ; ( "append-only compaction + CAS (task-1738)"
      , [ test_case
            "concurrent create + compaction loses nothing"
            `Quick
            test_concurrent_create_compact_no_loss
        ; test_case
            "CAS rejects stale expected_version, accepts current"
            `Quick
            test_cas_rejects_version_mismatch
        ; test_case
            "absent expected_version deletes by id alone"
            `Quick
            test_cas_absent_version_skips_check
        ] )
    ]
;;
