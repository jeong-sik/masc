
(** Parse query param from request target *)
let query_param request key =
  let uri = Uri.of_string request.Httpun.Request.target in
  Uri.get_query_param uri key

let int_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s -> (Option.value ~default:default (int_of_string_opt s))

let bool_query_param request key ~default =
  match query_param request key with
  | None -> default
  | Some s ->
      let v = String.lowercase_ascii (String.trim s) in
      if v = "1" || v = "true" || v = "yes" || v = "y" then true
      else if v = "0" || v = "false" || v = "no" || v = "n" then false
      else default

let clamp ~min_v ~max_v v = max min_v (min max_v v)

(** Bound an in-memory cache keyed partly by client-supplied input. When
    [cache] holds at least [max_entries] entries, evict the single entry with
    the smallest [age_of] (the least-recently-refreshed), so a caller that
    inserts on every miss keeps the table bounded over process lifetime. Call
    immediately before adding a new key. No-op below the cap. *)
let evict_oldest_if_full ~max_entries ~age_of cache =
  if Hashtbl.length cache >= max_entries then
    match
      Hashtbl.fold
        (fun k v acc ->
          let age = age_of v in
          match acc with
          | Some (_, oldest) when oldest <= age -> acc
          | Some _ | None -> Some (k, age))
        cache None
    with
    | Some (k, _) -> Hashtbl.remove cache k
    | None -> ()

let take = List.take
let drop = List.drop

(** Issue #8449 PR C: HTTP query-param sort_by parser. Delegates to
    [Board_dispatch.sort_order_of_string_opt] instead of duplicating
    the inline match. HTTP semantics keep the "default to Hot" fallback
    for missing or invalid query params — graceful UI degradation, not
    silent data corruption. *)
let board_sort_order_of_request request =
  match query_param request "sort_by" with
  | None -> Board_dispatch.Hot
  | Some sort ->
    (match Board_dispatch.sort_order_of_string_opt sort with
     | Some s -> s
     | None -> Board_dispatch.Hot)

(** Issue #8449 PR C: thin alias over the Variant SSOT helper. *)
let board_sort_label = Board_dispatch.sort_order_to_string

let filter_board_posts ~exclude_system ~exclude_automation posts =
  posts
  |> List.filter
       (Board.post_matches_filters ~exclude_system ~exclude_automation)

let board_actor_key ~kind id =
  kind ^ ":" ^ String.lowercase_ascii (String.trim id)

let board_actor_keeper_identity raw =
  let raw = String.trim raw in
  if raw = "" then None
  else
    match Keeper_registry_lookup.find_by_agent_name raw with
    | Some entry ->
        Some (entry.name, Some entry.meta.agent_name, "keeper_registry_agent_name")
    | None -> (
        match Keeper_registry_lookup.find_by_name raw with
        | Some entry ->
            Some (entry.name, Some entry.meta.agent_name, "keeper_registry_name")
        | None -> (
            match Keeper_identity.canonical_keeper_name_from_agent_name raw with
            | Some name -> Some (name, Some raw, "keeper_alias_contract")
            | None -> None))

let board_actor_identity_json raw : Yojson.Safe.t =
  let raw = String.trim raw in
  match board_actor_keeper_identity raw with
  | Some (keeper_name, runtime_agent_name, source) ->
      let runtime_fields =
        match runtime_agent_name with
        | Some runtime when String.trim runtime <> "" && not (String.equal runtime keeper_name) ->
            [ ("runtime_agent_name", `String runtime) ]
        | _ -> []
      in
      `Assoc
        ([
           ("kind", `String "keeper");
           ("id", `String keeper_name);
           ("key", `String (board_actor_key ~kind:"keeper" keeper_name));
           ("display_name", `String keeper_name);
           ("raw", `String raw);
           ("source", `String source);
         ]
        @ runtime_fields)
  | None ->
      `Assoc
        [
          ("kind", `String "agent");
          ("id", `String raw);
          ("key", `String (board_actor_key ~kind:"agent" raw));
          ("display_name", `String raw);
          ("raw", `String raw);
          ("source", `String "raw_agent");
        ]

let board_actor_entity raw =
  match board_actor_keeper_identity raw with
  | Some (keeper_name, _, _) -> Activity_graph.entity ~kind:"keeper" keeper_name
  | None -> Activity_graph.entity ~kind:"agent" (String.trim raw)

let board_actor_author_for_write raw =
  match board_actor_keeper_identity raw with
  | Some (keeper_name, _, _) -> keeper_name
  | None -> String.trim raw

let board_voter_query request =
  query_param request "voter"
  |> Option.map String.trim
  |> Fun.flip Option.bind (fun raw ->
       if raw = "" then None else Some (board_actor_author_for_write raw))

let board_current_vote_for_post ~voter ~post_id =
  match voter with
  | None -> None
  | Some voter -> (
      match Board_dispatch.current_vote_for_post ~voter ~post_id with
      | Ok vote -> Some vote
      | Error _ -> Some None)

let board_current_vote_for_comment ~voter ~comment_id =
  match voter with
  | None -> None
  | Some voter -> (
      match Board_dispatch.current_vote_for_comment ~voter ~comment_id with
      | Ok vote -> Some vote
      | Error _ -> Some None)

let max_filtered_board_window = 5200

let board_fetch_limit ~exclude_system ~exclude_automation ~limit ~offset =
  let base = limit + offset in
  if exclude_system || exclude_automation then max base max_filtered_board_window
  else base

let board_vote_state_fields = function
  | None -> []
  | Some None -> [ ("current_vote", `Null); ("has_voted", `Bool false) ]
  | Some (Some direction) ->
      [
        ("current_vote", `String (Board.vote_direction_to_string direction));
        ("has_voted", `Bool true);
      ]

let board_vote_blind_active ~blind_votes = function
  | Some (Some _) -> false
  | _ -> blind_votes

let board_vote_blind_fields ~blind_active =
  if blind_active then
    [
      ("vote_blind", `Bool true);
      ("vote_blind_reason", `String "vote_before_score");
      ("vote_balance", `Null);
      ("score", `Null);
      ("votes_up", `Null);
      ("votes_down", `Null);
    ]
  else [ ("vote_blind", `Bool false) ]

let board_reactions_for_post ~voter ~post_id =
  match
    Board_dispatch.list_reactions ~target_type:Board.Reaction_post
      ~target_id:post_id ?user_id:voter ()
  with
  | Ok summaries -> summaries
  | Error err ->
      Log.Server.warn "board reactions: post %s summary failed: %s" post_id
        (Board_types.show_board_error err);
      []

let board_reactions_for_comment ~voter ~comment_id =
  match
    Board_dispatch.list_reactions ~target_type:Board.Reaction_comment
      ~target_id:comment_id ?user_id:voter ()
  with
  | Ok summaries -> summaries
  | Error err ->
      Log.Server.warn "board reactions: comment %s summary failed: %s"
        comment_id (Board_types.show_board_error err);
      []

let board_reactions_batch ~targets ~voter =
  match targets with
  | [] -> []
  | _ -> Board_dispatch.list_reactions_batch ~targets ?user_id:voter ()

let board_reactions_lookup rows =
  let table = Hashtbl.create (List.length rows) in
  List.iter
    (fun (target, summaries) -> Hashtbl.replace table target summaries)
    rows;
  fun target -> Hashtbl.find_opt table target |> Option.value ~default:[]

let board_reaction_fields = function
  | None -> []
  | Some summaries ->
      [ ("reactions", `List (List.map Board.reaction_summary_to_yojson summaries)) ]

let board_moderation_fields ~include_moderation ~target_kind ~target_id =
  if not include_moderation then []
  else
    let summary = Board_moderation.target_summary ~target_kind ~target_id in
    [
      ("report_count", `Int summary.Board_moderation.report_count);
      ("moderation_status", `String summary.Board_moderation.moderation_status);
    ]

let board_contributor_quality_json
    (rep : Reputation.agent_reputation) : Yojson.Safe.t =
  `Assoc
    [
      ("source", `String "agent_reputation");
      ("completion_rate", `Float rep.completion_rate);
      ("response_rate", `Float rep.response_rate);
      ("board_posts", `Int rep.board_posts);
      ("board_comments", `Int rep.board_comments);
      ("accountability_score", `Float rep.accountability_score);
      ("autonomy_level", `String rep.autonomy_level);
      ("thompson_confidence", `Float rep.thompson_confidence);
      ("evidence_state", `String rep.evidence_state);
    ]

let board_contributor_quality_lookup ?config () =
  match config with
  | None -> fun _author -> None
  | Some config ->
      let cache = Hashtbl.create 16 in
      fun author ->
        match Hashtbl.find_opt cache author with
        | Some value -> value
        | None ->
            let value =
              try
                let rep =
                  Reputation.compute_reputation config
                    ~agent_name:author
                in
                Some (board_contributor_quality_json rep)
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                  Log.Server.warn
                    "board contributor quality failed for %s: %s" author
                    (Printexc.to_string exn);
                  None
            in
            Hashtbl.replace cache author value;
            value

let board_contributor_quality_fields = function
  | None -> []
  | Some quality -> [ ("contributor_quality", quality) ]

let board_claim_evidence_lookup () =
  let lookup = Masc_board_handlers.Board_claim_evidence.projection_lookup () in
  fun post_id ->
    Option.map Masc_board_handlers.Board_claim_evidence.projection_to_yojson (lookup post_id)
;;

let board_claim_evidence_fields = function
  | None -> []
  | Some projection -> [ ("claim_evidence", projection) ]

let board_comment_dashboard_json ?(include_moderation = false)
    ?(blind_votes = false) ?current_vote ?reactions (c : Board.comment) :
    Yojson.Safe.t =
  let author = Board.Agent_id.to_string c.author in
  let comment_id = Board.Comment_id.to_string c.id in
  match Board.comment_to_yojson c with
  | `Assoc fields ->
      let blind_active = board_vote_blind_active ~blind_votes current_vote in
      let fields =
        if blind_active then
          fields
          |> List.remove_assoc "votes"
          |> List.remove_assoc "vote_balance"
          |> List.remove_assoc "score"
          |> List.remove_assoc "votes_up"
          |> List.remove_assoc "votes_down"
        else fields
      in
      `Assoc
        (fields
         @ [ ("author_identity", board_actor_identity_json author) ]
         @ board_moderation_fields ~include_moderation
             ~target_kind:Board_moderation.Target_comment
             ~target_id:comment_id
         @ (if blind_active then [ ("votes", `Null) ] else [])
         @ board_vote_blind_fields ~blind_active
         @ board_vote_state_fields current_vote
         @ board_reaction_fields reactions)
  | other -> other

let board_post_dashboard_json ?(include_moderation = false)
    ?(blind_votes = false) ?contributor_quality ?claim_evidence ?current_vote
    ?reactions ~author_karma (p : Board.post) : Yojson.Safe.t =
  let author = Board.Agent_id.to_string p.author in
  let post_id = Board.Post_id.to_string p.id in
  let base_fields =
    match Board_dispatch.post_to_yojson_with_karma p ~author_karma with
    | `Assoc fields -> fields
    | _ -> []
  in
  let fields =
    base_fields
    |> List.remove_assoc "title"
    |> List.remove_assoc "votes"
    |> List.remove_assoc "comment_count"
    |> List.remove_assoc "created_at_iso"
    |> List.remove_assoc "updated_at_iso"
    |> List.remove_assoc "hearth_count"
  in
  let blind_active = board_vote_blind_active ~blind_votes current_vote in
  let fields =
    if blind_active then
      fields
      |> List.remove_assoc "vote_balance"
      |> List.remove_assoc "score"
      |> List.remove_assoc "votes_up"
      |> List.remove_assoc "votes_down"
    else fields
  in
  let score = p.votes_up - p.votes_down in
  `Assoc
    ( fields
      @ [
          ("title", `String p.title);
          ("body", `String p.body);
          ("votes", if blind_active then `Null else `Int score);
          ("comment_count", `Int p.reply_count);
          ("created_at_iso", `String (Masc_domain.iso8601_of_unix_seconds p.created_at));
          ("updated_at_iso", `String (Masc_domain.iso8601_of_unix_seconds p.updated_at));
          ("hearth", Json_util.string_opt_to_json p.hearth);
          ("hearth_count", `Int (match p.hearth with Some _ -> 1 | None -> 0));
          ("author_identity", board_actor_identity_json author);
        ]
      @ board_moderation_fields ~include_moderation
          ~target_kind:Board_moderation.Target_post
          ~target_id:post_id
      @ board_contributor_quality_fields contributor_quality
      @ board_claim_evidence_fields claim_evidence
      @ board_vote_blind_fields ~blind_active
      @ board_vote_state_fields current_vote
      @ board_reaction_fields reactions )

let dashboard_compact_mode request =
  match query_param request "mode" with
  | Some s -> String.equal "compact" (String.lowercase_ascii (String.trim s))
  | None -> false

(** Extract a path parameter after a known prefix.
    Returns None if the path doesn't start with prefix or the parameter is empty.
    Prevents String.sub crash from bounds violations. *)
let extract_path_param ~prefix path =
  let plen = String.length prefix in
  let plen_total = String.length path in
  if plen_total > plen && String.sub path 0 plen = prefix then
    let param = String.trim (String.sub path plen (plen_total - plen)) in
    if String.length param > 0 then Some param else None
  else None

(** Standard query param: limit with default 50, clamped 1..200. *)
let standard_limit request =
  int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200

(** Standard query param: offset with default 0, min 0. *)
let standard_offset request =
  int_query_param request "offset" ~default:0 |> max 0
