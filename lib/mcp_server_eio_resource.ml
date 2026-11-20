(** Mcp_server_eio_resource — Resource reading handler

    Extracted from mcp_server_eio.ml.
    Handles resources/read JSON-RPC method for MASC resources.
*)

(* The wiki resource ids. The topic form carries the separator so a name
   like [wikifoo] is not read as the topic [foo]. *)
let wiki_index_id = "wiki"
let wiki_index_json_id = "wiki.json"
let wiki_topic_prefix = "wiki/"

(* The wiki's append-only log is one of its two own files, so it is not in
   [Tool_wiki.list_pages]. It is read as [masc://wiki/log]. [log] is a
   reserved page name, so no page can take that URI. *)
let wiki_log_topic = Filename.chop_suffix Wiki_journal.log_file ".md"

let make_response = Mcp_transport_protocol.make_response
let make_error = Mcp_transport_protocol.make_error

(* Typed wrapper.  The bare [-32602] literal at three call sites was a
   "Magic Number repetition" anti-pattern (sw-dev §"Magic Number 금지")
   that bypassed the existing [Mcp_error_code.t] typed sum.  Mirrors
   the [make_error_typed] helper already used in
   [mcp_server_eio_protocol.ml]; routes the typed variant through
   [to_wire_code] so the JSON-RPC envelope stays unchanged. *)
let make_error_typed ?data ~id (code : Mcp_error_code.t) message =
  make_error ?data ~id (Mcp_error_code.to_wire_code code) message

let public_tool_help_schemas () =
  Config.visible_tool_schemas ()

(* Resource projections use the synchronous Workspace/Fs_compat APIs.  Keep
   those reads off the cooperative Eio domain; Session actor access remains on
   the calling fiber because it may yield through the registry mailbox. *)
let run_blocking_resource_io f = Eio_unix.run_in_systhread ~label:"mcp-resource-io" f

let run_blocking_resource_result f =
  run_blocking_resource_io (fun () ->
    try f () with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Sys_error detail -> Error (Mcp_error_code.Internal_error, detail)
    | Unix.Unix_error (err, fn, arg) ->
      Error (Mcp_error_code.Internal_error, Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err)))
;;

type resource_caller =
  | Operator_admin
  | Authenticated_reader of
      { agent_name : string
      ; board_reader : Masc_board_handlers.Board_access.reader
      }
  | Anonymous_reader

type resource_target =
  | Tool_help_index
  | Tool_help of string
  | Status_markdown
  | Status_json
  | Tasks_markdown
  | Tasks_json
  | Who_markdown
  | Who_json
  | Messages_markdown
  | Messages_json
  | Events_markdown
  | Events_json
  | Wiki_index_markdown
  | Wiki_index_json
  | Wiki_page_markdown of string
  | Wiki_page_json of string
  | World_memory_claims
  | World_memory_log
  | Keeper_memory of string
  | Keeper_memory_health of string
  | Unknown of string

let world_memory_claims_uri = "masc://world-memory/claims"
let world_memory_log_uri = "masc://world-memory/log"

let parse_resource_target resource_id =
  match resource_id with
  | "tool-help-index" -> Tool_help_index
  | s when String.starts_with ~prefix:"tool-help/" s ->
    let prefix_len = String.length "tool-help/" in
    Tool_help (String.sub s prefix_len (String.length s - prefix_len))
  | "status" -> Status_markdown
  | "status.json" -> Status_json
  | "tasks" -> Tasks_markdown
  | "tasks.json" -> Tasks_json
  | "who" -> Who_markdown
  | "who.json" -> Who_json
  | "messages" -> Messages_markdown
  | "messages.json" -> Messages_json
  | "events" -> Events_markdown
  | "events.json" -> Events_json
  | s when String.equal s wiki_index_id -> Wiki_index_markdown
  | s when String.equal s wiki_index_json_id -> Wiki_index_json
  | s when String.starts_with ~prefix:wiki_topic_prefix s ->
    let prefix_len = String.length wiki_topic_prefix in
    let rest = String.sub s prefix_len (String.length s - prefix_len) in
    if String.equal rest "" then Wiki_index_markdown
    else if Filename.check_suffix rest ".json" then
      let topic = Filename.chop_suffix rest ".json" in
      if String.equal topic "" then Wiki_index_json else Wiki_page_json topic
    else
      Wiki_page_markdown rest
  | "world-memory/claims" -> World_memory_claims
  | "world-memory/log" -> World_memory_log
  | s ->
    (match String.split_on_char '/' s with
     | [ "keepers"; raw_keeper; "memory" ] when raw_keeper <> "" ->
       Keeper_memory (Uri.pct_decode raw_keeper)
     | [ "keepers"; raw_keeper; "memory"; "health" ] when raw_keeper <> "" ->
       Keeper_memory_health (Uri.pct_decode raw_keeper)
     | _ -> Unknown resource_id)
;;

let session_resource_notifier : (uri:string -> unit) option Atomic.t = Atomic.make None

let register_session_resource_notifier fn =
  Atomic.set session_resource_notifier (Some fn)
;;

let notify_resource_updated uris =
  List.iter
    (fun uri ->
       let notification =
         Mcp_transport_protocol.jsonrpc_notification
           "notifications/resources/updated"
           ~params:(`Assoc [ "uri", `String uri ])
       in
       Mcp_subscriptions.notify_resource_updated ~uri notification;
       match Atomic.get session_resource_notifier with
       | Some notify -> notify ~uri
       | None -> ())
    uris
;;

let notify_world_memory_updated () =
  notify_resource_updated [ world_memory_claims_uri; world_memory_log_uri ]
;;

let validate_keeper_name keeper =
  if String.equal (String.trim keeper) ""
     || String.contains keeper '/'
     || String.contains keeper '\\'
     || String.contains keeper '\000'
     || String.equal keeper "."
     || String.equal keeper ".."
  then Error (Mcp_error_code.Invalid_params, Printf.sprintf "Invalid keeper name: %S" keeper)
  else Ok ()
;;

let briefing_to_json = function
  | Error detail -> `Assoc [ "status", `String "unavailable"; "detail", `String detail ]
  | Ok Workspace_memory_briefing.Missing -> `Assoc [ "status", `String "pending" ]
  | Ok (Workspace_memory_briefing.Current summary) ->
    `Assoc
      [ "status", `String "current"
      ; "text", `String summary.text
      ; "source_ids", `List (List.map (fun id -> `String id) summary.source_ids)
      ]
  | Ok (Workspace_memory_briefing.Stale summary) ->
    `Assoc
      [ "status", `String "stale"
      ; "text", `String summary.text
      ; "source_ids", `List (List.map (fun id -> `String id) summary.source_ids)
      ]
;;

(* Storage read/decode errors have no narrower variant in [Mcp_error_code.t]
   than [Internal_error] (unlike malformed URIs or unknown keepers, which use
   [Invalid_params]). *)
let rec read_world_memory_claims_json ?(attempt = 1) ~briefing_template ~base_path () =
  match Workspace_memory_ledger.observe_with_briefing_template ~briefing_template ~base_path with
  | Workspace_memory_ledger.Missing ->
    Ok
      (`Assoc
        [ "status", `String "missing"
        ; "claims", `List []
        ; "conflicts", `List []
        ; "briefing", `Assoc [ "status", `String "missing" ]
        ])
  | Workspace_memory_ledger.Unavailable detail ->
    Error (Mcp_error_code.Internal_error, detail)
  | Workspace_memory_ledger.Available descriptor ->
    (match Workspace_memory_ledger.load ~base_path with
     | Error detail -> Error (Mcp_error_code.Internal_error, detail)
     | Ok ledger ->
       if not (String.equal (Workspace_memory_ledger.sha256 ledger) descriptor.ledger_sha256)
       then
         if attempt < 2 then
           read_world_memory_claims_json ~attempt:(attempt + 1) ~briefing_template ~base_path ()
         else
           Error (Mcp_error_code.Internal_error, "workspace ledger changed during the read")
       else
         let module String_map = Map.Make (String) in
         let add_member map id fact_ref =
           let prev = Option.value ~default:[] (String_map.find_opt id map) in
           String_map.add id (Workspace_memory_ledger.fact_ref_to_json fact_ref :: prev) map
         in
         let claim_members, conflict_members =
           List.fold_left
             (fun (cm, xm) (fact_ref, disp) ->
                match disp with
                | Workspace_memory_ledger.Claim_member id -> add_member cm id fact_ref, xm
                | Workspace_memory_ledger.Conflict_member id -> cm, add_member xm id fact_ref
                | Workspace_memory_ledger.Excluded _ -> cm, xm)
             (String_map.empty, String_map.empty)
             (Workspace_memory_ledger.dispositions ledger)
         in
         let claims_json =
           Workspace_memory_ledger.all_claim_provenance ledger
           |> List.map (fun (prov : Workspace_memory_ledger.claim_provenance) ->
                let members =
                  Option.value ~default:[] (String_map.find_opt prov.claim_id claim_members)
                  |> List.rev
                in
                `Assoc
                  [ "id", `String prov.claim_id
                  ; "text", `String prov.claim
                  ; "stage",
                    `String (Workspace_memory_ledger.corroboration_stage_to_string prov.stage)
                  ; "support_count", `Int prov.support_count
                  ; "supporting_keepers",
                    `List (List.map (fun k -> `String k) prov.supporting_keepers)
                  ; "has_source_bound", `Bool prov.has_source_bound
                  ; "members", `List members
                  ])
         in
         let conflicts_json =
           Workspace_memory_ledger.conflicts ledger
           |> List.map (fun (id, text) ->
                let members =
                  Option.value ~default:[] (String_map.find_opt id conflict_members)
                  |> List.rev
                in
                `Assoc [ "id", `String id; "text", `String text; "members", `List members ])
         in
         Ok
           (`Assoc
             [ "status", `String "available"
             ; "ledger_sha256", `String descriptor.ledger_sha256
             ; "classified_count", `Int descriptor.classified_count
             ; "excluded_count", `Int descriptor.excluded_count
             ; "claims", `List claims_json
             ; "conflicts", `List conflicts_json
             ; "briefing", briefing_to_json descriptor.briefing
             ]))
;;

let default_world_memory_log_limit = 100
let max_world_memory_log_limit = 500

let take_prefix_rev_rem n items =
  let rec loop acc left = function
    | [] -> List.rev acc, []
    | rest when left <= 0 -> List.rev acc, rest
    | item :: rest -> loop (item :: acc) (left - 1) rest
  in
  loop [] n items
;;

let read_world_memory_log_json ~since_seq ~limit ~base_path =
  let log_path = Workspace_memory_log.log_path ~base_path in
  match Workspace_memory_log.recover_file ~path:log_path with
  | Error err -> Error (Mcp_error_code.Internal_error, Workspace_memory_log.error_to_string err)
  | Ok report ->
    let total_committed_changes = List.length report.committed_changes in
    let filtered =
      List.filter
        (fun (entry : Workspace_memory_log.change_entry) -> entry.seq > since_seq)
        report.committed_changes
    in
    let page_entries, remaining = take_prefix_rev_rem limit filtered in
    let has_more = remaining <> [] in
    let next_since_seq =
      match List.rev page_entries with
      | last :: _ -> last.seq
      | [] -> since_seq
    in
    let committed_changes =
      List.map
        (fun entry -> Workspace_memory_log.record_to_yojson (Workspace_memory_log.Change entry))
        page_entries
    in
    let incomplete_batches =
      List.map
        (fun (h : Workspace_memory_log.batch_header) ->
           `Assoc
             [ "batch_id", `String h.batch_id
             ; "author", `String h.author
             ; "started_at", `String h.started_at
             ; "expected_changes", `Int h.expected_changes
             ])
        report.incomplete_batches
    in
    Ok
      (`Assoc
        [ "schema", `String "workspace.memory.log.v1"
        ; "last_committed_seq", `Int report.last_committed_seq
        ; "since_seq", `Int since_seq
        ; "limit", `Int limit
        ; "total_committed_changes", `Int total_committed_changes
        ; "has_more", `Bool has_more
        ; "next_since_seq", `Int next_since_seq
        ; "committed_changes", `List committed_changes
        ; "incomplete_batches", `List incomplete_batches
        ; "aborted_batches", `List (List.map (fun id -> `String id) report.aborted_batches)
        ])
;;

let keeper_exists_hint ~base_path ~keepers_dir ~keeper ~ordinary ~source_bound =
  Option.is_some (Config_dir_resolver.keeper_toml_path_opt_for_base_path ~base_path keeper)
  || (match ordinary with
      | Keeper_memory_os_current.No_snapshot -> false
      | Readable _ | Undecodable _ | Io_unreadable _ -> true)
  || (match source_bound with
      | Ok None -> false
      | Ok (Some _) | Error _ -> true)
  || Sys.file_exists (Keeper_memory_os_current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:keeper)
  || Sys.file_exists (Keeper_memory_os_events.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper)
;;

(* Must run on an Eio fiber (not in [run_blocking_resource_io]), because
   [Board_dispatch.read_post_for_evidence] acquires an [Eio.Mutex]. *)
let filter_ordinary_snapshot_for_reader
      ?base_path
      ~(reader : Masc_board_handlers.Board_access.reader)
      (snap : Keeper_memory_os_current.t)
  : Keeper_memory_os_current.t * int
  =
  if Masc_board_handlers.Board_access.is_operator reader
  then snap, 0
  else (
    let store_ready =
      String.equal (Board_dispatch.backend_name ()) "jsonl"
      &&
      match base_path with
      | None -> true
      | Some bp ->
        Result.is_ok (Board_dispatch.check_store_workspace ~base_path:bp (Board_dispatch.backend ()))
    in
    let board_cache : (string, bool) Hashtbl.t = Hashtbl.create 16 in
    let can_read_post_id (pid : Board_types.Post_id.t) =
      let key = Board_types.Post_id.to_string pid in
      match Hashtbl.find_opt board_cache key with
      | Some ok -> ok
      | None ->
        let ok =
          store_ready
          &&
          match Board_dispatch.read_post_for_evidence ~reader ~post_id:key with
          | Ok _ -> true
          | Error _ -> false
        in
        Hashtbl.add board_cache key ok;
        ok
    in
    let open Keeper_memory_os_types in
    let fact_basis_directly_readable (fact : fact) =
      match fact.basis with
      | Observed Transcript -> true
      | Observed (Board { post_id; comment_id = (_ : Board_types.Comment_id.t option) }) ->
        can_read_post_id post_id
      | Derived (_ : derivation list) -> true
    in
    let pass1_facts = List.filter fact_basis_directly_readable snap.facts in
    let surviving_facts, _dropped_derived =
      Keeper_memory_os_support_core.maintain_supported_facts pass1_facts
    in
    let surviving_ids =
      List.fold_left
        (fun acc fact -> Set_util.StringSet.add (memory_id fact) acc)
        Set_util.StringSet.empty
        surviving_facts
    in
    let added =
      List.filter
        (fun fact -> Set_util.StringSet.mem (memory_id fact) surviving_ids)
        snap.change.added
    in
    let fact_history_readable (fact : fact) =
      match fact.basis with
      | Observed Transcript -> true
      | Observed (Board { post_id; comment_id = (_ : Board_types.Comment_id.t option) }) ->
        can_read_post_id post_id
      | Derived derivations ->
        Keeper_memory_os_support_core.derivations_supported surviving_ids derivations
    in
    let removed = List.filter fact_history_readable snap.change.removed in
    let invalidated =
      List.filter
        (fun (inv : Keeper_memory_os_current.support_invalidation) ->
           match inv.fact.basis with
           | Observed Transcript -> true
           | Observed (Board { post_id; comment_id = (_ : Board_types.Comment_id.t option) }) ->
             can_read_post_id post_id
           | Derived (_ : derivation list) -> false)
        snap.change.invalidated
    in
    let retained = max 0 (List.length surviving_facts - List.length added) in
    let change : Keeper_memory_os_current.change =
      { added; removed; retained; invalidated }
    in
    let withheld_count = List.length snap.facts - List.length surviving_facts in
    { snap with facts = surviving_facts; change }, withheld_count)
;;

let read_keeper_memory_inputs_blocking ~config ~caller ~keeper =
  let base_path = config.Workspace.base_path in
  let reader_res =
    match caller with
    | Operator_admin -> Ok Masc_board_handlers.Board_access.Operator
    | Anonymous_reader ->
      Error (Mcp_error_code.Auth_error, "Keeper memory resource requires authentication")
    | Authenticated_reader { agent_name; board_reader } ->
      if not (String.equal agent_name keeper)
      then
        Error
          ( Mcp_error_code.Insufficient_scope
          , "Keeper memory resource requires admin permission or matching keeper identity" )
      else (
        match Keeper_meta_store.read_effective_meta_presence config keeper with
        | Ok (Keeper_meta_store.Meta_present meta) ->
          (match board_reader with
           | Masc_board_handlers.Board_access.Anonymous ->
             Ok Masc_board_handlers.Board_access.Anonymous
           | Masc_board_handlers.Board_access.Named _
           | Masc_board_handlers.Board_access.Operator ->
             Ok (Keeper_board_audience.reader_for_keeper meta))
        | Ok (Keeper_meta_store.Meta_absent | Keeper_meta_store.Meta_not_current _) | Error _ ->
          Error (Mcp_error_code.Insufficient_scope, "Keeper readership metadata unavailable"))
  in
  match reader_res with
  | Error _ as err -> err
  | Ok reader ->
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    let ordinary = Keeper_memory_os_current.read_classified ~keepers_dir ~keeper_id:keeper in
    let source_bound =
      Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper
    in
    if not (keeper_exists_hint ~base_path ~keepers_dir ~keeper ~ordinary ~source_bound)
    then Ok None
    else (
      match ordinary with
      | Keeper_memory_os_current.Undecodable { rejection } ->
        Error (Mcp_error_code.Internal_error, "keeper ordinary memory undecodable: " ^ rejection)
      | Keeper_memory_os_current.Io_unreadable { detail } ->
        Error (Mcp_error_code.Internal_error, "keeper ordinary memory unreadable: " ^ detail)
      | (No_snapshot | Readable _) as ordinary_ok ->
        (match source_bound with
         | Error detail ->
           Error (Mcp_error_code.Internal_error, "keeper source memory unreadable: " ^ detail)
         | Ok source_opt -> Ok (Some (reader, ordinary_ok, source_opt))))
;;

let read_keeper_memory_json ~config ~caller ~keeper =
  match validate_keeper_name keeper with
  | Error err -> Error err
  | Ok () ->
    (match caller with
     | Anonymous_reader ->
       Error (Mcp_error_code.Auth_error, "Keeper memory resource requires authentication")
     | Authenticated_reader { agent_name; board_reader = _ }
       when not (String.equal agent_name keeper) ->
       Error
         ( Mcp_error_code.Insufficient_scope
         , "Keeper memory resource requires admin permission or matching keeper identity" )
     | Operator_admin | Authenticated_reader _ ->
       (match
          run_blocking_resource_result (fun () ->
            read_keeper_memory_inputs_blocking ~config ~caller ~keeper)
        with
        | Error err -> Error err
        | Ok None -> Ok None
        | Ok (Some (reader, ordinary_ok, source_opt)) ->
          let ordinary_json, withheld_fact_count =
            match ordinary_ok with
            | Keeper_memory_os_current.Readable snap ->
              let filtered, withheld =
                filter_ordinary_snapshot_for_reader ~base_path:config.base_path ~reader snap
              in
              Keeper_memory_os_current.to_json filtered, withheld
            | Keeper_memory_os_current.No_snapshot
            | Keeper_memory_os_current.Undecodable _
            | Keeper_memory_os_current.Io_unreadable _ -> `Null, 0
          in
          let source_json =
            match source_opt with
            | None -> `Null
            | Some snap -> Keeper_memory_source_current.to_json snap
          in
          Ok
            (Some
               (`Assoc
                  [ "keeper", `String keeper
                  ; "ordinary", ordinary_json
                  ; "source_bound", source_json
                  ; "withheld_fact_count", `Int withheld_fact_count
                  ]))))
;;

(* RFC §12.1 G16: health surface carries only closed status/outcome/kind tokens,
   counts, revisions, timestamps, and hashes — no free-text claims, details,
   rejections, or file paths. *)
let journal_entry_summary = function
  | Keeper_memory_os_current.Journal_committed { recorded_at; revision; source; change; _ } ->
    `Assoc
      [ "outcome", `String "committed"
      ; "recorded_at", `Float recorded_at
      ; "revision", `Int revision
      ; "source_kind", `String (Keeper_memory_os_current.source_kind_to_string source.kind)
      ; "added_count", `Int (List.length change.added)
      ; "removed_count", `Int (List.length change.removed)
      ; "retained_count", `Int change.retained
      ; "invalidated_count", `Int (List.length change.invalidated)
      ]
  | Keeper_memory_os_current.Journal_failed { recorded_at; kind; snapshot_present; _ } ->
    `Assoc
      [ "outcome", `String "failed"
      ; "recorded_at", `Float recorded_at
      ; "kind", `String (Keeper_memory_os_current.librarian_failure_kind_to_string kind)
      ; "snapshot_present", `Bool snapshot_present
      ]
  | Keeper_memory_os_current.Journal_quarantined { recorded_at; _ } ->
    `Assoc
      [ "outcome", `String "quarantined"
      ; "recorded_at", `Float recorded_at
      ]
;;

let read_keeper_memory_health_json ~base_path ~caller ~keeper =
  match validate_keeper_name keeper with
  | Error err -> Error err
  | Ok () ->
    (match caller with
     | Anonymous_reader ->
       Error (Mcp_error_code.Auth_error, "Keeper memory health resource requires authentication")
     | Operator_admin | Authenticated_reader _ ->
       run_blocking_resource_result (fun () ->
         let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
         let ordinary = Keeper_memory_os_current.read_classified ~keepers_dir ~keeper_id:keeper in
         let source_bound =
           Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper
         in
         if not (keeper_exists_hint ~base_path ~keepers_dir ~keeper ~ordinary ~source_bound)
         then Ok None
         else
           let ordinary_json =
             match ordinary with
             | Keeper_memory_os_current.No_snapshot ->
               `Assoc [ "status", `String "missing" ]
             | Keeper_memory_os_current.Readable snap ->
               let path =
                 Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper
               in
               let bytes_opt = Fs_compat.file_size path in
               `Assoc
                 ([ "status", `String "readable"
                  ; "revision", `Int snap.revision
                  ; "updated_at", `Float snap.updated_at
                  ; "fact_count", `Int (List.length snap.facts)
                  ; "invalidated_count", `Int (List.length snap.change.invalidated)
                  ; "snapshot_sha256", `String (Keeper_memory_os_current.snapshot_sha256 snap)
                  ]
                  @
                  match bytes_opt with
                  | Some n -> [ "snapshot_bytes", `Int n ]
                  | None -> [])
             | Keeper_memory_os_current.Undecodable _ ->
               `Assoc [ "status", `String "undecodable" ]
             | Keeper_memory_os_current.Io_unreadable _ ->
               `Assoc [ "status", `String "io_unreadable" ]
           in
           let source_bound_json =
             match source_bound with
             | Ok None -> `Assoc [ "status", `String "missing" ]
             | Ok (Some snap) ->
               `Assoc
                 [ "status", `String "readable"
                 ; "revision", `Int snap.revision
                 ; "updated_at", `Float snap.updated_at
                 ; "fact_count", `Int (List.length snap.facts)
                 ; "invalidation_count", `Int (List.length snap.invalidations)
                 ]
             | Error _ -> `Assoc [ "status", `String "unreadable" ]
           in
           let events_json =
             match Keeper_memory_os_events.read ~keepers_dir ~keeper_id:keeper with
             | Error _ -> `Assoc [ "status", `String "unreadable" ]
             | Ok rows ->
               let valid_count, error_count =
                 List.fold_left
                   (fun (ok_n, err_n) (_, item) ->
                      match item with
                      | Ok _ -> ok_n + 1, err_n
                      | Error _ -> ok_n, err_n + 1)
                   (0, 0)
                   rows
               in
               `Assoc
                 [ "status", `String "readable"
                 ; "event_count", `Int valid_count
                 ; "undecodable_count", `Int error_count
                 ]
           in
           let journal_json =
             match
               Keeper_memory_os_current.read_journal_tail ~keepers_dir ~keeper_id:keeper ~limit:20
             with
             | Error _ -> `Assoc [ "status", `String "unreadable" ]
             | Ok rows ->
               let entries, undecodable_count =
                 List.fold_left
                   (fun (acc, bad) item ->
                      match item with
                      | Ok entry -> journal_entry_summary entry :: acc, bad
                      | Error _ -> acc, bad + 1)
                   ([], 0)
                   rows
               in
               `Assoc
                 [ "status", `String "readable"
                 ; "undecodable_count", `Int undecodable_count
                 ; "recent_entries", `List (List.rev entries)
                 ]
           in
           Ok
             (Some
                (`Assoc
                   [ "schema", `String "keeper.memory.health.v1"
                   ; "keeper", `String keeper
                   ; "ordinary", ordinary_json
                   ; "source_bound", source_bound_json
                   ; "events", events_json
                   ; "journal", journal_json
                   ]))))
;;

module For_testing = struct
  let blocking_io_execution_context () =
    run_blocking_resource_io Eio_guard.execution_context

  let filter_ordinary_snapshot_for_reader ?base_path ~reader snap =
    filter_ordinary_snapshot_for_reader ?base_path ~reader snap
end

(* A page's header sits at the top, so the listing reads only this many bytes
   of a page to find it, not the whole file (task-2309). A page larger than
   this whose header still does not read from the prefix falls back to the
   whole file, so a header longer than the bound is listed exactly as before. *)
let frontmatter_read_limit = 8192

let read_listing_header ~path ~size =
  if size <= frontmatter_read_limit
  then Fs_compat.load_file path
  else begin
    let prefix = Fs_compat.read_slice ~path ~from:0 ~len:frontmatter_read_limit in
    match Tool_wiki.parse_frontmatter prefix with
    | Ok _ -> prefix
    | Error _ -> Fs_compat.load_file path
  end
;;

(* The log is append-only and grows without bound, so an explicit read returns
   its tail rather than the whole file (task-2309). The read is the last
   [log_read_limit] bytes, starting at a line boundary so the first line is
   whole; a log at or below the bound is returned as written. The listing's
   size is the whole file, so a client can tell a tail from the whole.

   When the last [log_read_limit] bytes hold no newline the file is a single
   line longer than the bound; the slice is then returned as read, and its
   first byte may sit inside a UTF-8 code point. Real logs add one short line
   per event, so this is a guard, not a path taken. *)
let log_read_limit = 65536

let read_log_tail ~path ~size =
  if size <= log_read_limit
  then Fs_compat.load_file path
  else begin
    let from = size - log_read_limit in
    let text = Fs_compat.read_slice ~path ~from ~len:log_read_limit in
    match String.index_opt text '\n' with
    | Some i -> String.sub text (i + 1) (String.length text - i - 1)
    | None -> text
  end
;;

(* One listed resource per page, or [None] when the name is not a valid page
   topic or the file vanished. The URI comes from the validated topic, never
   from concatenating the file name. The size is a stat, so a page's body is
   not read to list it. *)
let page_resource path : Mcp_server.mcp_resource option =
  let file = Filename.basename path in
  let topic = Filename.chop_suffix file ".md" in
  match Tool_wiki.validate_page_name topic with
  | Error _ -> None
  | Ok _ ->
    (match Fs_compat.file_size path with
     | None -> None
     | Some size ->
       (match read_listing_header ~path ~size with
        | exception Sys_error _ -> None
        | content ->
          let uri = "masc://" ^ wiki_topic_prefix ^ topic in
          (match Tool_wiki.parse_frontmatter content with
           | Ok (fm : Tool_wiki.frontmatter) ->
             Some
               (Mcp_server.make_resource
                  ~title:(fm.title :> string)
                  ~size
                  ~uri
                  ~name:topic
                  ~description:(fm.summary :> string)
                  ~mime_type:"text/markdown"
                  ())
           | Error error ->
             Some
               (Mcp_server.make_resource
                  ~size
                  ~uri
                  ~name:file
                  ~description:(Tool_wiki.frontmatter_error_to_string error)
                  ~mime_type:"text/markdown"
                  ()))))
;;

(* One listed resource per wiki page. The pages are otherwise reachable only
   through the [masc://wiki/{topic}] template, which a client that lists
   resources cannot expand, so it could not open a page. A page whose header
   does not read is listed by file name with the reason, as the index resource
   does. A file whose name is not a valid page topic is not listed: its URI
   would not read back as the same file ([notes.json.md] reads as a JSON
   request for [notes]; [?] and [#] fall to URI parsing), and the index
   resource still shows it with its reason. The log is listed once it exists.

   Read cost (task-2309): the listing no longer reads page bodies. Each page
   contributes a stat and, at most, a bounded header prefix, and the log is
   sized by stat. The TUI Resources screen follows [nextCursor], so a listing
   longer than one page is no longer cut off at its end, where the wiki entries
   sort. An explicit [masc://wiki/log] read now returns the log's tail
   ([log_read_limit]) instead of the whole file. *)
let wiki_resources ~base_path : Mcp_server.mcp_resource list =
  run_blocking_resource_io (fun () ->
    let uri_of_topic topic = "masc://" ^ wiki_topic_prefix ^ topic in
    (* [list_pages] raises [Sys_error] when the wiki root cannot be listed
       (a regular file in its place, or a stat failure other than ENOENT).
       The listing keeps every other resource and lists no wiki pages; the
       wiki tools report the failure itself. *)
    let pages =
      match Tool_wiki.list_pages ~base_path with
      | paths -> List.filter_map page_resource paths
      | exception Sys_error _ -> []
    in
    let log_path =
      Filename.concat (Tool_wiki.wiki_root ~base_path) Wiki_journal.log_file
    in
    let log =
      match Fs_compat.file_size log_path with
      | None -> []
      | Some size ->
        [ Mcp_server.make_resource
            ~title:"Wiki log"
            ~size
            ~uri:(uri_of_topic wiki_log_topic)
            ~name:wiki_log_topic
            ~description:
              "One line per wiki page creation or update, oldest first. Lines \
               are only appended. A read returns the tail: the last 65536 bytes, \
               starting at a line boundary; the size below is the whole file."
            ~mime_type:"text/markdown"
            ()
        ]
    in
    log @ pages)
;;

let handle_read_resource_eio ?(caller = Anonymous_reader) state id params =
  match params with
  | None -> make_error_typed ~id Mcp_error_code.Invalid_params "Missing params"
  | Some (`Assoc _ as p) ->
      let uri_str = Safe_ops.json_string "uri" p in
      if uri_str = "" then
        make_error_typed ~id Mcp_error_code.Invalid_params "Missing uri"
      else begin
        let resource_id, uri = Mcp_server.parse_masc_resource_uri uri_str in
        let config = (Mcp_server.workspace_config state) in
        let registry = state.Mcp_server.session_registry in

        let read_messages_json ~since_seq ~limit =
          run_blocking_resource_io (fun () ->
            let msgs_path = Workspace.messages_dir config in
            if Sys.file_exists msgs_path then
              let extract_seq name =
                match String.index_opt name '_' with
                | None -> 0
                | Some idx ->
                  Safe_ops.int_of_string_with_default
                    ~default:0
                    (String.sub name 0 idx)
              in
              let files =
                Sys.readdir msgs_path
                |> Array.to_list
                |> List.sort (fun a b -> compare (extract_seq b) (extract_seq a))
              in
              let count = ref 0 in
              let msgs = ref [] in
              List.iter
                (fun name ->
                   if !count < limit
                   then (
                     let path = Filename.concat msgs_path name in
                     let json = Workspace.read_json config path in
                     match Masc_domain.message_of_yojson json with
                     | Ok msg when msg.Masc_domain.seq > since_seq ->
                       msgs := Masc_domain.message_to_yojson msg :: !msgs;
                       incr count
                     | Ok _ -> ()
                     | Error detail ->
                       Log.legacy_traceln
                         ~level:Log.Warn
                         ~module_name:"MCP"
                         (Printf.sprintf
                            "[WARN] Failed to decode message resource %s: %s"
                            path
                            detail)))
                files;
              `List (List.rev !msgs)
            else `List [])
        in

        let read_events_json ~limit =
          run_blocking_resource_io (fun () ->
            let lines = Mcp_server.read_event_lines config ~limit in
            let events =
              List.filter_map
                (fun line ->
                   match Yojson.Safe.from_string line with
                   | json -> Some json
                   | exception Yojson.Json_error msg ->
                     let preview =
                       String_util.utf8_safe ~max_bytes:53 ~suffix:"..." line
                       |> String_util.to_string
                     in
                     Log.legacy_traceln
                       ~level:Log.Warn
                       ~module_name:"MCP"
                       (Printf.sprintf
                          "[WARN] Failed to parse event JSON: %s (line: %s)"
                          msg
                          preview);
                     None)
                lines
            in
            `List events)
        in

        let read_events_markdown ~limit =
          run_blocking_resource_io (fun () ->
            let lines = Mcp_server.read_event_lines config ~limit in
            if lines = []
            then "(no events)"
            else String.concat "\n" (List.map (fun line -> "- " ^ line) lines))
        in

        let read_wiki_resource ~is_json ~topic =
          match
            run_blocking_resource_io (fun () ->
              let base_path = config.base_path in
              let wiki_dir = Tool_wiki.wiki_root ~base_path in
              (* Trimmed here, not in the parser. The three readers this
                 replaced disagreed: prompt_registry kept the body verbatim
                 and this one trimmed it. Frontmatter.parse follows the
                 verbatim reading -- it returns what the file says -- so the
                 surface that wants a tidy body asks for it. Without the
                 trim, a file ending in a newline renders as "Alpha body\n"
                 in the JSON resource. *)
              let strip_frontmatter content =
                String.trim (Frontmatter.parse content).Frontmatter.body
              in
              if not (Sys.file_exists wiki_dir) then
                if topic <> "" then ("text/plain", None)
                else if is_json then
                  ("application/json", Some (Yojson.Safe.to_string
                    (`Assoc [ ("documents", `List []); ("count", `Int 0) ])))
                else ("text/markdown", Some "Wiki is empty.")
              else begin
              let topic_of path = Filename.chop_suffix (Filename.basename path) ".md" in
              let uri_of path = "masc://wiki/" ^ topic_of path in
              (* The same header rules as the wiki tools: a document that
                 does not read is named with its reason, never given a title
                 or a source it does not have. A file that vanishes between
                 the listing and the read is left out, as the tools do. *)
              let read_documents () =
                Tool_wiki.list_pages ~base_path
                |> List.filter_map (fun path ->
                  match Fs_compat.load_file path with
                  | content -> Some (path, Tool_wiki.parse_frontmatter content)
                  | exception Sys_error _ -> None)
              in
              let metadata_fields (fm : Tool_wiki.frontmatter) =
                [ ("title", `String (fm.title :> string))
                ; ("summary", `String (fm.summary :> string))
                ; ("source", `String (Tool_wiki.source_to_string fm.source))
                ; ("author", `String (fm.author :> string))
                ; ("created", `String (fm.created :> string))
                ; ("revision", `Int fm.revision)
                ; ("tags", `List (List.map (fun (t : Tool_wiki.Tag.t) -> `String (t :> string)) fm.tags))
                ]
              in
              let unreadable_fields error =
                [ ("unreadable", `String (Tool_wiki.frontmatter_error_to_string error)) ]
              in
              (* [topic] arrives from the client's URI. Resolving it against
                 the listing rather than concatenating it onto [wiki_dir]
                 means a topic like [../../secrets] has nothing to match:
                 readdir never returns a name with a separator in it. *)
              let wiki_page_path topic =
                let want = topic ^ ".md" in
                List.find_opt
                  (fun path -> String.equal (Filename.basename path) want)
                  (Tool_wiki.list_pages ~base_path)
              in
              if topic = "" && not is_json then begin
                let entries = List.map (fun (path, header) ->
                  match header with
                  | Ok (fm : Tool_wiki.frontmatter) ->
                    let tag_str = if fm.tags = [] then ""
                      else " -- " ^ String.concat ", " (List.map (fun (t : Tool_wiki.Tag.t) -> "`" ^ (t :> string) ^ "`") fm.tags) in
                    Printf.sprintf "- **%s** -- `%s` (%s)%s" (fm.title :> string) (uri_of path)
                      (Tool_wiki.source_to_string fm.source) tag_str
                  | Error error ->
                    Printf.sprintf "- %s -- `%s`"
                      (Tool_wiki.describe_unreadable path error) (uri_of path)
                ) (read_documents ()) in
                let body = if entries = [] then "Wiki is empty."
                  else "# Wiki index\n\n" ^ String.concat "\n" entries ^ "\n"
                in
                ("text/markdown", Some body)
              end else if topic = "" && is_json then begin
                let docs = List.map (fun (path, header) ->
                  let described =
                    match header with
                    | Ok fm -> metadata_fields fm
                    | Error error -> unreadable_fields error
                  in
                  `Assoc
                    ((("topic", `String (topic_of path)) :: described)
                     @ [ ("uri", `String (uri_of path)) ])
                ) (read_documents ()) in
                let json = `Assoc [
                  ("documents", `List docs);
                  ("count", `Int (List.length docs));
                ] in
                ("application/json", Some (Yojson.Safe.to_string json))
              end else if is_json then begin
                match wiki_page_path topic with
                | Some path ->
                  (* A page can be listed and then become unreadable before
                     this read: deleted, or its permissions changed. Answer
                     with an error envelope rather than letting [Sys_error]
                     escape the handler, as the index and log branches
                     already do (the [.mli] promises [Never raises]). *)
                  (match Fs_compat.load_file path with
                   | exception Sys_error _ -> ("application/json", None)
                   | raw ->
                     let described =
                       match Tool_wiki.parse_frontmatter raw with
                       | Ok fm -> metadata_fields fm
                       | Error error -> unreadable_fields error
                     in
                     let json =
                       `Assoc
                         ((("topic", `String topic) :: described)
                          @ [ ("content", `String (strip_frontmatter raw)) ])
                     in
                     ("application/json", Some (Yojson.Safe.to_string json)))
                | None -> ("application/json", None)
              end else begin
                match wiki_page_path topic with
                | Some path ->
                  (match Fs_compat.load_file path with
                   | content -> ("text/markdown", Some content)
                   | exception Sys_error _ -> ("text/markdown", None))
                | None when String.equal topic wiki_log_topic ->
                  (* The log is not a page, so the listing above has no
                     entry for it. The path is the constant file name, never
                     the client's topic. The log is append-only and grows
                     without bound, so the read returns its tail rather than
                     the whole file (task-2309). *)
                  let log_path = Filename.concat wiki_dir Wiki_journal.log_file in
                  (match Fs_compat.file_size log_path with
                   | None -> ("text/markdown", None)
                   | Some size ->
                     (match read_log_tail ~path:log_path ~size with
                      | text -> ("text/markdown", Some text)
                      | exception Sys_error _ -> ("text/markdown", None)))
                | None -> ("text/markdown", None)
              end
              end)
          with
          | read -> Ok (match read with _, None -> None | mime_type, Some text -> Some (mime_type, text))
          | exception Sys_error _ -> Ok None
        in

        let resource_outcome =
          match parse_resource_target resource_id with
          | Tool_help_index ->
              Ok
                (Some
                  ( "text/markdown"
                  , Tool_help_registry.index_markdown (public_tool_help_schemas ()) ))
          | Tool_help tool_name ->
              let text_opt =
                match
                  Tool_help_registry.find_entry (public_tool_help_schemas ()) tool_name
                with
                | Some entry -> Some (Tool_help_registry.entry_markdown entry)
                | None -> None
              in
              Ok (Option.map (fun text -> ("text/markdown", text)) text_opt)
          | Status_markdown ->
              Ok (Some ("text/markdown", run_blocking_resource_io (fun () -> Workspace.status config)))
          | Status_json ->
              let state_observation, backlog_json =
                run_blocking_resource_io (fun () ->
                  ( Workspace.observe_state config
                  , Masc_domain.backlog_to_yojson (Workspace.read_backlog config) ))
              in
              let state_json =
                Masc_domain.workspace_state_to_yojson
                  (Workspace.state_of_observation state_observation)
              in
              let connected_agents = Session.get_agent_statuses registry in
              let json = `Assoc [
                ("base_path", `String config.base_path);
                ("state", state_json);
                ("state_read", Workspace.state_observation_to_yojson state_observation);
                ("backlog", backlog_json);
                ("connected_agents", `List connected_agents);
              ] in
              Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
          | Tasks_markdown ->
              Ok (Some ("text/markdown", run_blocking_resource_io (fun () -> Workspace.list_tasks config)))
          | Tasks_json ->
              let backlog_json =
                run_blocking_resource_io (fun () ->
                  Masc_domain.backlog_to_yojson (Workspace.read_backlog config))
              in
              Ok (Some ("application/json", Yojson.Safe.pretty_to_string backlog_json))
          | Who_markdown ->
              Ok (Some ("text/markdown", Session.status_string registry))
          | Who_json ->
              let statuses = Session.get_agent_statuses registry in
              Ok (Some ("application/json", Yojson.Safe.pretty_to_string (`List statuses)))
          | Messages_markdown ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              Ok
                (Some
                  ( "text/markdown"
                  , run_blocking_resource_io (fun () ->
                      Workspace.get_messages config ~since_seq ~limit) ))
          | Messages_json ->
              let since_seq = Mcp_server.int_query_param uri "since_seq" ~default:0 in
              let limit = Mcp_server.int_query_param uri "limit" ~default:10 in
              let json = read_messages_json ~since_seq ~limit in
              Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
          | Events_markdown ->
              let limit = Mcp_server.int_query_param uri "limit" ~default:50 in
              Ok (Some ("text/markdown", read_events_markdown ~limit))
          | Events_json ->
              let limit = Mcp_server.int_query_param uri "limit" ~default:50 in
              let json = read_events_json ~limit in
              Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
          | Wiki_index_markdown -> read_wiki_resource ~is_json:false ~topic:""
          | Wiki_index_json -> read_wiki_resource ~is_json:true ~topic:""
          | Wiki_page_markdown topic -> read_wiki_resource ~is_json:false ~topic
          | Wiki_page_json topic -> read_wiki_resource ~is_json:true ~topic
          | World_memory_claims ->
              let briefing_template =
                (Prompt_registry.resolve_prompt Prompt_names.workspace_memory_briefing).effective
              in
              (match
                 run_blocking_resource_result (fun () ->
                   read_world_memory_claims_json ~briefing_template ~base_path:config.base_path ())
               with
               | Ok json -> Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
               | Error err -> Error err)
          | World_memory_log ->
              let since_seq = max 0 (Mcp_server.int_query_param uri "since_seq" ~default:0) in
              let limit =
                min max_world_memory_log_limit
                  (max 1 (Mcp_server.int_query_param uri "limit" ~default:default_world_memory_log_limit))
              in
              (match
                 run_blocking_resource_result (fun () ->
                   read_world_memory_log_json ~since_seq ~limit ~base_path:config.base_path)
               with
               | Ok json -> Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
               | Error err -> Error err)
          | Keeper_memory keeper ->
              (match read_keeper_memory_json ~config ~caller ~keeper with
               | Ok None -> Ok None
               | Ok (Some json) ->
                 Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
               | Error err -> Error err)
          | Keeper_memory_health keeper ->
              (match read_keeper_memory_health_json ~base_path:config.base_path ~caller ~keeper with
               | Ok None -> Ok None
               | Ok (Some json) ->
                 Ok (Some ("application/json", Yojson.Safe.pretty_to_string json))
               | Error err -> Error err)
          | Unknown _ -> Ok None
        in

        match resource_outcome with
        | Error (code, message) ->
            make_error_typed ~id
              ~data:(`Assoc [ ("uri", `String uri_str) ])
              code
              message
        | Ok None ->
            make_error_typed ~id
              ~data:(`Assoc [ ("uri", `String uri_str) ])
              Mcp_error_code.Invalid_params
              "Resource not found"
        | Ok (Some (mime_type, text)) ->
            let contents = `List [
              `Assoc [
                ("uri", `String uri_str);
                ("mimeType", `String mime_type);
                ("text", `String text);
              ]
            ] in
            make_response ~id
              (`Assoc
                ([ ("contents", contents) ]
                @ Mcp_server.(cache_hint_fields live_state_cache_hint)))
      end
  | Some _ ->
      make_error_typed ~id Mcp_error_code.Invalid_params "Invalid params"
