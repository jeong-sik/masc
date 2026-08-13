(** The join between a keeper's annotation write and the IDE's LSP read.

    [test_ide_canonical_url_join.ml] pins the resolver that decides a write's
    partition and repo-relative path. Nothing pinned that the LSP reader
    addresses the partition the write landed in — so the reader read
    [_orphan/] while keeper writes accumulated under [by-url/<slug>/], and
    every overlay came back empty. These cases pin the reader's half of that
    join. *)

open Alcotest

module Store = Ide_annotations
module Types = Ide_annotation_types
module Lsp = Lsp_overlay_provider

let slug = "github.com_jeong-sik_masc"
let repo_partition = Ide_paths.By_url slug
let file_path = "lib/keeper/keeper_tool_ide_runtime.ml"

(* The overlay cache is guarded by an [Eio.Mutex], so every case runs inside
   an Eio context. *)
let with_temp_dir f =
  Eio_main.run (fun _env ->
    let dir = Filename.temp_dir "masc-ide-join-" "" in
    Fun.protect
      ~finally:(fun () ->
        (* Best effort: the store files live two levels down, and a leftover
           temp dir must not fail the case. *)
        ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir))))
      (fun () -> f dir))
;;

let create_annotation ~base_dir ~partition ~keeper_id ~content ~line =
  match
    Store.create
      ~base_dir
      ~partition
      ~keeper_id
      ~file_path
      ~line_start:line
      ~line_end:line
      ~kind:Types.Decision
      ~content
      ()
  with
  | Ok annotation -> annotation
  | Error msg -> failf "annotation write failed: %s" msg
;;

let codelens_titles ~base_dir ~partition =
  Lsp.codelenses ~base_dir ~partition ~file_path
  |> List.filter_map (fun lens ->
    match lens with
    | `Assoc fields ->
      (match List.assoc_opt "command" fields with
       | Some (`Assoc command) ->
         (match List.assoc_opt "title" command with
          | Some (`String title) -> Some title
          | _ -> None)
       | _ -> None)
    | _ -> None)
;;

(* The defect this file exists for: the write names a by-URL partition and the
   read has to name the same one. A reader that omits the partition (the old
   behaviour, which defaulted to [Legacy_default]) sees nothing. *)
let test_by_url_write_is_read_under_its_partition () =
  with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    ignore
      (create_annotation
         ~base_dir
         ~partition:repo_partition
         ~keeper_id:"analyst"
         ~content:"picked Eio.Mutex over Lazy here"
         ~line:12);
    check
      (list string)
      "the addressed partition yields the keeper's annotation"
      [ "[Decision] picked Eio.Mutex over Lazy here" ]
      (codelens_titles ~base_dir ~partition:(Some repo_partition));
    check
      (list string)
      "the orphan partition does not"
      []
      (codelens_titles ~base_dir ~partition:(Some Ide_paths.Legacy_default))
  )
;;

(* A reader that names no store must read as empty, not as some default
   partition's rows: an LSP connection opened without an IDE scope has not
   said which codebase it is looking at. *)
let test_unaddressed_store_reads_empty () =
  with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    ignore
      (create_annotation
         ~base_dir
         ~partition:Ide_paths.Legacy_default
         ~keeper_id:"analyst"
         ~content:"orphan lane row"
         ~line:3);
    check
      (list string)
      "no partition named, no rows served"
      []
      (codelens_titles ~base_dir ~partition:None)
  )
;;

(* Two partitions hold the same repo-relative path. A cache keyed on
   [base_dir + file_path] alone served one partition's rows for the other's
   request. *)
let test_partitions_do_not_share_cache_entries () =
  with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    ignore
      (create_annotation
         ~base_dir
         ~partition:repo_partition
         ~keeper_id:"analyst"
         ~content:"by-url row"
         ~line:5);
    ignore
      (create_annotation
         ~base_dir
         ~partition:Ide_paths.Legacy_default
         ~keeper_id:"sangsu"
         ~content:"orphan row"
         ~line:5);
    (* Read the by-URL partition first so its rows are the cached ones. *)
    check
      (list string)
      "by-url partition serves its own row"
      [ "[Decision] by-url row" ]
      (codelens_titles ~base_dir ~partition:(Some repo_partition));
    check
      (list string)
      "orphan partition is not served the by-url row"
      [ "[Decision] orphan row" ]
      (codelens_titles ~base_dir ~partition:(Some Ide_paths.Legacy_default))
  )
;;

(* The client that reads this overlay is read-only, so [didSave] never fires
   and the cache never got invalidated. An annotation a keeper writes after
   the reader first touched the file has to become visible anyway. *)
let test_write_after_first_read_becomes_visible () =
  with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    check
      (list string)
      "empty store reads empty"
      []
      (codelens_titles ~base_dir ~partition:(Some repo_partition));
    ignore
      (create_annotation
         ~base_dir
         ~partition:repo_partition
         ~keeper_id:"analyst"
         ~content:"written after the reader cached the empty store"
         ~line:9);
    check
      (list string)
      "the later write is visible without an explicit invalidation"
      [ "[Decision] written after the reader cached the empty store" ]
      (codelens_titles ~base_dir ~partition:(Some repo_partition))
  )
;;

(* A [Location] URI has to point at the document in the tree the reader
   opened. Building it from the directory that holds [.masc-ide] produced a
   path under the store root, which no editor can open. *)
let test_location_uri_uses_the_document_root () =
  with_temp_dir (fun base_dir ->
    Lsp.clear_cache ();
    let document_root = Filename.concat base_dir "worktree" in
    ignore
      (create_annotation
         ~base_dir
         ~partition:repo_partition
         ~keeper_id:"analyst"
         ~content:"anchored"
         ~line:4);
    let uris =
      Lsp.definition_links
        ~base_dir
        ~partition:(Some repo_partition)
        ~document_root
        ~file_path
        ~line:3
      |> List.filter_map (function
        | `Assoc fields ->
          (match List.assoc_opt "uri" fields with
           | Some (`String uri) -> Some uri
           | _ -> None)
        | _ -> None)
    in
    check
      (list string)
      "location resolves under the opened tree, not under the store root"
      [ "file://" ^ Filename.concat document_root file_path ]
      uris
  )
;;

let () =
  run
    "ide_lsp_join_key"
    [ ( "partition addressing"
      , [ test_case
            "by-url write reads under its partition"
            `Quick
            test_by_url_write_is_read_under_its_partition
        ; test_case
            "unaddressed store reads empty"
            `Quick
            test_unaddressed_store_reads_empty
        ; test_case
            "partitions do not share cache entries"
            `Quick
            test_partitions_do_not_share_cache_entries
        ] )
    ; ( "freshness"
      , [ test_case
            "write after first read becomes visible"
            `Quick
            test_write_after_first_read_becomes_visible
        ] )
    ; ( "document root"
      , [ test_case
            "location URI uses the document root"
            `Quick
            test_location_uri_uses_the_document_root
        ] )
    ]
;;
