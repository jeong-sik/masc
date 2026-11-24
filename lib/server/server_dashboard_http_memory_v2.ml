module Http = Http_server_eio
module Env = Server_dashboard_http_v2_envelope
module Cur = Keeper_memory_os_current
module Types = Keeper_memory_os_types
module Events = Keeper_memory_os_events
module Ledger = Workspace_memory_ledger
module Briefing = Workspace_memory_briefing
module Wlog = Workspace_memory_log

type diff_scope =
  | Scope_world
  | Scope_keeper of string

type diff_window =
  | Window_24h
  | Window_7d
  | Window_30d

type diff_range =
  | Range_window of diff_window
  | Range_revs of
      { from_rev : int
      ; to_rev : int option
      }

type retrieval_heat =
  | Heat_hot
  | Heat_warm
  | Heat_cold
  | Heat_never

let retrieval_heat_to_string = function
  | Heat_hot -> "hot"
  | Heat_warm -> "warm"
  | Heat_cold -> "cold"
  | Heat_never -> "never_retrieved"
;;

let window_seconds = function
  | Window_24h -> 86400.0
  | Window_7d -> 7.0 *. 86400.0
  | Window_30d -> 30.0 *. 86400.0
;;

let window_to_string = function
  | Window_24h -> "24h"
  | Window_7d -> "7d"
  | Window_30d -> "30d"
;;

let window_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "24h" -> Some Window_24h
  | "7d" -> Some Window_7d
  | "30d" -> Some Window_30d
  | _ -> None
;;

let classify_retrieval_heat ~now ~retrieved_count ~last_retrieved_at =
  if retrieved_count <= 0
  then Heat_never
  else (
    let age_sec =
      match last_retrieved_at with
      | Some ts -> Float.max 0.0 (now -. ts)
      | None -> Float.infinity
    in
    if Float.compare age_sec 86400.0 <= 0 || retrieved_count >= 5
    then Heat_hot
    else if Float.compare age_sec (7.0 *. 86400.0) <= 0 || retrieved_count >= 2
    then Heat_warm
    else Heat_cold)
;;

let parse_diff_query ~scope ~keeper ~window ~from_rev ~to_rev =
  let open Result.Syntax in
  let trim_opt = function
    | None -> None
    | Some s ->
      let t = String.trim s in
      if String.equal t "" then None else Some t
  in
  let* parsed_scope =
    match trim_opt scope, trim_opt keeper with
    | None, None -> Error ("scope", "scope parameter is required (world or keeper name)")
    | Some "world", None -> Ok Scope_world
    | Some "world", Some _ -> Error ("keeper", "keeper parameter is not valid when scope=world")
    | Some "keeper", Some k ->
      if Keeper_config.validate_name k
      then Ok (Scope_keeper k)
      else Error ("keeper", Printf.sprintf "invalid keeper name %S" k)
    | Some "keeper", None ->
      Error ("keeper", "keeper parameter is required when scope=keeper")
    | Some raw, None ->
      if Keeper_config.validate_name raw
      then Ok (Scope_keeper raw)
      else Error ("scope", Printf.sprintf "invalid scope %S" raw)
    | Some _, Some _ ->
      Error ("scope", "use either scope=<keeper> or scope=keeper&keeper=<keeper>")
    | None, Some k ->
      if Keeper_config.validate_name k
      then Ok (Scope_keeper k)
      else Error ("keeper", Printf.sprintf "invalid keeper name %S" k)
  in
  let* parsed_range =
    match trim_opt window, trim_opt from_rev, trim_opt to_rev with
    | None, None, None -> Ok (Range_window Window_24h)
    | Some w, None, None ->
      (match window_of_string w with
       | Some win -> Ok (Range_window win)
       | None ->
         Error ("window", Printf.sprintf "invalid window %S; expected 24h, 7d, or 30d" w))
    | Some _, (Some _ | None), Some _ | Some _, Some _, None ->
      Error ("window", "cannot combine window with from_rev/to_rev")
    | None, None, Some _ ->
      Error ("from_rev", "from_rev is required when to_rev is specified")
    | None, Some raw_from, raw_to_opt ->
      (match int_of_string_opt raw_from with
       | None -> Error ("from_rev", "from_rev must be a non-negative integer")
       | Some from_v when from_v < 0 ->
         Error ("from_rev", "from_rev must be a non-negative integer")
       | Some from_v ->
         (match raw_to_opt with
          | None -> Ok (Range_revs { from_rev = from_v; to_rev = None })
          | Some raw_to ->
            (match int_of_string_opt raw_to with
             | None -> Error ("to_rev", "to_rev must be a non-negative integer")
             | Some to_v when to_v < from_v ->
               Error ("to_rev", "to_rev must be greater than or equal to from_rev")
             | Some to_v -> Ok (Range_revs { from_rev = from_v; to_rev = Some to_v }))))
  in
  Ok (parsed_scope, parsed_range)
;;

let error_result ?field code message =
  Error (Env.error_status code, Env.error_json ?field ~code message)
;;

let claim_sha256_of_fact (fact : Types.fact) =
  let id = Types.memory_id fact in
  let prefix = "sha256:" in
  if String.starts_with ~prefix id
  then String.sub id (String.length prefix) (String.length id - String.length prefix)
  else id
;;

let fact_lookup_for_keeper ~cache ~keepers_dir keeper_id =
  match Hashtbl.find_opt cache keeper_id with
  | Some table -> table
  | None ->
    let tbl = Hashtbl.create 32 in
    (match Cur.read_for_keepers_dir ~keepers_dir ~keeper_id with
     | Ok (Some snap) ->
       List.iter
         (fun (fact : Types.fact) ->
            Hashtbl.replace tbl (claim_sha256_of_fact fact) fact)
         snap.facts
     | Ok None | Error _ -> ());
    Hashtbl.replace cache keeper_id tbl;
    tbl
;;

let resolve_fact_ref_json ~cache ~keepers_dir (ref_ : Ledger.fact_ref) =
  match ref_ with
  | Ledger.Ordinary { keeper_id; claim_sha256 } ->
    let tbl = fact_lookup_for_keeper ~cache ~keepers_dir keeper_id in
    let resolved_fields =
      match Hashtbl.find_opt tbl claim_sha256 with
      | Some fact ->
        [ "resolved", `Bool true
        ; "claim", `String fact.claim
        ; "category", `String (Types.category_to_string fact.category)
        ; "origin", `String (Types.origin_kind_to_string fact.origin.kind)
        ; "first_seen_unix", `Float fact.first_seen
        ; "last_seen_unix", `Float fact.last_seen
        ]
      | None ->
        [ "resolved", `Bool false
        ; "claim", `Null
        ; "category", `Null
        ; "origin", `Null
        ; "first_seen_unix", `Null
        ; "last_seen_unix", `Null
        ]
    in
    `Assoc
      ([ "store_kind", `String "ordinary"
       ; "keeper_id", `String keeper_id
       ; "path", `Null
       ; "claim_sha256", `String claim_sha256
       ]
       @ resolved_fields)
  | Ledger.Source_bound { keeper_id; path; claim_sha256 } ->
    `Assoc
      [ "store_kind", `String "source_bound"
      ; "keeper_id", `String keeper_id
      ; "path", `String path
      ; "claim_sha256", `String claim_sha256
      ; "resolved", `Bool false
      ; "claim", `Null
      ; "category", `Null
      ; "origin", `Null
      ; "first_seen_unix", `Null
      ; "last_seen_unix", `Null
      ]
;;

let briefing_json ~briefing ~building =
  let status, text, source_ids_count, error =
    match briefing with
    | Error detail -> "unavailable", `Null, 0, Some detail
    | Ok Briefing.Missing -> "missing", `Null, 0, None
    | Ok (Briefing.Current summary) ->
      "current", `String summary.text, List.length summary.source_ids, None
    | Ok (Briefing.Stale summary) ->
      "stale", `String summary.text, List.length summary.source_ids, None
  in
  let building_json =
    match building with
    | Ok (Some (pass : Briefing.pass)) ->
      `Assoc [ "target", `Int pass.target; "remaining", `Int pass.remaining ]
    | Ok None | Error _ -> `Null
  in
  `Assoc
    [ "status", `String status
    ; "text", text
    ; "source_ids_count", `Int source_ids_count
    ; "error", Json_util.string_opt_to_json error
    ; "building_pass", building_json
    ]
;;

let rfc3339_of_unix ts =
  match Ptime.of_float_s ts with
  | Some p -> Ptime.to_rfc3339 ~tz_offset_s:0 p
  | None -> ""
;;

let world_fact_supporting_keepers (fact : World_memory_types.world_fact) =
  match fact.provenance with
  | World_memory_types.Proposed_by { keeper_id; _ } -> [ keeper_id ]
  | World_memory_types.Cross_keeper_synthesized { keeper_ids; _ } -> keeper_ids
;;

let world_fact_as_competing_claim_json (fact : World_memory_types.world_fact) =
  let keeper_id =
    match world_fact_supporting_keepers fact with
    | first :: _ -> first
    | [] -> "world"
  in
  `Assoc
    [ "store_kind", `String "world_memory_db"
    ; "keeper_id", `String keeper_id
    ; "path", `Null
    ; "claim_sha256", `String fact.fact_id
    ; "resolved", `Bool true
    ; "claim", `String fact.claim
    ; "category", `String (Types.category_to_string fact.category)
    ; "origin", `String (World_memory_types.lifecycle_to_string fact.lifecycle)
    ; "first_seen_unix", `Null
    ; "last_seen_unix", `Null
    ]
;;

let summary_references_private_scope (summary : string) : bool =
  let lower = String.lowercase_ascii summary in
  String_util.contains_substring lower "scope=keeper:"
  || String_util.contains_substring lower "scope=private:"
;;

let build_private_change_filter (snapshot : World_memory_store.consistent_snapshot) =
  let private_fact_ids : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let private_fact_id_list = ref [] in
  List.iter
    (fun (f : World_memory_types.world_fact) ->
       if World_memory_types.is_private_scope f.scope
       then (
         Hashtbl.replace private_fact_ids f.fact_id ();
         private_fact_id_list := f.fact_id :: !private_fact_id_list))
    snapshot.facts;
  let private_edge_seqs : (int, unit) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (e : World_memory_types.world_edge) ->
       if Hashtbl.mem private_fact_ids e.from_fact_id
          || Hashtbl.mem private_fact_ids e.to_fact_id
       then Hashtbl.replace private_edge_seqs e.created_seq ())
    snapshot.edges;
  let private_ids = !private_fact_id_list in
  let is_visible (ev : World_memory_types.change_event) : bool =
    if Hashtbl.mem private_fact_ids ev.target_id
    then false
    else if summary_references_private_scope ev.summary
    then false
    else (
      match ev.kind with
      | World_memory_types.Edge_added ->
        if Hashtbl.mem private_edge_seqs ev.seq
        then false
        else
          not
            (List.exists
               (fun pid -> String_util.contains_substring ev.summary pid)
               private_ids)
      | Fact_upserted | Fact_lifecycle_changed | Index_upserted | Digest_committed ->
        not
          (List.exists
             (fun pid -> String_util.contains_substring ev.summary pid)
             private_ids))
  in
  is_visible
;;

let world_json_from_mvcc_db ~now ~base_path ~writer_health =
  (* Read with [include_inactive:true] so [Superseded]/[Molted] keeper-private
     facts still seed [private_fact_ids] and never leak through change-log rows,
     while [public_facts] stays filtered to active shared workspace facts. *)
  match World_memory_store.read_snapshot ~include_inactive:true ~base_path () with
  | Error err ->
    error_result
      Env.Store_unavailable
      ("world memory db unavailable: " ^ World_memory_store.error_to_string err)
  | Ok snapshot ->
    (* Never leak keeper-private scoped facts into workspace-shared World Memory views. *)
    let public_facts =
      List.filter
        (fun (f : World_memory_types.world_fact) ->
           (not (World_memory_types.is_private_scope f.scope))
           && World_memory_types.is_active_lifecycle f.lifecycle)
        snapshot.facts
    in
    let public_fact_tbl : (string, World_memory_types.world_fact) Hashtbl.t =
      Hashtbl.create (max 16 (List.length public_facts))
    in
    List.iter
      (fun (f : World_memory_types.world_fact) -> Hashtbl.replace public_fact_tbl f.fact_id f)
      public_facts;
    let is_visible_change = build_private_change_filter snapshot in
    let public_edges =
      List.filter
        (fun (e : World_memory_types.world_edge) ->
           Hashtbl.mem public_fact_tbl e.from_fact_id
           && Hashtbl.mem public_fact_tbl e.to_fact_id)
        snapshot.edges
    in
    let active_conflicts_json =
      public_edges
      |> List.filter_map (fun (e : World_memory_types.world_edge) ->
           match e.kind with
           | World_memory_types.Contradicts ->
             let members =
               List.filter_map
                 (Hashtbl.find_opt public_fact_tbl)
                 [ e.from_fact_id; e.to_fact_id ]
             in
             Some
               (`Assoc
                 [ "conflict_id", `String (e.from_fact_id ^ ":" ^ e.to_fact_id)
                 ; "description", `String e.reason
                 ; "member_count", `Int (List.length members)
                 ; ( "competing_claims"
                   , `List (List.map world_fact_as_competing_claim_json members) )
                 ])
           | Supersedes | Refines | Synthesizes_from -> None)
    in
    let claims_json =
      List.map
        (fun (fact : World_memory_types.world_fact) ->
           let keepers = world_fact_supporting_keepers fact in
           `Assoc
             [ "claim_id", `String fact.fact_id
             ; "claim", `String fact.claim
             ; "stage", `String (World_memory_types.lifecycle_to_string fact.lifecycle)
             ; "supporting_keepers", `List (List.map (fun k -> `String k) keepers)
             ; "support_count", `Int (max 1 (List.length keepers))
             ; "has_source_bound", `Bool false
             ; "category", `String (Types.category_to_string fact.category)
             ; "scope", `String fact.scope
             ; "facets", `List (List.map (fun fc -> `String fc) fact.facets)
             ; "revision", `Int fact.revision
             ])
        public_facts
    in
    let briefing_obj, digest_sha256, mvcc_summary =
      match snapshot.digest with
      | None ->
        ( `Assoc
            [ "status", `String "missing"
            ; "text", `Null
            ; "source_ids_count", `Int 0
            ; "error", `Null
            ; "building_pass", `Null
            ]
        , `Null
        , `Assoc
            [ "digest_revision", `Null
            ; "digest_sha256", `Null
            ; "edges_count", `Int (List.length public_edges)
            ; "index_count", `Int (List.length snapshot.entries)
            ; "canonical_count", `Int 0
            ; "wiki_count", `Int 0
            ; "artifact_count", `Int 0
            ; "resource_count", `Int 0
            ] )
      | Some d ->
        ( `Assoc
            [ "status", `String "current"
            ; "text", `String d.rendered
            ; "source_ids_count", `Int d.fact_count
            ; "error", `Null
            ; "building_pass", `Null
            ]
        , `String d.digest_sha256
        , `Assoc
            [ "digest_revision", `Int d.digest_revision
            ; "digest_sha256", `String d.digest_sha256
            ; "edges_count", `Int (List.length public_edges)
            ; "index_count", `Int (List.length snapshot.entries)
            ; "canonical_count", `Int d.canonical_count
            ; "wiki_count", `Int d.wiki_count
            ; "artifact_count", `Int d.artifact_count
            ; "resource_count", `Int d.resource_count
            ] )
    in
    let log_report_json =
      match World_memory_store.read_change_log_tail ~base_path ~limit:200 with
      | Error err ->
        `Assoc
          [ "status", `String "unavailable"
          ; "error", `String (World_memory_store.error_to_string err)
          ; "last_committed_seq", `Int 0
          ; "committed_changes_count", `Int 0
          ; "incomplete_batches_count", `Int 0
          ; "aborted_batches_count", `Int 0
          ; "recent_changes", `List []
          ]
      | Ok (events, max_seq) ->
        let visible_events = List.filter is_visible_change events in
        let recent =
          visible_events
          |> List.rev
          |> Server_utils.take 20
          |> List.map (fun (ev : World_memory_types.change_event) ->
               `Assoc
                 [ "seq", `Int ev.seq
                 ; ( "batch_id"
                   , `String (World_memory_types.change_event_kind_to_string ev.kind) )
                 ; "fact_id", `String ev.target_id
                 ; "summary", `String ev.summary
                 ; "recorded_at", `String (rfc3339_of_unix ev.recorded_at)
                 ])
        in
        `Assoc
          [ "status", `String "available"
          ; "error", `Null
          ; "last_committed_seq", `Int max_seq
          ; "committed_changes_count", `Int (List.length visible_events)
          ; "incomplete_batches_count", `Int 0
          ; "aborted_batches_count", `Int 0
          ; "recent_changes", `List recent
          ]
    in
    let data =
      `Assoc
        [ "source", `String "world_memory_db"
        ; "ledger_state", `String "available"
        ; ( "inventory"
          , `Assoc
              [ "ledger_sha256", digest_sha256
              ; "claims_count", `Int (List.length claims_json)
              ; "facts_count", `Int (List.length public_facts)
              ; "classified_count", `Int (List.length public_facts)
              ; "conflicts_count", `Int (List.length active_conflicts_json)
              ; "excluded_count", `Int 0
              ; "ordinary_absence", `Null
              ] )
        ; "world_mvcc", mvcc_summary
        ; "claims", `List claims_json
        ; "active_conflicts", `List active_conflicts_json
        ; "briefing", briefing_obj
        ; "recent_batches", log_report_json
        ; "librarian_writers", writer_health
        ]
    in
    Ok (Env.ok ~now data)
;;

let world_json ?(now = Time_compat.now ()) ~config () =
  let base_path = config.Workspace.base_path in
  let writer_health = Keeper_memory_writer_health.section_json ~config in
  if World_memory_store.exists ~base_path
  then world_json_from_mvcc_db ~now ~base_path ~writer_health
  else (
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let obs = Ledger.observe ~base_path in
  let log_report_json =
    match Wlog.recover_file ~path:(Wlog.log_path ~base_path) with
    | Error err ->
      `Assoc
        [ "status", `String "unavailable"
        ; "error", `String (Wlog.error_to_string err)
        ; "last_committed_seq", `Int 0
        ; "committed_changes_count", `Int 0
        ; "incomplete_batches_count", `Int 0
        ; "aborted_batches_count", `Int 0
        ; "recent_changes", `List []
        ]
    | Ok report ->
      let recent =
        report.Wlog.committed_changes
        |> List.rev
        |> Server_utils.take 20
        |> List.map (fun (c : Wlog.change_entry) ->
             `Assoc
               [ "seq", `Int c.seq
               ; "batch_id", `String c.batch_id
               ; "fact_id", `String c.fact_id
               ; "summary", `String c.summary
               ; "recorded_at", `String c.recorded_at
               ])
      in
      `Assoc
        [ "status", `String "available"
        ; "error", `Null
        ; "last_committed_seq", `Int report.last_committed_seq
        ; "committed_changes_count", `Int (List.length report.committed_changes)
        ; "incomplete_batches_count", `Int (List.length report.incomplete_batches)
        ; "aborted_batches_count", `Int (List.length report.aborted_batches)
        ; "recent_changes", `List recent
        ]
  in
  match obs with
  | Ledger.Unavailable detail ->
    error_result Env.Store_unavailable ("world memory ledger unavailable: " ^ detail)
  | Ledger.Missing ->
    let data =
      `Assoc
        [ "ledger_state", `String "missing"
        ; ( "inventory"
          , `Assoc
              [ "ledger_sha256", `Null
              ; "claims_count", `Int 0
              ; "facts_count", `Int 0
              ; "conflicts_count", `Int 0
              ; "excluded_count", `Int 0
              ] )
        ; "claims", `List []
        ; "active_conflicts", `List []
        ; ( "briefing"
          , `Assoc
              [ "status", `String "missing"
              ; "text", `Null
              ; "source_ids_count", `Int 0
              ; "error", `Null
              ; "building_pass", `Null
              ] )
        ; "recent_batches", log_report_json
        ; "librarian_writers", writer_health
        ]
    in
    Ok (Env.ok ~now data)
  | Ledger.Available
      { ledger_sha256
      ; claim_count
      ; conflict_count
      ; classified_count
      ; excluded_count
      ; briefing
      ; building
      } ->
    (match Ledger.load ~base_path with
     | Error detail ->
       error_result Env.Store_unavailable ("world memory ledger load failed: " ^ detail)
     | Ok ledger ->
       let fact_cache = Hashtbl.create 16 in
       let conflict_members = Hashtbl.create 8 in
       List.iter
         (fun (fact_ref, disp) ->
            match disp with
            | Ledger.Conflict_member cid ->
              let prev =
                match Hashtbl.find_opt conflict_members cid with
                | Some lst -> lst
                | None -> []
              in
              Hashtbl.replace conflict_members cid (fact_ref :: prev)
            | Ledger.Claim_member _ | Ledger.Excluded _ -> ())
         (Ledger.dispositions ledger);
       let active_conflicts_json =
         Ledger.conflicts ledger
         |> List.map (fun (conflict_id, description) ->
              let refs =
                match Hashtbl.find_opt conflict_members conflict_id with
                | Some lst -> List.rev lst
                | None -> []
              in
              `Assoc
                [ "conflict_id", `String conflict_id
                ; "description", `String description
                ; "member_count", `Int (List.length refs)
                ; ( "competing_claims"
                  , `List
                      (List.map (resolve_fact_ref_json ~cache:fact_cache ~keepers_dir) refs) )
                ])
       in
       let claims_json =
         Ledger.all_claim_provenance ledger
         |> List.map (fun (prov : Ledger.claim_provenance) ->
              `Assoc
                [ "claim_id", `String prov.claim_id
                ; "claim", `String prov.claim
                ; "stage", `String (Ledger.corroboration_stage_to_string prov.stage)
                ; ( "supporting_keepers"
                  , `List (List.map (fun k -> `String k) prov.supporting_keepers) )
                ; "support_count", `Int prov.support_count
                ; "has_source_bound", `Bool prov.has_source_bound
                ])
       in
       let ordinary_absence_json =
         match Workspace_memory_ledger_view.inventory ~now ~base_path () with
         | Ok inv ->
           (match Json_util.assoc_member_opt "ordinary_absence" inv with
            | Some v -> v
            | None -> `Null)
         | Error _ -> `Null
       in
       let data =
         `Assoc
           [ "ledger_state", `String "available"
           ; ( "inventory"
             , `Assoc
                 [ "ledger_sha256", `String ledger_sha256
                 ; "claims_count", `Int claim_count
                 ; "facts_count", `Int (classified_count + excluded_count)
                 ; "classified_count", `Int classified_count
                 ; "conflicts_count", `Int conflict_count
                 ; "excluded_count", `Int excluded_count
                 ; "ordinary_absence", ordinary_absence_json
                 ] )
           ; "claims", `List claims_json
           ; "active_conflicts", `List active_conflicts_json
           ; "briefing", briefing_json ~briefing ~building
           ; "recent_batches", log_report_json
           ; "librarian_writers", writer_health
           ]
       in
       Ok (Env.ok ~now data)))
;;

type heat_stats =
  { retrieved_count : int
  ; last_retrieved_at : float option
  ; heat : retrieval_heat
  }

let build_event_heat_table ?(wanted = fun _ -> true) ~now ~keepers_dir ~keeper_id () =
  let counts = Hashtbl.create 64 and last_seen = Hashtbl.create 64 in
  let record (total, unreadable) = function
    | Error _ -> total, unreadable + 1
    | Ok (ev : Events.event) ->
      if wanted ev.memory_id then (
        let prior = Option.value ~default:0 (Hashtbl.find_opt counts ev.memory_id) in
        Hashtbl.replace counts ev.memory_id (prior + 1);
        let last = Option.value ~default:ev.recorded_at (Hashtbl.find_opt last_seen ev.memory_id) in
        Hashtbl.replace last_seen ev.memory_id (max last ev.recorded_at));
      total + 1, unreadable in
  let total_events, unreadable = match Events.fold ~keepers_dir ~keeper_id ~init:(0, 0) ~f:record with
    | Ok totals -> totals
    | Error _ -> Hashtbl.clear counts; Hashtbl.clear last_seen; 0, 0 in
  let lookup memory_id =
    let retrieved_count =
      match Hashtbl.find_opt counts memory_id with
      | Some n -> n
      | None -> 0
    in
    let last_retrieved_at = Hashtbl.find_opt last_seen memory_id in
    let heat = classify_retrieval_heat ~now ~retrieved_count ~last_retrieved_at in
    { retrieved_count; last_retrieved_at; heat }
  in
  lookup, total_events, unreadable
;;

let fact_diff_entry_fields ~heat_lookup (fact : Types.fact) =
  let id = Types.memory_id fact in
  let hs = heat_lookup id in
  [ "memory_id", `String id
    ; "category", `String (Types.category_to_string fact.category)
    ; "origin", `String (Types.origin_kind_to_string fact.origin.kind)
    ; "text", `String fact.claim
    ; "first_seen_unix", `Float fact.first_seen
    ; "last_seen_unix", `Float fact.last_seen
    ; "retrieval_count", `Int hs.retrieved_count
    ; "last_retrieved_at_unix", Json_util.float_opt_to_json hs.last_retrieved_at
    ; "heat", `String (retrieval_heat_to_string hs.heat)
    ]
;;

let keeper_diff_json ~now ~config ~keeper_id ~range =
  let module Diff = Librarian_history_diff in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
  match Cur.read_for_keepers_dir ~keepers_dir ~keeper_id with
  | Error detail -> error_result Env.Store_unavailable ("snapshot read failed: " ^ detail)
  | Ok snapshot ->
    let current = Option.fold ~none:[] ~some:(fun (s : Cur.t) -> s.facts) snapshot in
    let revision = Option.fold ~none:0 ~some:(fun (s : Cur.t) -> s.revision) snapshot in
    let filter, window, lo_time, hi_time, from_rev =
      match range with
      | Range_window w ->
        let lo = now -. window_seconds w in
        Diff.Time (lo, now), Some (window_to_string w), Some lo, Some now, None
      | Range_revs { from_rev; to_rev } ->
        Diff.Revisions (from_rev, Option.value ~default:max_int to_rev), None, None, None, Some from_rev in
    let max_bytes = Keeper_memory_os_render.hard_backstop_bytes
        ~maximum_bytes:(Env_config.KeeperMemoryOs.facts_max_bytes ()) in
    match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Librarian_history_window.read ~range:filter ~max_bytes log_path) with
    | Error error -> error_result Env.Store_unavailable
                       ("memory history read failed: " ^ Private_jsonl_scan.error_to_string error)
    | Ok history ->
      let to_rev = match range with
        | Range_window _ -> None
        | Range_revs { to_rev = Some rev; _ } -> Some rev
        | Range_revs { to_rev = None; _ } -> Some (List.fold_left (fun hi (c : Librarian_memory_change.t) ->
            max hi c.revision) revision history.changes) in
      let diff = Diff.project_window ~range:filter ~current ~revision history in
      let visible = Hashtbl.create 64 in
      let remember fact = Hashtbl.replace visible (Types.memory_id fact) () in
      List.iter remember current;
      List.iter (function
        | _, Diff.Added f -> remember f
        | _, Updated { before; after; _ } -> remember before; remember after
        | _, (Removed _ | Successor_unavailable _) -> ()) diff.events;
      let heat_lookup, total_events, unreadable_events =
        build_event_heat_table ~wanted:(Hashtbl.mem visible) ~now ~keepers_dir ~keeper_id () in
      let fact_fields = fact_diff_entry_fields ~heat_lookup in
      let int_opt = Json_util.int_opt_to_json in
      let relation = function
        | Diff.Revision -> "revision" | Program_revision -> "program_revision"
        | Program_absorption -> "program_absorption" in
      let added = ref [] and updated = ref [] and retracted = ref [] and invalidated = ref [] and unresolved = ref [] in
      let rows_left = ref Librarian_archive.max_detailed_rows and bytes_left = ref max_bytes in
      let output_rows = ref diff.events_limited and output_bytes = ref false in
      let admit rows =
        let count = List.length rows in
        if count > !rows_left then (output_rows := true; false)
        else
          let bytes = List.fold_left (fun n (_, row) -> n + String.length (Yojson.Safe.to_string row) + 1) 0 rows in
          if bytes > !bytes_left then (output_bytes := true; false)
          else (bytes_left := !bytes_left - bytes; rows_left := !rows_left - count; true) in
      let ordered = List.mapi (fun order event -> order, event) diff.events in
      List.iter (fun (order, ((p : Diff.position), event)) ->
        let group = ref [] in
        let push target fields =
          group := (target, `Assoc (("order", `Int order) :: ("seq", int_opt p.seq) ::
                             ("at_unix", `Float p.at) :: fields)) :: !group
        in
        (match event with
        | Diff.Added f ->
          push added (("added_at_rev", int_opt p.revision) :: fact_fields f)
        | Updated { before; after; relation = r; body_source } ->
          let provenance = match body_source with
            | Diff.Same_commit -> "same_commit" | Held_before -> "held_before"
            | Current_snapshot -> "current_snapshot" | Archived_fact -> "archived_fact" in
          push updated [ "relation", `String (relation r); "at_rev", int_opt p.revision
                       ; "before", `Assoc (fact_fields before); "after", `Assoc (fact_fields after); "after_source", `String provenance ]
        | Successor_unavailable { before; successor_id; relation = r } ->
          push unresolved [ "before_id", `String (Types.memory_id before); "after_id", `String successor_id
                          ; "relation", `String (relation r); "at_rev", int_opt p.revision ]
        | Removed { fact; reason; missing } ->
          push retracted [ "memory_id", `String (Types.memory_id fact); "category", `String (Types.category_to_string fact.category)
                         ; "text", `String fact.claim; "removed_at_rev", int_opt p.revision
                         ; "removed_by", Json_util.string_opt_to_json (Option.map (fun (s : Cur.source) -> Cur.source_kind_to_string s.kind) p.source)
                         ; "drop_reason", Json_util.string_opt_to_json reason ];
          Option.iter (fun ids ->
            push invalidated [ "memory_id", `String (Types.memory_id fact); "text", `String fact.claim
                             ; "at_rev", int_opt p.revision; "missing_premise_ids", `List (List.map (fun s -> `String s) ids) ]) missing);
        if admit !group then List.iter (fun (target, row) -> target := row :: !target) !group)
        (List.rev ordered);
      let ticks = List.fold_left (fun ticks (c : Librarian_memory_change.t) ->
          let invalidated = List.fold_left (fun n (_, what) ->
            match what with Librarian_effects.Support_lost _ -> n + 1
            | Dropped _ | Molted _ | Merged_into _ | Revised_into _ | Superseded_by _ | Retracted _ -> n) 0 c.removed in
          let row = `Assoc [ "seq", `Int c.seq; "rev", `Int c.revision; "at_unix", `Float c.at
                 ; "source", `String (Cur.source_kind_to_string c.source.kind)
                 ; "added", `Int (List.length c.added); "removed", `Int (List.length c.removed)
                 ; "invalidated", `Int invalidated ] in
          if admit [(), row] then row :: ticks else ticks) [] (List.rev diff.ticks) in
      let hot = ref 0 and warm = ref 0 and cold = ref 0 and never = ref 0 in
      List.iter (fun fact -> match (heat_lookup (Types.memory_id fact)).heat with
        | Heat_hot -> incr hot | Heat_warm -> incr warm | Heat_cold -> incr cold | Heat_never -> incr never) current;
      let first_rev = function [] -> None | (c : Librarian_memory_change.t) :: _ -> Some c.revision in
      let count rows = `Int (List.length !rows) and body rows = `List !rows in
      let unplaced =
        match filter, history.changes with
        | Diff.Time _, _ -> 0
        | Revisions (lo, _), (first : Librarian_memory_change.t) :: _ when lo > first.revision -> 0
        | Revisions _, _ -> history.unsequenced_count in
      let retention_applies = Option.fold ~none:false ~some:(Librarian_history_window.intersects filter) history.folded in
      let retention = match history.folded with None -> `Null | Some f ->
        `Assoc ["through_seq", `Int f.through_seq; "min_revision", `Int f.min_revision;
                "max_revision", `Int f.max_revision; "min_at", `Float f.min_at; "max_at", `Float f.max_at] in
      let partial = history.input_limited || !output_rows || !output_bytes || retention_applies || history.conflicting > 0 || history.unreadable > 0 || diff.gaps <> [] || diff.snapshot_ahead || diff.snapshot_behind
                    || unplaced > 0 || diff.unsequenced_in_range > 0 || !unresolved <> [] in
      Ok (Env.ok ~now
        (`Assoc
           [ "scope", `Assoc [ "kind", `String "keeper"; "keeper", `String keeper_id ]
           ; "range", `Assoc [ "window", Json_util.string_opt_to_json window
                             ; "from_rev", int_opt (match from_rev with Some _ -> from_rev | None -> first_rev diff.ticks)
                             ; "to_rev", int_opt (match to_rev with Some _ -> to_rev | None -> first_rev (List.rev diff.ticks))
                             ; "from_unix", Json_util.float_opt_to_json lo_time; "to_unix", Json_util.float_opt_to_json hi_time ]
           ; "coverage", `Assoc [ "status", `String (if partial then "partial" else "complete")
                                ; "folded_detail", retention; "retention_applies", `Bool retention_applies
                                ; "input_limited", `Bool history.input_limited; "output_limited", `Bool (!output_rows || !output_bytes)
                                ; "limit_causes", `List (List.filter_map (fun (hit, name) ->
                                  if hit then Some (`String name) else None)
                                  [ history.live_cut.by_rows, "live_rows"; history.live_cut.by_bytes, "live_bytes";
                                    history.archive_cut.by_rows, "archive_rows"; history.archive_cut.by_bytes, "archive_bytes";
                                    !output_rows, "result_rows"; !output_bytes, "result_bytes" ])
                                ; "row_limit", `Int Librarian_archive.max_detailed_rows; "byte_limit", `Int max_bytes
                                ; "conflicting_sequences", `Int history.conflicting
                                ; "unsequenced_in_window", `Int diff.unsequenced_in_range
                                ; "unplaced_in_revision_range", `Int unplaced
                                ; "missing_sequences", `List (List.map (fun (g : Diff.gap) ->
                                      `Assoc [ "first", `Int g.first_seq; "last", `Int g.last_seq ]) diff.gaps)
                                ; "snapshot_ahead", `Bool diff.snapshot_ahead; "snapshot_behind", `Bool diff.snapshot_behind
                                ; "unreadable_lines", `Int history.unreadable
                                ; "unresolved_successors", count unresolved ]
           ; "counts", `Assoc [ "total_facts_now", `Int (List.length current); "added", count added; "updated", count updated
                              ; "retracted", count retracted; "invalidated", count invalidated
                              ; "journal_failures_in_window", `Int 0; "journal_quarantines_in_window", `Int 0
                              ; "undecodable_journal_lines", `Int (history.unreadable + history.conflicting) ]
           ; "retrieval_heat", `Assoc [ "hot", `Int !hot; "warm", `Int !warm; "cold", `Int !cold; "never_retrieved", `Int !never
                                      ; "total_events", `Int total_events; "unreadable_event_lines", `Int unreadable_events ]
           ; "revisions", `List ticks; "added", body added; "updated", body updated; "retracted", body retracted
           ; "invalidated", body invalidated; "unresolved_links", body unresolved
           ; "writer_status", Keeper_memory_writer_health.keeper_rows ~config keeper_id ]))
;;

let parse_rfc3339_unix raw =
  match Ptime.of_rfc3339 raw with
  | Ok (ptime, _, _) -> Some (Ptime.to_float_s ptime)
  | Error _ -> None
;;

let strip_entity_prefix (raw : string) : string =
  let trimmed = String.trim raw in
  if String.starts_with ~prefix:"claim:" trimmed
  then String.sub trimmed 6 (String.length trimmed - 6)
  else if String.starts_with ~prefix:"conflict:" trimmed
  then String.sub trimmed 9 (String.length trimmed - 9)
  else trimmed
;;

let nonblank_string_opt = function
  | Some (`String s) ->
    let trimmed = String.trim s in
    if String.equal trimmed "" then None else Some trimmed
  | Some _ | None -> None
;;

let assoc_nonblank_string_opt key json =
  nonblank_string_opt (Json_util.assoc_member_opt key json)
;;

let first_some_opt = function
  | [] -> None
  | xs -> List.find_map Fun.id xs
;;

let extract_text_from_json json =
  match json with
  | `String s ->
    let trimmed = String.trim s in
    if String.equal trimmed "" then None else Some trimmed
  | `Assoc _ ->
    first_some_opt
      [ assoc_nonblank_string_opt "claim_text" json
      ; assoc_nonblank_string_opt "claim" json
      ; assoc_nonblank_string_opt "description" json
      ; assoc_nonblank_string_opt "summary" json
      ]
  | _ -> None
;;

let extract_author_keeper_from_payload payload =
  let from_fact =
    match Json_util.assoc_member_opt "fact" payload with
    | Some (`Assoc _ as fact_json) -> assoc_nonblank_string_opt "keeper_id" fact_json
    | Some _ | None -> None
  in
  let from_vanished =
    match Json_util.assoc_member_opt "vanished_keepers" payload with
    | Some (`List (first :: _)) -> nonblank_string_opt (Some first)
    | Some _ | None -> None
  in
  first_some_opt
    [ assoc_nonblank_string_opt "author_keeper" payload
    ; assoc_nonblank_string_opt "keeper_id" payload
    ; from_fact
    ; from_vanished
    ]
;;

let claim_id_of_change_entry (c : Wlog.change_entry) =
  let from_payload =
    first_some_opt
      [ assoc_nonblank_string_opt "claim_id" c.payload
      ; assoc_nonblank_string_opt "conflict_id" c.payload
      ]
  in
  match from_payload with
  | Some _ as id -> id
  | None ->
    let trimmed = String.trim c.fact_id in
    if String.starts_with ~prefix:"claim:" trimmed
       || String.starts_with ~prefix:"conflict:" trimmed
       || String.starts_with ~prefix:"claim-" trimmed
       || String.starts_with ~prefix:"conflict-" trimmed
    then Some (strip_entity_prefix trimmed)
    else None
;;

let fleet_retrieval_heat_json ~now ~keepers_dir =
  let keeper_ids = Cur.list_keeper_ids_for_keepers_dir ~keepers_dir in
  let hot = ref 0 in
  let warm = ref 0 in
  let cold = ref 0 in
  let never = ref 0 in
  let total_events = ref 0 in
  let unreadable_events = ref 0 in
  List.iter
    (fun kid ->
       let lookup, ev_c, unr_c = build_event_heat_table ~now ~keepers_dir ~keeper_id:kid () in
       total_events := !total_events + ev_c;
       unreadable_events := !unreadable_events + unr_c;
       match Cur.read_for_keepers_dir ~keepers_dir ~keeper_id:kid with
       | Ok (Some snap) ->
         List.iter
           (fun fact ->
              match (lookup (Types.memory_id fact)).heat with
              | Heat_hot -> incr hot
              | Heat_warm -> incr warm
              | Heat_cold -> incr cold
              | Heat_never -> incr never)
           snap.facts
       | Ok None | Error _ -> ())
    keeper_ids;
  `Assoc
    [ "hot", `Int !hot
    ; "warm", `Int !warm
    ; "cold", `Int !cold
    ; "never_retrieved", `Int !never
    ; "total_events", `Int !total_events
    ; "unreadable_event_lines", `Int !unreadable_events
    ]
;;

let world_diff_json_from_mvcc_db ~now ~base_path ~keepers_dir ~range =
  match World_memory_store.read_snapshot ~include_inactive:true ~base_path () with
  | Error err ->
    error_result
      Env.Store_unavailable
      ("world memory db unavailable: " ^ World_memory_store.error_to_string err)
  | Ok snapshot ->
    let change_log_res =
      match range with
      | Range_window _ -> World_memory_store.read_change_log_tail ~base_path ~limit:500
      | Range_revs { from_rev; _ } ->
        World_memory_store.read_change_log ~base_path ~since_seq:(max 0 (from_rev - 1)) ~limit:500
    in
    (match change_log_res with
     | Error err ->
       error_result
         Env.Store_unavailable
         ("world memory change log unavailable: " ^ World_memory_store.error_to_string err)
     | Ok (events, max_seq) ->
       let is_visible_change = build_private_change_filter snapshot in
       let public_fact_tbl : (string, World_memory_types.world_fact) Hashtbl.t = Hashtbl.create 32 in
       let active_public_count = ref 0 in
       List.iter
         (fun (f : World_memory_types.world_fact) ->
            if not (World_memory_types.is_private_scope f.scope)
            then (
              Hashtbl.replace public_fact_tbl f.fact_id f;
              if World_memory_types.is_active_lifecycle f.lifecycle
              then incr active_public_count))
         snapshot.facts;
       let visible_events = List.filter is_visible_change events in
       let from_unix_opt, to_unix_opt, from_rev_opt, to_rev_opt, window_label =
         match range with
         | Range_window w ->
           let span = window_seconds w in
           Some (now -. span), Some now, None, None, Some (window_to_string w)
         | Range_revs { from_rev; to_rev } ->
           None, None, Some from_rev, Some (Option.value to_rev ~default:max_seq), None
       in
       let selected =
         List.filter
           (fun (ev : World_memory_types.change_event) ->
              match range with
              | Range_window _ ->
                (match from_unix_opt, to_unix_opt with
                 | Some lo, Some hi ->
                   Float.compare ev.recorded_at lo >= 0 && Float.compare ev.recorded_at hi <= 0
                 | None, _ | _, None -> false)
              | Range_revs _ ->
                (match from_rev_opt, to_rev_opt with
                 | Some lo, Some hi -> ev.seq >= lo && ev.seq <= hi
                 | None, _ | _, None -> false))
           visible_events
       in
       let added = ref [] in
       let updated = ref [] in
       let retracted = ref [] in
       let revisions = ref [] in
       List.iter
         (fun (ev : World_memory_types.change_event) ->
            let fact_opt = Hashtbl.find_opt public_fact_tbl ev.target_id in
            let op_kind =
              match ev.kind with
              | World_memory_types.Fact_lifecycle_changed ->
                (match fact_opt with
                 | Some { lifecycle = Superseded | Molted; _ } -> "retracted"
                 | Some { lifecycle = Working | Consolidated | Canonical; _ } | None -> "updated")
              | Fact_upserted ->
                (match fact_opt with
                 | Some f when f.revision > 1 -> "updated"
                 | Some _ | None -> "added")
              | Edge_added | Index_upserted | Digest_committed -> "added"
            in
            let claim_text_opt = Option.map (fun (f : World_memory_types.world_fact) -> f.claim) fact_opt in
            let recorded_iso = rfc3339_of_unix ev.recorded_at in
            let payload_json = World_memory_types.change_event_to_json ev in
            let enrichment_fields =
              [ "claim_id", `String ev.target_id
              ; "claim_text", Json_util.string_opt_to_json claim_text_opt
              ; "before_text", `Null
              ; "author_keeper", `String ev.actor
              ; "ts", `Float ev.recorded_at
              ]
            in
            let entry_json =
              `Assoc
                ([ "seq", `Int ev.seq
                 ; "batch_id", `String (World_memory_types.change_event_kind_to_string ev.kind)
                 ; "fact_id", `String ev.target_id
                 ; "summary", `String ev.summary
                 ; "recorded_at", `String recorded_iso
                 ; "payload", payload_json
                 ]
                 @ enrichment_fields)
            in
            revisions
            := `Assoc
                 [ "rev", `Int ev.seq
                 ; "batch_id", `String (World_memory_types.change_event_kind_to_string ev.kind)
                 ; "fact_id", `String ev.target_id
                 ; "recorded_at", `String recorded_iso
                 ; "op", `String op_kind
                 ]
               :: !revisions;
            if String.equal op_kind "retracted"
            then retracted := entry_json :: !retracted
            else if String.equal op_kind "updated"
            then
              updated
              := `Assoc
                   ([ "seq", `Int ev.seq
                    ; "fact_id", `String ev.target_id
                    ; "summary", `String ev.summary
                    ; "recorded_at", `String recorded_iso
                    ; "before", `Null
                    ; "after", payload_json
                    ]
                    @ enrichment_fields)
                 :: !updated
            else added := entry_json :: !added)
         selected;
       let data =
         `Assoc
           [ "source", `String "world_memory_db"
           ; "scope", `Assoc [ "kind", `String "world" ]
           ; ( "range"
             , `Assoc
                 [ "window", Json_util.string_opt_to_json window_label
                 ; "from_rev", Json_util.int_opt_to_json from_rev_opt
                 ; ( "to_rev"
                   , Json_util.int_opt_to_json
                       (match to_rev_opt with
                        | Some _ as t -> t
                        | None -> Some max_seq) )
                 ; "from_unix", Json_util.float_opt_to_json from_unix_opt
                 ; "to_unix", Json_util.float_opt_to_json to_unix_opt
                 ] )
           ; ( "counts"
             , `Assoc
                 [ "total_claims_now", `Int !active_public_count
                 ; "added", `Int (List.length !added)
                 ; "updated", `Int (List.length !updated)
                 ; "retracted", `Int (List.length !retracted)
                 ; "incomplete_batches", `Int 0
                 ; "aborted_batches", `Int 0
                 ] )
           ; "retrieval_heat", fleet_retrieval_heat_json ~now ~keepers_dir
           ; "revisions", `List (List.rev !revisions)
           ; "added", `List (List.rev !added)
           ; "updated", `List (List.rev !updated)
           ; "retracted", `List (List.rev !retracted)
           ; "unparseable_timestamps", `Int 0
           ]
       in
       Ok (Env.ok ~now data))
;;

let world_diff_json ~now ~config ~range =
  let base_path = config.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  if World_memory_store.exists ~base_path
  then world_diff_json_from_mvcc_db ~now ~base_path ~keepers_dir ~range
  else
  match Wlog.recover_file ~path:(Wlog.log_path ~base_path) with
  | Error err ->
    error_result
      Env.Store_unavailable
      ("world memory log unavailable: " ^ Wlog.error_to_string err)
  | Ok report ->
    let ledger_opt =
      match Ledger.load ~base_path with
      | Ok ledger -> Some ledger
      | Error _ -> None
    in
    let claim_text_tbl : (string, string) Hashtbl.t = Hashtbl.create 64 in
    let prior_text_tbl : (int, string) Hashtbl.t = Hashtbl.create 16 in
    let claim_author_tbl : (string, string) Hashtbl.t = Hashtbl.create 64 in
    let fact_cache : (string, (string, Types.fact) Hashtbl.t) Hashtbl.t = Hashtbl.create 16 in
    (* Seed historical claim/conflict text and authors chronologically from
       committed log entries so retracted claims retain human-readable text. *)
    List.iter
      (fun (c : Wlog.change_entry) ->
         let cid_opt = claim_id_of_change_entry c in
         let payload_text_opt =
           let from_after =
             match Json_util.assoc_member_opt "after" c.payload with
             | Some after_json -> extract_text_from_json after_json
             | None -> None
           in
           first_some_opt
             [ assoc_nonblank_string_opt "claim_text" c.payload
             ; assoc_nonblank_string_opt "claim" c.payload
             ; assoc_nonblank_string_opt "description" c.payload
             ; from_after
             ]
         in
         (match cid_opt, payload_text_opt with
          | Some cid, Some text ->
            (match Hashtbl.find_opt claim_text_tbl cid with
             | Some prev when not (String.equal prev text) ->
               Hashtbl.replace prior_text_tbl c.seq prev
             | Some _ | None -> ());
            Hashtbl.replace claim_text_tbl cid text;
            Hashtbl.replace claim_text_tbl c.fact_id text
          | None, Some text -> Hashtbl.replace claim_text_tbl c.fact_id text
          | _, None -> ());
         match cid_opt, extract_author_keeper_from_payload c.payload with
         | Some cid, Some author ->
           if not (Hashtbl.mem claim_author_tbl cid)
           then Hashtbl.replace claim_author_tbl cid author
         | _, _ -> ())
      report.committed_changes;
    (* Overlay authoritative current ledger claims, conflicts, and provenance. *)
    (match ledger_opt with
     | None -> ()
     | Some ledger ->
       List.iter
         (fun (cid, text) ->
            Hashtbl.replace claim_text_tbl cid text;
            Hashtbl.replace claim_text_tbl ("claim:" ^ cid) text)
         (Ledger.claims ledger);
       List.iter
         (fun (cid, desc) ->
            Hashtbl.replace claim_text_tbl cid desc;
            Hashtbl.replace claim_text_tbl ("conflict:" ^ cid) desc)
         (Ledger.conflicts ledger);
       List.iter
         (fun (prov : Ledger.claim_provenance) ->
            match prov.supporting_keepers with
            | first :: _ ->
              if not (Hashtbl.mem claim_author_tbl prov.claim_id)
              then Hashtbl.replace claim_author_tbl prov.claim_id first
            | [] -> ())
         (Ledger.all_claim_provenance ledger));
    let from_unix_opt, to_unix_opt, from_rev_opt, to_rev_opt, window_label =
      match range with
      | Range_window w ->
        let span = window_seconds w in
        Some (now -. span), Some now, None, None, Some (window_to_string w)
      | Range_revs { from_rev; to_rev } ->
        ( None
        , None
        , Some from_rev
        , Some (Option.value to_rev ~default:report.last_committed_seq)
        , None )
    in
    let unparseable_timestamps = ref 0 in
    let selected =
      List.filter
        (fun (c : Wlog.change_entry) ->
           match range with
           | Range_window _ ->
             (match from_unix_opt, to_unix_opt, parse_rfc3339_unix c.recorded_at with
              | Some lo, Some hi, Some ts ->
                Float.compare ts lo >= 0 && Float.compare ts hi <= 0
              | Some _, Some _, None ->
                incr unparseable_timestamps;
                false
              | None, _, _ | _, None, _ -> false)
           | Range_revs _ ->
             (match from_rev_opt, to_rev_opt with
              | Some lo, Some hi -> c.seq >= lo && c.seq <= hi
              | None, _ | _, None -> false))
        report.committed_changes
    in
    let resolve_change_fields (c : Wlog.change_entry) =
      let cid_opt = claim_id_of_change_entry c in
      let lookup_tbl tbl =
        first_some_opt
          [ Option.bind cid_opt (Hashtbl.find_opt tbl)
          ; Hashtbl.find_opt tbl c.fact_id
          ; Hashtbl.find_opt tbl (strip_entity_prefix c.fact_id)
          ]
      in
      let from_fact_store () =
        match Json_util.assoc_member_opt "fact" c.payload with
        | Some fact_json ->
          (match Ledger.fact_ref_of_json fact_json with
           | Ok (Ledger.Ordinary { keeper_id; claim_sha256 }) ->
             let tbl = fact_lookup_for_keeper ~cache:fact_cache ~keepers_dir keeper_id in
             Option.map (fun (f : Types.fact) -> f.claim) (Hashtbl.find_opt tbl claim_sha256)
           | Ok (Ledger.Source_bound _) | Error _ -> None)
        | None -> None
      in
      let claim_text_opt =
        match
          first_some_opt
            [ assoc_nonblank_string_opt "claim_text" c.payload
            ; assoc_nonblank_string_opt "claim" c.payload
            ; assoc_nonblank_string_opt "description" c.payload
            ; Option.bind (Json_util.assoc_member_opt "after" c.payload) extract_text_from_json
            ; lookup_tbl claim_text_tbl
            ]
        with
        | Some _ as found -> found
        | None -> from_fact_store ()
      in
      let before_text_opt =
        first_some_opt
          [ Option.bind (Json_util.assoc_member_opt "before" c.payload) extract_text_from_json
          ; Hashtbl.find_opt prior_text_tbl c.seq
          ]
      in
      let author_keeper_opt =
        first_some_opt
          [ extract_author_keeper_from_payload c.payload
          ; lookup_tbl claim_author_tbl
          ]
      in
      let ts_opt = parse_rfc3339_unix c.recorded_at in
      let kind_lc =
        Option.map (fun s -> String.lowercase_ascii (String.trim s))
          (Json_util.assoc_string_opt "kind" c.payload)
      in
      let display_summary =
        match claim_text_opt with
        | Some text when not (String_util.contains_substring c.summary text) ->
          (match kind_lc with
           | Some "claim_retracted" -> "Retracted: " ^ text
           | Some "claim_shrank" -> "Support shrank: " ^ text
           | Some "claim_joined" -> "Joined: " ^ text
           | Some "conflict_dissolved" -> "Conflict dissolved: " ^ text
           | Some "conflict_joined" -> "Conflict joined: " ^ text
           | Some "claim_created" | Some "conflict_created" -> text
           | Some _ | None ->
             if String.starts_with ~prefix:"Claim " c.summary
                || String.starts_with ~prefix:"Conflict " c.summary
                || String.starts_with ~prefix:"Joined " c.summary
             then text
             else c.summary)
        | Some _ | None -> c.summary
      in
      ( cid_opt
      , claim_text_opt
      , before_text_opt
      , author_keeper_opt
      , ts_opt
      , kind_lc
      , display_summary )
    in
    let added = ref [] in
    let updated = ref [] in
    let retracted = ref [] in
    let revisions = ref [] in
    List.iter
      (fun (c : Wlog.change_entry) ->
         let ( cid_opt
             , claim_text_opt
             , before_text_opt
             , author_keeper_opt
             , ts_opt
             , kind_lc
             , display_summary )
           =
           resolve_change_fields c
         in
         let op_kind =
           match Json_util.assoc_string_opt "op" c.payload with
           | Some s -> String.lowercase_ascii (String.trim s)
           | None ->
             (match Json_util.assoc_string_opt "action" c.payload with
              | Some s -> String.lowercase_ascii (String.trim s)
              | None ->
                (match kind_lc with
                 | Some ("claim_retracted" | "conflict_dissolved") -> "retracted"
                 | Some "claim_shrank" -> "updated"
                 | Some ("claim_created" | "claim_joined" | "conflict_created" | "conflict_joined")
                 | Some _ | None -> "added"))
         in
         let enrichment_fields =
           [ "claim_id", Json_util.string_opt_to_json cid_opt
           ; "claim_text", Json_util.string_opt_to_json claim_text_opt
           ; "before_text", Json_util.string_opt_to_json before_text_opt
           ; "author_keeper", Json_util.string_opt_to_json author_keeper_opt
           ; "ts", Json_util.float_opt_to_json ts_opt
           ]
         in
         let entry_json =
           `Assoc
             ([ "seq", `Int c.seq
              ; "batch_id", `String c.batch_id
              ; "fact_id", `String c.fact_id
              ; "summary", `String display_summary
              ; "recorded_at", `String c.recorded_at
              ; "payload", c.payload
              ]
              @ enrichment_fields)
         in
         revisions
         := `Assoc
              [ "rev", `Int c.seq
              ; "batch_id", `String c.batch_id
              ; "fact_id", `String c.fact_id
              ; "recorded_at", `String c.recorded_at
              ; "op", `String op_kind
              ]
            :: !revisions;
         if String.equal op_kind "retracted" || String.equal op_kind "removed"
         then retracted := entry_json :: !retracted
         else if
           String.equal op_kind "updated"
           || Option.is_some (Json_util.assoc_member_opt "before" c.payload)
         then (
           let before =
             Option.value ~default:`Null (Json_util.assoc_member_opt "before" c.payload)
           in
           let after =
             Option.value ~default:c.payload (Json_util.assoc_member_opt "after" c.payload)
           in
           updated
           := `Assoc
                ([ "seq", `Int c.seq
                 ; "fact_id", `String c.fact_id
                 ; "summary", `String display_summary
                 ; "recorded_at", `String c.recorded_at
                 ; "before", before
                 ; "after", after
                 ]
                 @ enrichment_fields)
              :: !updated)
         else added := entry_json :: !added)
      selected;
    (* Fleet-wide retrieval heat rollup across Keeper memory-events sidecars *)
    let keeper_ids = Cur.list_keeper_ids_for_keepers_dir ~keepers_dir in
    let hot = ref 0 in
    let warm = ref 0 in
    let cold = ref 0 in
    let never = ref 0 in
    let total_events = ref 0 in
    let unreadable_events = ref 0 in
    List.iter
      (fun kid ->
         let lookup, ev_c, unr_c = build_event_heat_table ~now ~keepers_dir ~keeper_id:kid () in
         total_events := !total_events + ev_c;
         unreadable_events := !unreadable_events + unr_c;
         match Cur.read_for_keepers_dir ~keepers_dir ~keeper_id:kid with
         | Ok (Some snap) ->
           List.iter
             (fun fact ->
                match (lookup (Types.memory_id fact)).heat with
                | Heat_hot -> incr hot
                | Heat_warm -> incr warm
                | Heat_cold -> incr cold
                | Heat_never -> incr never)
             snap.facts
         | Ok None | Error _ -> ())
      keeper_ids;
    let total_claims_now =
      match ledger_opt with
      | Some ledger -> List.length (Ledger.claims ledger)
      | None -> 0
    in
    let data =
      `Assoc
        [ "scope", `Assoc [ "kind", `String "world" ]
        ; ( "range"
          , `Assoc
              [ "window", Json_util.string_opt_to_json window_label
              ; "from_rev", Json_util.int_opt_to_json from_rev_opt
              ; ( "to_rev"
                , Json_util.int_opt_to_json
                    (match to_rev_opt with
                     | Some _ as t -> t
                     | None -> Some report.last_committed_seq) )
              ; "from_unix", Json_util.float_opt_to_json from_unix_opt
              ; "to_unix", Json_util.float_opt_to_json to_unix_opt
              ] )
        ; ( "counts"
          , `Assoc
              [ "total_claims_now", `Int total_claims_now
              ; "added", `Int (List.length !added)
              ; "updated", `Int (List.length !updated)
              ; "retracted", `Int (List.length !retracted)
              ; "incomplete_batches", `Int (List.length report.incomplete_batches)
              ; "aborted_batches", `Int (List.length report.aborted_batches)
              ] )
        ; ( "retrieval_heat"
          , `Assoc
              [ "hot", `Int !hot
              ; "warm", `Int !warm
              ; "cold", `Int !cold
              ; "never_retrieved", `Int !never
              ; "total_events", `Int !total_events
              ; "unreadable_event_lines", `Int !unreadable_events
              ] )
        ; "revisions", `List (List.rev !revisions)
        ; "added", `List (List.rev !added)
        ; "updated", `List (List.rev !updated)
        ; "retracted", `List (List.rev !retracted)
        ; "unparseable_timestamps", `Int !unparseable_timestamps
        ]
    in
    Ok (Env.ok ~now data)
;;

let diff_json ?(now = Time_compat.now ()) ~config ~scope ~range () =
  match scope with
  | Scope_world -> world_diff_json ~now ~config ~range
  | Scope_keeper keeper_id -> keeper_diff_json ~now ~config ~keeper_id ~range
;;

let respond_result ~req reqd = function
  | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd
  | Error (status, json) ->
    Http.Response.json_value ~status ~compress:true ~request:req json reqd
;;

let add_routes router =
  router
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/memory/world"
       (fun state req reqd ->
          let config = Mcp_server.workspace_config state in
          let result =
            Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              world_json ~config ())
          in
          respond_result ~req reqd result)
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/memory/diff"
       (fun state req reqd ->
          let config = Mcp_server.workspace_config state in
          let parsed =
            parse_diff_query
              ~scope:(Server_utils.query_param req "scope")
              ~keeper:(Server_utils.query_param req "keeper")
              ~window:(Server_utils.query_param req "window")
              ~from_rev:(Server_utils.query_param req "from_rev")
              ~to_rev:(Server_utils.query_param req "to_rev")
          in
          let result =
            match parsed with
            | Error (field, msg) -> error_result ~field Env.Invalid_param msg
            | Ok (scope, range) ->
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                diff_json ~config ~scope ~range ())
          in
          respond_result ~req reqd result)
;;
