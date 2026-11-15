include Dashboard_utils

type attention_context = Dashboard_briefing_assembly.attention_context = {
  severity : string;
  related_agent_names : string list;
  json : Yojson.Safe.t;
}

let top_item items =
  match items with
  | item :: _ -> item
  | [] -> `Null

let rec evidence_preview_strings json =
  match json with
  | `String value ->
      let compact = compact_text value in
      if compact = "" then [] else [ compact ]
  | `List items ->
      items |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | `Assoc fields ->
      fields |> List.map snd |> List.concat_map evidence_preview_strings |> dedup_strings |> take 4
  | _ -> []

(* Workspace-level attention stays internal to the operator projection. *)
let is_internal_attention incident =
  Operator_digest_types.is_workspace_target_type
    (string_field "target_type" incident)

let build_attention_queue incidents =
  let public_incidents =
    incidents
    |> List.filter (fun incident -> not (is_internal_attention incident))
  in
  public_incidents
  |> List.filter_map (fun incident ->
         let kind = string_field "kind" incident in
         let severity = string_field ~default:"warn" "severity" incident in
         let summary = string_field "summary" incident in
         if kind = "" || summary = "" then None
         else
           let target_type = string_field "target_type" incident in
           let target_id = String_util.trim_nonempty (string_field "target_id" incident) in
           let related_agent_names =
             dedup_strings
               (match String_util.trim_nonempty (string_field "actor" incident) with
               | Some actor -> [ actor ]
               | None -> [])
           in
           let id =
             Printf.sprintf "%s:%s:%s" kind target_type
               (match target_id with Some value -> value | None -> "none")
           in
           Some
             {
               severity;
               related_agent_names;
               json =
                 `Assoc
                   [
                     ("id", `String id);
                     ("kind", `String kind);
                     ("severity", `String severity);
                     ("summary", `String summary);
                     ("target_type", `String target_type);
                     ("target_id", Json_util.string_opt_to_json target_id);
                     ("related_agent_names", `List (List.map (fun value -> `String value) related_agent_names));
                     ("evidence", member_assoc "evidence" incident);
                     ("evidence_preview", `List (List.map (fun value -> `String value) (evidence_preview_strings (member_assoc "evidence" incident))));
                   ];
             })
  (* Stable, so incidents of equal severity keep the operator digest's own
     order. The previous tie-break ranked "has a matching action" first, and
     that flag was a guess (see {!Dashboard_briefing_assembly}). *)
  |> List.stable_sort (fun left right ->
         Int.compare
           (Operator_digest_types.severity_rank_of_string right.severity)
           (Operator_digest_types.severity_rank_of_string left.severity))


(* The operator digest fields the briefing reads. *)
type digest = {
  health : string;
  attention_items : Yojson.Safe.t list;
  recommended_actions : Yojson.Safe.t list;
}

let digest_of_json json =
  let list_of name =
    match member_assoc name json with
    | `List items -> Ok items
    | other ->
        Error
          (Printf.sprintf "operator digest %s is not a list: %s" name
             (Yojson.Safe.to_string other))
  in
  match member_assoc "health" json, list_of "attention_items", list_of "recommended_actions" with
  | `String health, Ok attention_items, Ok recommended_actions ->
      Ok { health; attention_items; recommended_actions }
  | _, Error detail, _ | _, Ok _, Error detail -> Error detail
  | other, Ok _, Ok _ ->
      Error
        (Printf.sprintf "operator digest health is not a word: %s"
           (Yojson.Safe.to_string other))

(* [Dashboard_cache] holds JSON, so a [Reuse] read hands it this module's own
   encoding of the read outcome and decodes what comes back. The decoder
   accepts exactly what the encoder writes: any other value is [None], never a
   digest with empty lists. *)
let cached_json_of_outcome = function
  | Ok { health; attention_items; recommended_actions } ->
      `Assoc
        [
          ( "read",
            `Assoc
              [
                ("health", `String health);
                ("attention_items", `List attention_items);
                ("recommended_actions", `List recommended_actions);
              ] );
        ]
  | Error detail -> `Assoc [ ("unreadable", `String detail) ]

let outcome_of_cached_json = function
  | `Assoc
      [
        ( "read",
          `Assoc
            [
              ("health", `String health);
              ("attention_items", `List attention_items);
              ("recommended_actions", `List recommended_actions);
            ] );
      ] ->
      Some (Ok { health; attention_items; recommended_actions })
  | `Assoc [ ("unreadable", `String detail) ] -> Some (Error detail)
  | _ -> None

(* The briefing's lists built from a read digest. *)
type digest_view = {
  digest : digest;
  incidents : Yojson.Safe.t list;  (* attention items, most severe first *)
  attention_queue : attention_context list;
  internal_signals : Yojson.Safe.t list;
}

let view_of_digest digest =
  let incidents =
    digest.attention_items
    |> List.sort (fun left right ->
           Int.compare
             (Operator_digest_types.severity_rank_of_string
                (string_field ~default:"ok" "severity" right))
             (Operator_digest_types.severity_rank_of_string
                (string_field ~default:"ok" "severity" left)))
  in
  {
    digest;
    incidents;
    attention_queue = build_attention_queue incidents;
    internal_signals =
      Dashboard_briefing_assembly.build_internal_signals incidents
        digest.recommended_actions;
  }

(* What one read of the operator digest produced. A digest that was read and
   holds no attention item is [Read] with empty lists; the other two cases say
   nothing about what needs attention. *)
type digest_read =
  | Read of digest_view
  | Timed_out
  | Unreadable of string

let read_of_outcome = function
  | Ok digest -> Read (view_of_digest digest)
  | Error detail -> Unreadable detail

let digest_read_field = "digest_read"
let digest_read_error_field = "digest_read_error"

let digest_read_to_wire = function
  | Read _ -> "read"
  | Timed_out -> "timed_out"
  | Unreadable _ -> "unreadable"

let digest_completeness = function
  | Read _ -> Dashboard_projection_read.Complete
  | Timed_out -> Dashboard_projection_read.Partial "operator digest: read timed out"
  | Unreadable detail -> Dashboard_projection_read.Partial ("operator digest: " ^ detail)

type briefing_projection = {
  generated_at : string;
  snapshot_json : Yojson.Safe.t;
  namespace_json : Yojson.Safe.t;
  digest_read : digest_read;
  agent_briefs : Yojson.Safe.t list;
  keeper_briefs : Yojson.Safe.t list;
  keepers_unread : Keeper_snapshot_unread.t list;
  keepers_listing : Keeper_snapshot_unread.listing;
  next_deadline_unix : float option;
  completeness : Dashboard_projection_read.completeness;
}

let build_projection ~read_policy ?actor ~config ~sw ~clock
    ~proc_mgr () =
  let actor_name = Dashboard_projection_cache.normalize_actor_name actor in
  let ctx : _ Tool_operator.context =
    {
      config;
      agent_name = actor_name;
      sw;
      clock;
      proc_mgr;
      net = None;
      (* Briefing projections call only snapshot/digest reads; no Keeper lane
         action is reachable through this context. *)
      delegated_dispatch = None;
      mcp_session_id = None;
    }
  in
  let snapshot_compute () =
    let read actor_name = Dashboard_projection_cache.operator_snapshot_json
            ~read_policy ~actor:actor_name
            ~view:"summary"
            ~include_messages:false
            ~include_keepers:true
            ~include_summary_fields:false
            ~lightweight_summary:true ctx in
    match read_policy with
    | Dashboard_projection_read.Reuse ->
        Dashboard_projection_cache.Cached_json (Dashboard_projection_cache.get_or_compute_snapshot_json
          ~config ~actor:(Some actor_name) (fun actor_name ->
            Pool_work.cpu ~name:__FUNCTION__ (fun () -> read actor_name)))
    | Current ->
        let observation = Dashboard_projection_cache.operator_snapshot_observation
            ~actor:actor_name ~view:"summary" ~include_messages:false ~include_keepers:true
            ~include_summary_fields:false ~lightweight_summary:true ctx in
        Observed {observation with json =
          Dashboard_projection_cache.with_current_keeper_observations ~config observation.json}
  in
  (* The digest read, its next policy transition, and the completeness of the
     read. Only a [Current] read carries a source observation of its own. *)
  let digest_compute () =
    match read_policy with
    | Dashboard_projection_read.Current ->
        (match Dashboard_projection_cache.operator_digest_observation ~actor:actor_name ctx with
         | Ok observation ->
             let read = read_of_outcome (digest_of_json observation.json) in
             ( read,
               observation.next_deadline_unix,
               Dashboard_projection_read.combine_completeness observation.completeness
                 (digest_completeness read) )
         | Error detail ->
             let read = Unreadable detail in
             (read, None, digest_completeness read))
    | Reuse ->
        let cached =
          Dashboard_projection_cache.get_or_compute_digest_json
            ~config ~actor:(Some actor_name) (fun actor_name ->
              Pool_work.cpu ~name:__FUNCTION__ (fun () ->
                cached_json_of_outcome
                  (Result.bind
                     (Dashboard_projection_cache.operator_digest_json ~actor:actor_name ctx)
                     digest_of_json)))
        in
        let read =
          if Dashboard_cache.is_timeout_envelope cached then Timed_out
          else
            match outcome_of_cached_json cached with
            | Some outcome -> read_of_outcome outcome
            | None ->
                Unreadable
                  (Printf.sprintf
                     "digest cache entry for %s is neither a digest nor a timeout envelope"
                     actor_name)
        in
        (read, None, digest_completeness read)
  in
  let snapshot_read, (digest_read, digest_next_deadline_unix, digest_read_completeness) =
    Eio.Fiber.pair snapshot_compute digest_compute
  in
  let snapshot_json, snapshot_observation = match snapshot_read with
    | Dashboard_projection_cache.Cached_json json -> json, None
    | Observed observation -> observation.json, Some observation in
  let namespace_json =
    match member_assoc "workspace" snapshot_json with
    | `Assoc _ as value -> value
    | _ -> member_assoc "workspace" snapshot_json
  in
  (* Agent briefs count the attention entries that name them. An unread
     digest leaves them nothing to count; the briefing's [digest_read] says
     the counts were not read. *)
  let attention_queue =
    match digest_read with
    | Read view -> view.attention_queue
    | Timed_out | Unreadable _ -> []
  in
  let keeper_items =
    match member_assoc "keepers" snapshot_json |> member_assoc "items" with
    | `List items -> items
    | _ -> []
  in
  let agent_observation =
    Dashboard_briefing_assembly.build_agent_briefs_observation ~now_ts:(Time_compat.now ())
      config attention_queue keeper_items
  in
  let keeper_briefs = Dashboard_briefing_assembly.build_keeper_briefs config keeper_items in
  (* Keepers the snapshot listed but could not build a row for. They are not
     in [keeper_items], so without this list they left the briefing without a
     trace (#38090). The snapshot always writes the list beside its rows; one
     missing is a producer defect and fails the render rather than reading as
     "none". *)
  let keepers_unread =
    match Keeper_snapshot_unread.of_snapshot snapshot_json with
    | Ok unread -> unread
    | Error detail -> invalid_arg ("dashboard briefing: " ^ detail)
  in
  (* Empty [keeper_briefs] and [keepers_unread] are also what a Keeper
     directory that did not list leaves behind, so whether the list read
     travels beside them (#38120). *)
  let keepers_listing =
    match Keeper_snapshot_unread.listing_of_snapshot snapshot_json with
    | Ok listing -> listing
    | Error detail -> invalid_arg ("dashboard briefing: " ^ detail)
  in
  {
    generated_at = Masc_domain.now_iso ();
    snapshot_json;
    namespace_json;
    digest_read;
    agent_briefs = agent_observation.json;
    keeper_briefs;
    keepers_unread;
    keepers_listing;
    completeness = Dashboard_projection_read.combine_completeness digest_read_completeness
      (match snapshot_observation with
       | Some observation -> observation.completeness
       | None -> Dashboard_projection_read.keeper_completeness ~listing:keepers_listing ~unread:keepers_unread);
    next_deadline_unix = (let digest_and_agents = match digest_next_deadline_unix, agent_observation.next_deadline_unix with
      | None, deadline | deadline, None -> deadline
      | Some left, Some right -> Some (Float.min left right) in
      match digest_and_agents, Option.bind snapshot_observation (fun observation -> observation.next_deadline_unix) with
      | None, deadline | deadline, None -> deadline
      | Some left, Some right -> Some (Float.min left right));
}

let render_projection projection =
  (* A digest that was not read says nothing about its lists, so they are
     null, not the empty lists of a digest with no attention item. *)
  let digest_list select =
    match projection.digest_read with
    | Read view -> `List (select view)
    | Timed_out | Unreadable _ -> `Null
  in
  let digest_top select =
    match projection.digest_read with
    | Read view -> top_item (select view)
    | Timed_out | Unreadable _ -> `Null
  in
  (* An unread digest names no health. The word is the health vocabulary's
     own [unknown], which every reader of the health line already names. *)
  let health =
    `String
      (match projection.digest_read with
       | Read view -> view.digest.health
       | Timed_out | Unreadable _ -> string_of_health_level Health_status.Unknown)
  in
  let digest_read_error =
    match projection.digest_read with
    | Read _ | Timed_out -> `Null
    | Unreadable detail -> `String detail
  in
  let summary_json =
    `Assoc
      [
        ("workspace_health", health);
        ("project", Json_util.string_opt_to_json (Some (string_field "project" projection.namespace_json)));
      ]
  in
  let command_focus_json =
    `Assoc
      [
        ("health", health);
        ("active_operations", `Int 0);
        ("pending_approvals", `Int 0);
        ("top_attention", digest_top (fun view -> view.incidents));
        ("top_action", digest_top (fun view -> view.digest.recommended_actions));
      ]
  in
  let operator_targets_json =
    `Assoc
      [
        ("keepers", `List projection.keeper_briefs);
        ("available_actions", member_assoc "available_actions" projection.snapshot_json);
      ]
  in
  `Assoc
    [
      ("generated_at", `String projection.generated_at);
      ("summary", summary_json);
      ("candle", member_assoc "candle" (member_assoc "keepers" projection.snapshot_json));
      (digest_read_field, `String (digest_read_to_wire projection.digest_read));
      (digest_read_error_field, digest_read_error);
      ("incidents", digest_list (fun view -> view.incidents));
      ("recommended_actions", digest_list (fun view -> view.digest.recommended_actions));
      ("command_focus", command_focus_json);
      ("operator_targets", operator_targets_json);
      ( "attention_queue",
        digest_list (fun view ->
            List.map (fun (item : attention_context) -> item.json) view.attention_queue) );
      ("agent_briefs", `List projection.agent_briefs);
      ("keeper_briefs", `List projection.keeper_briefs);
      ( "keepers_unread",
        `List (List.map Keeper_snapshot_unread.to_json projection.keepers_unread) );
      ("keepers_listing", Keeper_snapshot_unread.listing_to_json projection.keepers_listing);
      ("internal_signals", digest_list (fun view -> view.internal_signals));
    ]

type observation = Dashboard_projection_read.observation = {
  json : Yojson.Safe.t;
  next_deadline_unix : float option;
  completeness : Dashboard_projection_read.completeness;
}

let observe_current ?actor ~config ~sw ~clock ~proc_mgr () =
  let projection = build_projection ~read_policy:Dashboard_projection_read.Current
      ?actor ~config ~sw ~clock ~proc_mgr () in
  {json = render_projection projection; next_deadline_unix = projection.next_deadline_unix;
   completeness = projection.completeness}

let json ?actor ~config ~sw ~clock ~proc_mgr () =
  build_projection ~read_policy:Dashboard_projection_read.Reuse
    ?actor ~config ~sw ~clock ~proc_mgr ()
  |> render_projection
