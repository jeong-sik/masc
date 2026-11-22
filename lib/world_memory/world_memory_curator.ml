open Result.Syntax
open World_memory_types
module Store = World_memory_store

type batch_report =
  { upserted_facts : world_fact list
  ; synthesized_facts : world_fact list
  ; edges_added : world_edge list
  ; digest : world_digest
  ; digest_changed : bool
  }

let process_promotions_sync ~base_path ~now ~keeper_id promotions =
  let* upserted_facts, synthesized_facts, edges_added, digest, digest_changed =
    Store.apply_promotion_batch ~base_path ~now ~keeper_id promotions
  in
  Ok { upserted_facts; synthesized_facts; edges_added; digest; digest_changed }
;;

let supersede_fact_sync ~base_path ~now ~actor ~old_fact_id ~new_fact_id ~reason =
  Store.supersede_fact ~base_path ~now ~actor ~old_fact_id ~new_fact_id ~reason
;;

let builtin_mcp_resource_inputs : Store.index_sync_input list =
  [ { entry_id = "resource:world-memory-claims"
    ; kind = Mcp_resource
    ; title = "World Memory Claims"
    ; uri = "masc://world-memory/claims"
    ; summary = "Lock-free MVCC World Memory facts, edges, and provenance"
    ; facets = [ "mcp_resource"; "world_memory" ]
    ; sha256 = None
    }
  ; { entry_id = "resource:world-memory-digest"
    ; kind = Mcp_resource
    ; title = "World Memory Digest"
    ; uri = "masc://world-memory/digest"
    ; summary = "Immutable compiled World Memory digest revision"
    ; facets = [ "mcp_resource"; "world_memory" ]
    ; sha256 = None
    }
  ; { entry_id = "resource:world-memory-index"
    ; kind = Mcp_resource
    ; title = "World Memory Unified Index"
    ; uri = "masc://world-memory/index"
    ; summary = "Unified index of workspace Wiki pages, published Artifacts, and MCP Resources"
    ; facets = [ "mcp_resource"; "world_memory" ]
    ; sha256 = None
    }
  ; { entry_id = "resource:world-memory-log"
    ; kind = Mcp_resource
    ; title = "World Memory Change Log"
    ; uri = "masc://world-memory/log"
    ; summary = "Sequential audit trail of World Memory mutations"
    ; facets = [ "mcp_resource"; "world_memory" ]
    ; sha256 = None
    }
  ]
;;

(* Collect all Wiki pages under .masc/wiki/ and explicitly published workspace
   artifacts under .masc/artifacts/ (NEVER internal .masc/tool_blobs/ shards)
   inside ONE off-domain Domain_pool job so zero filesystem I/O runs on the
   main Eio domain. *)
let collect_index_inputs_off_domain ~base_path : Store.index_sync_input list =
  Domain_pool_ref.submit_io_or_inline ~name:"world_curator.collect_index_inputs" (fun () ->
    let wiki_inputs =
      let paths =
        try Tool_wiki.list_pages ~base_path with
        | Sys_error _ -> []
      in
      List.filter_map
        (fun path ->
           let file = Filename.basename path in
           let topic =
             if Filename.check_suffix file ".md" then Filename.chop_suffix file ".md" else file
           in
           (* Re-verify lstat S_REG + O_NOFOLLOW + max_page_bytes at read time so
              a symlink swap between list_pages and read can never disclose host
              files or cause unbounded memory allocation. *)
           match Tool_wiki.load_regular_page path with
           | Error _ -> None
           | Ok raw ->
             let sha = Agent_core_sha256.(digest_string raw |> to_hex) in
             let title, summary, facets =
               match Tool_wiki.parse_frontmatter raw with
               | Ok fm ->
                 ( (fm.title :> string)
                 , (fm.summary :> string)
                 , List.map (fun (t : Tool_wiki.Tag.t) -> (t :> string)) fm.tags )
               | Error _ -> topic, "Workspace wiki page", [ "wiki" ]
             in
             Some
               { Store.entry_id = "wiki:" ^ topic
               ; kind = Wiki_page
               ; title
               ; uri = "masc://wiki/" ^ topic
               ; summary
               ; facets
               ; sha256 = Some sha
               })
        paths
    in
    let artifacts_dir =
      Filename.concat (Filename.concat base_path Common.masc_dirname) "artifacts"
    in
    let artifact_inputs =
      if Sys.file_exists artifacts_dir && Sys.is_directory artifacts_dir
      then
        let names =
          try
            Sys.readdir artifacts_dir
            |> Array.to_list
            |> List.filter (fun name -> not (String.starts_with ~prefix:"." name))
            |> List.sort String.compare
          with
          | Sys_error _ -> []
        in
        List.filter_map
          (fun name ->
             let full = Filename.concat artifacts_dir name in
             match Unix.lstat full with
             | exception (Unix.Unix_error _ | Sys_error _) -> None
             | { Unix.st_kind = Unix.S_REG; st_size; st_mtime; _ } ->
               let fingerprint =
                 Printf.sprintf "%s|%d|%.6f" name st_size st_mtime
                 |> Agent_core_sha256.digest_string
                 |> Agent_core_sha256.to_hex
               in
               Some
                 { Store.entry_id = "artifact:" ^ name
                 ; kind = Artifact
                 ; title = name
                 ; uri = "masc://artifacts/" ^ name
                 ; summary = Printf.sprintf "Published workspace artifact (%d bytes)" st_size
                 ; facets = [ "artifact"; "published" ]
                 ; sha256 = Some fingerprint
                 }
             | { Unix.st_kind =
                   (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK)
               ; _
               } -> None)
          names
      else []
    in
    wiki_inputs @ artifact_inputs @ builtin_mcp_resource_inputs)
;;

let sync_wiki_and_artifacts_sync_detailed ~base_path ~now () =
  let inputs = collect_index_inputs_off_domain ~base_path in
  let* upserted, pruned, digest, digest_changed =
    Store.sync_index_batch ~base_path ~now ~actor:"world_curator" inputs
  in
  let _ = pruned in
  Ok (upserted, digest, digest_changed)
;;

let sync_wiki_and_artifacts_sync ~base_path ~now () =
  let* upserted, digest, (_ : bool) =
    sync_wiki_and_artifacts_sync_detailed ~base_path ~now ()
  in
  Ok (upserted, digest)
;;

type msg =
  | Promotions of
      { keeper_id : string
      ; promotions : Librarian_lifecycle.world_promotion list
      }
  | Sync_index
  | Flush of unit Eio.Promise.u

type t = { mailbox : msg Eio.Stream.t }

let start ~sw ~base_path ~now ~on_updated =
  let mailbox = Eio.Stream.create 256 in
  let notify () =
    try on_updated () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Server.warn "world_memory curator on_updated callback failed: %s"
        (Printexc.to_string exn)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      let handle_message = function
        | Promotions { keeper_id; promotions } ->
          (match process_promotions_sync ~base_path ~now:(now ()) ~keeper_id promotions with
           | Ok report when report.digest_changed -> notify ()
           | Ok _ -> ()
           | Error err ->
             Log.Server.warn "world_memory curator promotion batch failed (%s): %s"
               keeper_id (Store.error_to_string err))
        | Sync_index ->
          (match sync_wiki_and_artifacts_sync_detailed ~base_path ~now:(now ()) () with
           | Ok (_, _, true) -> notify ()
           | Ok (_, _, false) -> ()
           | Error err ->
             Log.Server.warn "world_memory curator index sync failed: %s"
               (Store.error_to_string err))
        | Flush reply -> Eio.Promise.resolve reply ()
      in
      let msg = Eio.Stream.take mailbox in
      (try handle_message msg with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Log.Server.warn "world_memory curator fiber recovered from exception: %s"
           (Printexc.to_string exn);
         (match msg with
          | Flush reply -> ignore (Eio.Promise.try_resolve reply () : bool)
          | Promotions _ | Sync_index -> ()));
      loop ()
    in
    loop ());
  { mailbox }
;;

let enqueue_promotions t ~keeper_id promotions =
  match promotions with
  | [] -> ()
  | _ :: _ -> Eio.Stream.add t.mailbox (Promotions { keeper_id; promotions })
;;

let enqueue_index_sync t = Eio.Stream.add t.mailbox Sync_index

let flush t =
  let done_, resolve = Eio.Promise.create () in
  Eio.Stream.add t.mailbox (Flush resolve);
  Eio.Promise.await done_
;;
