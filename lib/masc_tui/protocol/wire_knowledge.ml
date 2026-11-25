open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let board_quarantines_path ~keeper =
  "/api/v1/keepers/" ^ percent_encode keeper ^ "/board-attention/quarantines"

let board_list_path ?(sort_by = "recent") ?hearth ?(signal_only = true) ?limit
    ?offset () =
  let params =
    [ "sort_by=" ^ percent_encode sort_by ]
    @ (match hearth with
      | None -> []
      | Some h -> [ "hearth=" ^ percent_encode h ])
    @ (if signal_only then [ "signal_only=true"; "exclude_system=true" ] else [])
    @ (match limit with
      | None -> []
      | Some n -> [ Printf.sprintf "limit=%d" (max 1 n) ])
    @
    match offset with
    | None -> []
    | Some o -> [ Printf.sprintf "offset=%d" (max 0 o) ]
  in
  "/api/v1/board?" ^ String.concat "&" params

let board_post_path ~post_id ?comment_offset ?comment_limit () =
  let params =
    [ "format=flat" ]
    @ (match comment_offset with
      | None -> []
      | Some o -> [ Printf.sprintf "comment_offset=%d" (max 0 o) ])
    @
    match comment_limit with
    | None -> []
    | Some l -> [ Printf.sprintf "comment_limit=%d" (max 1 l) ]
  in
  Printf.sprintf "/api/v1/board/%s?%s" (percent_encode post_id)
    (String.concat "&" params)

let board_hearths_path = "/api/v1/board/hearths"
let board_comment_path = "/api/v1/tools/masc_board_comment"
let board_vote_path = "/api/v1/tools/masc_board_vote"
let board_comment_vote_path = "/api/v1/tools/masc_board_comment_vote"
let board_pin_path = "/api/v1/dashboard/board/pin"
let board_delete_path = "/api/v1/dashboard/board/delete"

let wiki_index_path ?tag ?source ?sort () =
  let params =
    (match tag with None -> [] | Some t -> [ "tag=" ^ percent_encode t ])
    @ (match source with
      | None -> []
      | Some s -> [ "source=" ^ percent_encode s ])
    @ match sort with None -> [] | Some s -> [ "sort=" ^ percent_encode s ]
  in
  match params with
  | [] -> "/api/v1/wiki"
  | _ -> "/api/v1/wiki?" ^ String.concat "&" params

let wiki_page_path ~page = "/api/v1/wiki/" ^ percent_encode page

let wiki_log_path ?limit ?before_idx ?page () =
  let params =
    (match limit with
    | None -> []
    | Some n -> [ Printf.sprintf "limit=%d" (max 1 n) ])
    @ (match before_idx with
      | None -> []
      | Some i -> [ Printf.sprintf "before_idx=%d" i ])
    @ match page with None -> [] | Some p -> [ "page=" ^ percent_encode p ]
  in
  match params with
  | [] -> "/api/v1/wiki/log"
  | _ -> "/api/v1/wiki/log?" ^ String.concat "&" params

let wiki_search_path ~query ?limit () =
  let params =
    [ "q=" ^ percent_encode query ]
    @
    match limit with
    | None -> []
    | Some n -> [ Printf.sprintf "limit=%d" (max 1 n) ]
  in
  "/api/v1/wiki/search?" ^ String.concat "&" params

let wiki_lint_path = "/api/v1/wiki/lint"
let published_artifacts_path = "/api/v1/published-artifacts"

let published_artifact_detail_path ~id ?revision () =
  let base = "/api/v1/published-artifacts/" ^ percent_encode id in
  match revision with
  | Some r when r > 0 -> Printf.sprintf "%s?revision=%d" base r
  | Some _ | None -> base

let published_artifact_checks_path = "/api/v1/published-artifact-checks"
let published_artifact_shares_path = "/api/v1/published-artifact-shares"

let world_memory_path = "/api/v1/memory/world"
let workspace_memory_inventory_path = "/api/v1/dashboard/workspace-memory-inventory"

let keeper_memory_os_internals_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/memory-os-internals" (percent_encode keeper)

let keeper_memory_facts_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/memory-facts" (percent_encode keeper)

let keeper_memory_activity_path ~keeper ?(limit = 50) () =
  Printf.sprintf "/api/v1/keepers/%s/memory-journal?activity=1&limit=%d"
    (percent_encode keeper) (max 1 limit)

let keeper_memory_health_path ?keeper () =
  match keeper with
  | None -> "/api/v1/dashboard/keeper-memory-health"
  | Some k ->
      "/api/v1/dashboard/keeper-memory-health?keeper=" ^ percent_encode k

let memory_diff_path ~keeper ?window ?from_rev ?to_rev () =
  let params =
    (match keeper with
    | None -> [ "scope=world" ]
    | Some k -> [ "scope=keeper"; "keeper=" ^ percent_encode k ])
    @ (match window with
      | None -> []
      | Some w -> [ "window=" ^ percent_encode w ])
    @ (match from_rev with
      | None -> []
      | Some r -> [ Printf.sprintf "from_rev=%d" r ])
    @
    match to_rev with
    | None -> []
    | Some r -> [ Printf.sprintf "to_rev=%d" r ]
  in
  "/api/v1/memory/diff?" ^ String.concat "&" params

let keeper_memory_act_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/memory/act" (percent_encode keeper)

type post_kind =
  | Human_post
  | Automation_post
  | System_post

type post_visibility =
  | Vis_public
  | Vis_unlisted
  | Vis_internal
  | Vis_direct

type board_post = {
  id : string;
  title : string;
  body : string;
  author : string;
  hearth : string option;
  post_kind : post_kind option;
  visibility : post_visibility option;
  created_at_unix : float;
  updated_at_unix : float option;
  score : int;
  comment_count : int;
  author_karma : int Observed.t;
  succession_chain_root_id : string option;
  chain_depth : int option;
  is_signal : bool;
  pinned : bool;
}

type board_comment = {
  id : string;
  post_id : string;
  parent_id : string option;
  author : string;
  body : string;
  created_at_unix : float;
  score : int;
}

type board_feed = {
  posts : board_post list;
  count : int;
  sort_by : string;
  signal_only : bool;
}

let post_kind_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "direct" | "human" | "human_post" -> Some Human_post
  | "automation" | "automation_post" -> Some Automation_post
  | "system" | "system_post" -> Some System_post
  | _ -> None

let post_visibility_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "public" -> Some Vis_public
  | "unlisted" -> Some Vis_unlisted
  | "internal" -> Some Vis_internal
  | "direct" -> Some Vis_direct
  | _ -> None

let has_noise_prefix (raw : string) =
  let s = String.lowercase_ascii (String.trim raw) in
  String.starts_with ~prefix:"verify:" s
  || String.starts_with ~prefix:"[verify]" s
  || String.starts_with ~prefix:"approved task" s
  || String.starts_with ~prefix:"rejected task" s

let is_signal_board_post ~post_kind ~hearth ~title ~body =
  let is_system =
    match post_kind with
    | Some System_post -> true
    | Some (Human_post | Automation_post) | None -> false
  in
  let is_verification_hearth =
    match hearth with
    | Some h -> String.equal (String.lowercase_ascii (String.trim h)) "verification"
    | None -> false
  in
  (not is_system)
  && (not is_verification_hearth)
  && (not (has_noise_prefix title))
  && not (has_noise_prefix body)

let decode_board_post ~observed_at json =
  let* id = required_nonblank_string json "id" in
  let* title = required_string_field json "title" in
  let* body =
    if has_field json "body" then required_string_field json "body"
    else required_string_field json "content"
  in
  let* author = required_nonblank_string json "author" in
  let* hearth = optional_nonblank_string json "hearth" in
  let* post_kind =
    decode_optional_enum ~field:"post_kind" post_kind_of_string json
  in
  let* visibility =
    decode_optional_enum ~field:"visibility" post_visibility_of_string json
  in
  let* created_at_unix =
    if has_field json "created_at_unix" then
      decode_timestamp_unix json "created_at_unix"
    else decode_timestamp_unix json "created_at"
  in
  let* updated_at_unix = decode_optional_timestamp_unix json "updated_at" in
  let* score =
    if has_field json "votes" then required_int_field json "votes"
    else int_field_or json "score" ~default:0
  in
  let* comment_count = int_field_or json "comment_count" ~default:0 in
  let* author_karma = observed_int ~observed_at json "author_karma" in
  let* succession_chain_root_id =
    optional_nonblank_string json "succession_chain_root_id"
  in
  let* chain_depth = optional_int_field json "chain_depth" in
  let* is_signal =
    if has_field json "is_signal" then required_bool_field json "is_signal"
    else Ok (is_signal_board_post ~post_kind ~hearth ~title ~body)
  in
  let* pinned = decode_bool_field_or json "pinned" ~default:false in
  Ok
    {
      id;
      title;
      body;
      author;
      hearth;
      post_kind;
      visibility;
      created_at_unix;
      updated_at_unix;
      score;
      comment_count;
      author_karma;
      succession_chain_root_id;
      chain_depth;
      is_signal;
      pinned;
    }

let decode_board_comment json =
  let* id = required_nonblank_string json "id" in
  let* post_id = required_nonblank_string json "post_id" in
  let* parent_id = optional_nonblank_string json "parent_id" in
  let* author = required_nonblank_string json "author" in
  let* body =
    if has_field json "body" then required_string_field json "body"
    else required_string_field json "content"
  in
  let* created_at_unix =
    if has_field json "created_at_unix" then
      decode_timestamp_unix json "created_at_unix"
    else decode_timestamp_unix json "created_at"
  in
  (* A live thread comment carries its vote tallies (votes_up/votes_down);
     allow an explicit score field only when present in synthetic fixtures. *)
  let* score =
    if has_field json "score" then required_int_field json "score"
    else
      let* votes_up = required_nonnegative_int_field json "votes_up" in
      let* votes_down = required_nonnegative_int_field json "votes_down" in
      Ok (votes_up - votes_down)
  in
  Ok { id; post_id; parent_id; author; body; created_at_unix; score }

let decode_board_feed ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "posts" in
  let* posts = decode_list "posts" (decode_board_post ~observed_at) items in
  let* count = int_field_or body "count" ~default:(List.length posts) in
  let* sort_by =
    match optional_nonblank_string body "sort_by" with
    | Ok (Some s) -> Ok s
    | Ok None -> Ok "recent"
    | Error _ as err -> err
  in
  let* signal_only = decode_bool_field_or body "signal_only" ~default:false in
  Ok { posts; count; sort_by; signal_only }

let decode_board_thread ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* post_json =
    if has_field body "post" then required_object_field body "post"
    else Ok body
  in
  let* post = decode_board_post ~observed_at post_json in
  let* comment_items = optional_list_field body "comments" in
  let* comments = decode_list "comments" decode_board_comment comment_items in
  Ok (post, comments)

type board_post_extras = {
  audience_label : string option;
  closed_by : string option;
  closed_successor_id : string option;
  flair_label : string option;
  reaction_summary : string option;
}

type board_feed_meta = {
  has_more : bool;
  filtered_out_count : int;
  signal_scan_truncated : bool;
  post_extras : (string * board_post_extras) list;
}

type board_comment_page = {
  offset : int;
  returned : int;
  total : int;
  next_offset : int option;
}

type board_thread_meta = {
  post_id : string;
  post_extras : board_post_extras option;
  comment_page : board_comment_page option;
  comment_audiences : (string * string) list;
}

let decode_audience_label_opt json =
  match member "audience" json with
  | `Assoc _ as aud -> (
      match optional_nonblank_string aud "kind" with
      | Ok (Some "targets") -> (
          match optional_string_list aud "targets" with
          | Ok (_ :: _ as ts) ->
              Some (String.concat ", " (List.map (fun s -> "@" ^ s) ts))
          | Ok [] | Error _ -> None)
      | Ok (Some "broadcast") -> Some "@all"
      | Ok (Some "thread_participants") -> Some "@thread"
      | Ok (Some _ | None) | Error _ -> None)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

let decode_post_extras_opt json =
  let audience_label = decode_audience_label_opt json in
  let closed_by, closed_successor_id =
    match member "closed" json with
    | `Assoc _ as cl ->
        let by =
          match optional_nonblank_string cl "closed_by" with
          | Ok v -> v
          | Error _ -> None
        in
        let succ =
          match optional_nonblank_string cl "successor_id" with
          | Ok v -> v
          | Error _ -> None
        in
        (by, succ)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        (None, None)
  in
  let safe_reaction_token emoji =
    match String.trim emoji with
    | "👍" -> "+1"
    | "👎" -> "-1"
    | "❤️" | "❤" -> "<3"
    | "🔥" -> "fire"
    | "🚀" -> "ship"
    | "👀" -> "eyes"
    | "🎉" -> "tada"
    | "😄" -> ":)"
    | "🤔" -> "?"
    | s ->
        let is_ascii =
          String.length s > 0
          && String.for_all (fun c -> Char.code c >= 33 && Char.code c <= 126) s
        in
        if is_ascii then s else "rx"
  in
  let flair_label =
    match member "flair" json with
    | `Assoc _ as fl -> (
        let label =
          match optional_nonblank_string fl "label" with
          | Ok (Some l) -> Some l
          | Ok None | Error _ -> (
              match optional_nonblank_string fl "name" with
              | Ok v -> v
              | Error _ -> None)
        in
        match label with
        | Some l -> Some l
        | None -> (
            match optional_nonblank_string fl "emoji" with
            | Ok (Some e) -> Some (safe_reaction_token e)
            | Ok None | Error _ -> None))
    | `String s when not (String.equal (String.trim s) "") -> Some (String.trim s)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        None
  in
  let reaction_summary =
    match member "reactions" json with
    | `List items -> (
        let chips =
          List.filter_map
            (fun item ->
              match item with
              | `Assoc _ -> (
                  match
                    ( optional_nonblank_string item "emoji"
                    , optional_int_field item "count" )
                  with
                  | Ok (Some e), Ok (Some c) when c > 0 ->
                      Some (Printf.sprintf "%s:%d" (safe_reaction_token e) c)
                  | Ok (Some _ | None), Ok (Some _ | None)
                  | Error _, _
                  | _, Error _ ->
                      None)
              | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _
              | `List _ ->
                  None)
            items
        in
        match chips with [] -> None | _ :: _ -> Some (String.concat " " chips))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
        None
  in
  if
    Option.is_none audience_label
    && Option.is_none closed_by
    && Option.is_none closed_successor_id
    && Option.is_none flair_label
    && Option.is_none reaction_summary
  then None
  else
    Some
      {
        audience_label;
        closed_by;
        closed_successor_id;
        flair_label;
        reaction_summary;
      }

let decode_board_feed_meta json =
  let* _, body = unwrap_v2_or_raw json in
  let* has_more = decode_bool_field_or body "has_more" ~default:false in
  let* filtered_out_count = int_field_or body "filtered_out_count" ~default:0 in
  let* signal_scan_truncated =
    decode_bool_field_or body "signal_scan_truncated" ~default:false
  in
  let* items = optional_list_field body "posts" in
  let post_extras =
    List.filter_map
      (fun item ->
        match optional_nonblank_string item "id" with
        | Ok (Some id) ->
            Option.map (fun ex -> (id, ex)) (decode_post_extras_opt item)
        | Ok None | Error _ -> None)
      items
  in
  Ok { has_more; filtered_out_count; signal_scan_truncated; post_extras }

let decode_board_thread_meta json =
  let* _, body = unwrap_v2_or_raw json in
  let post_json =
    match member "post" body with
    | `Assoc _ as p -> p
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        body
  in
  let* post_id = required_nonblank_string post_json "id" in
  let post_extras = decode_post_extras_opt post_json in
  let comment_page =
    match member "comment_page" body with
    | `Assoc _ as cp -> (
        let opt_int field =
          match optional_int_field cp field with Ok v -> v | Error _ -> None
        in
        match (opt_int "offset", opt_int "returned", opt_int "total") with
        | Some offset, Some returned, Some total ->
            let next_offset = opt_int "next_offset" in
            Some { offset; returned; total; next_offset }
        | None, _, _ | _, None, _ | _, _, None -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
        None
  in
  let* comment_items = optional_list_field body "comments" in
  let comment_audiences =
    List.filter_map
      (fun c ->
        match optional_nonblank_string c "id" with
        | Ok (Some cid) ->
            Option.map (fun a -> (cid, a)) (decode_audience_label_opt c)
        | Ok None | Error _ -> None)
      comment_items
  in
  Ok { post_id; post_extras; comment_page; comment_audiences }

type wiki_source =
  | Source_direct_experience
  | Source_research
  | Source_experiment
  | Source_observation

type wiki_frontmatter = {
  title : string;
  summary : string;
  source : wiki_source;
  author : string;
  created : string;
  updated : string;
  revision : int;
  tags : string list;
}

type wiki_unsupported_link =
  | Unsupported_anchor
  | Unsupported_scheme
  | Unsupported_path
  | Unsupported_not_markdown
  | Unsupported_wikilink

type wiki_link_target =
  | Link_page of { slug : string; exists : bool }
  | Link_own_file of string
  | Link_external of string
  | Link_invalid_name of string
  | Link_unsupported of wiki_unsupported_link

type wiki_outgoing_link = {
  text : string;
  target : wiki_link_target;
  raw : string;
  line : int;
}

type wiki_lint_kind =
  | Broken_link
  | Unsupported_link
  | Orphan_page
  | Orphan_unconfirmed
  | Missing_sources
  | Hearsay_only
  | Unreadable_page
  | Revision_log_gap
  | Revision_log_hole
  | Duplicate_title_candidate
  | Other_lint of string

type wiki_lint_finding = {
  kind : wiki_lint_kind;
  subject : string;
  page : string option;
  file : string option;
  line : int option;
  target : string option;
  form : string option;
  reason : string option;
  log_revision : int option;
  page_revision : int option;
  missing_revision : int option;
}

type wiki_duplicate_candidate = {
  page_a : string;
  title_a : string;
  page_b : string;
  title_b : string;
  reason : string;
}

type wiki_unreadable_page = {
  file : string;
  reason : string;
}

type wiki_page_summary = {
  slug : string;
  file : string;
  title : string;
  summary : string;
  source : wiki_source;
  author : string;
  created : string;
  updated : string;
  revision : int;
  tags : string list;
  backlink_count : int;
  outgoing_link_count : int;
  sources_count : int;
  hearsay_count : int;
  sha256 : string;
}

type wiki_lint_counts = {
  broken_link : int;
  unsupported_link : int;
  orphan : int;
  orphan_unconfirmed : int;
  missing_sources : int;
  hearsay_only : int;
  unreadable_page : int;
  revision_log_gap : int;
  revision_log_hole : int;
  duplicate_title_candidates : int;
}

type wiki_index_lint = {
  total_findings : int;
  counts : wiki_lint_counts;
  log_hole_suppressed : bool;
  orphans : string list;
  duplicate_title_candidates : wiki_duplicate_candidate list;
  findings : wiki_lint_finding list;
}

type wiki_index = {
  pages_total : int;
  pages_readable : int;
  pages_unreadable : int;
  pages : wiki_page_summary list;
  unreadable_pages : wiki_unreadable_page list;
  lint : wiki_index_lint;
}

type wiki_page_detail = {
  page : string;
  slug : string;
  file : string;
  frontmatter : wiki_frontmatter;
  sha256 : string;
  body_markdown : string;
  outgoing_links : wiki_outgoing_link list;
  backlinks : string list;
  lint_findings : wiki_lint_finding list;
}

type wiki_log_entry = {
  idx : int;
  written_at_unix : float;
  action : string;
  revision : int;
  page : string;
  author : string option;
  note : string option;
}

type wiki_log_response = {
  total_lines : int;
  entries : wiki_log_entry list;
  unknown_action : int;
  unreadable_line : int;
  limit : int;
}

type wiki_search_snippet = {
  line : int;
  text : string;
}

type wiki_search_tier =
  | Tier_whole_query
  | Tier_every_term

type wiki_search_result = {
  slug : string;
  title : string;
  summary : string;
  source : wiki_source;
  updated : string;
  revision : int;
  tags : string list;
  score : float;
  match_tier : wiki_search_tier;
  snippets : wiki_search_snippet list;
}

type wiki_search_response = {
  query : string;
  count : int;
  limit : int;
  results : wiki_search_result list;
}

type wiki_lint_report = {
  pages_total : int;
  pages_unreadable : int;
  findings : wiki_lint_finding list;
  counts : wiki_lint_counts;
  duplicate_title_candidates : wiki_duplicate_candidate list;
  log_hole_suppressed : bool;
  log_unknown_action : int;
  log_unreadable_line : int;
}

type wiki_put_request = {
  expected_revision : int option;
  expected_sha256 : string option;
  title : string;
  summary : string;
  source : wiki_source;
  tags : string list;
  body : string;
  note : string;
}

let wiki_source_to_string = function
  | Source_direct_experience -> "direct_experience"
  | Source_research -> "research"
  | Source_experiment -> "experiment"
  | Source_observation -> "observation"

let wiki_source_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "direct_experience" -> Some Source_direct_experience
  | "research" -> Some Source_research
  | "experiment" -> Some Source_experiment
  | "observation" -> Some Source_observation
  | _ -> None

let wiki_lint_kind_of_string = function
  | "broken_link" -> Broken_link
  | "unsupported_link" -> Unsupported_link
  | "orphan" | "orphan_page" -> Orphan_page
  | "orphan_unconfirmed" -> Orphan_unconfirmed
  | "missing_sources" -> Missing_sources
  | "hearsay_only" -> Hearsay_only
  | "unreadable_page" -> Unreadable_page
  | "revision_log_gap" -> Revision_log_gap
  | "revision_log_hole" -> Revision_log_hole
  | "duplicate_title_candidate" | "duplicate_title" -> Duplicate_title_candidate
  | other -> Other_lint other

let optional_nonnegative_count_field json key =
  match optional_int_field json key with
  | Ok (Some n) when n < 0 -> Error (Printf.sprintf "field %S must be >= 0, got %d" key n)
  | (Ok _ | Error _) as result -> result

let optional_nonnegative_count json key =
  Result.map (Option.value ~default:0) (optional_nonnegative_count_field json key)

let decode_wiki_lint_counts json =
  (* [Wiki_lint.counts] omits zero-count keys; validate every present key is >= 0. *)
  let* broken_link = optional_nonnegative_count json "broken_link" in
  let* unsupported_link = optional_nonnegative_count json "unsupported_link" in
  let* orphan = optional_nonnegative_count json "orphan" in
  let* orphan_unconfirmed =
    optional_nonnegative_count json "orphan_unconfirmed"
  in
  let* missing_sources = optional_nonnegative_count json "missing_sources" in
  let* hearsay_only = optional_nonnegative_count json "hearsay_only" in
  let* unreadable_page = optional_nonnegative_count json "unreadable_page" in
  let* revision_log_gap = optional_nonnegative_count json "revision_log_gap" in
  let* revision_log_hole = optional_nonnegative_count json "revision_log_hole" in
  let* duplicate_title_candidates =
    optional_nonnegative_count json "duplicate_title_candidates"
  in
  Ok
    {
      broken_link;
      unsupported_link;
      orphan;
      orphan_unconfirmed;
      missing_sources;
      hearsay_only;
      unreadable_page;
      revision_log_gap;
      revision_log_hole;
      duplicate_title_candidates;
    }

let decode_wiki_lint_finding json =
  let* kind_str = required_nonblank_string json "kind" in
  let* subject = required_nonblank_string json "subject" in
  let* page = optional_nonblank_string json "page" in
  let* file = optional_nonblank_string json "file" in
  let* line = optional_int_field json "line" in
  let* target = optional_nonblank_string json "target" in
  let* form = optional_nonblank_string json "form" in
  let* reason = optional_nonblank_string json "reason" in
  let* log_revision = optional_int_field json "log_revision" in
  let* page_revision = optional_int_field json "page_revision" in
  let* missing_revision = optional_int_field json "missing_revision" in
  Ok
    {
      kind = wiki_lint_kind_of_string kind_str;
      subject;
      page;
      file;
      line;
      target;
      form;
      reason;
      log_revision;
      page_revision;
      missing_revision;
    }

let decode_wiki_duplicate_candidate json =
  let* page_a = required_nonblank_string json "page_a" in
  let* title_a = required_string_field json "title_a" in
  let* page_b = required_nonblank_string json "page_b" in
  let* title_b = required_string_field json "title_b" in
  let* reason = required_nonblank_string json "reason" in
  Ok { page_a; title_a; page_b; title_b; reason }

let decode_wiki_unreadable_page json =
  let* file = required_nonblank_string json "file" in
  let* reason = required_string_field json "reason" in
  Ok { file; reason }

let decode_wiki_page_summary json =
  let* slug = required_nonblank_string json "slug" in
  let* file = required_nonblank_string json "file" in
  let* title = required_nonblank_string json "title" in
  let* summary = required_string_field json "summary" in
  let* source = decode_enum ~field:"source" wiki_source_of_string json in
  let* author = required_nonblank_string json "author" in
  let* created = required_nonblank_string json "created" in
  let* updated = required_nonblank_string json "updated" in
  let* revision = required_nonnegative_int_field json "revision" in
  let* tags = required_string_list json "tags" in
  let* backlink_count = required_nonnegative_int_field json "backlink_count" in
  let* outgoing_link_count =
    required_nonnegative_int_field json "outgoing_link_count"
  in
  let* sources_count = required_nonnegative_int_field json "sources_count" in
  let* hearsay_count = required_nonnegative_int_field json "hearsay_count" in
  let* sha256 = required_nonblank_string json "sha256" in
  Ok
    {
      slug;
      file;
      title;
      summary;
      source;
      author;
      created;
      updated;
      revision;
      tags;
      backlink_count;
      outgoing_link_count;
      sources_count;
      hearsay_count;
      sha256;
    }

let decode_wiki_index json =
  let* _, body = unwrap_v2_or_raw json in
  let* pages_total = required_nonnegative_int_field body "pages_total" in
  let* pages_readable = required_nonnegative_int_field body "pages_readable" in
  let* pages_unreadable =
    required_nonnegative_int_field body "pages_unreadable"
  in
  let* page_items = required_list_field body "pages" in
  let* pages = decode_list "pages" decode_wiki_page_summary page_items in
  let* unreadable_items = optional_list_field body "unreadable_pages" in
  let* unreadable_pages =
    decode_list "unreadable_pages" decode_wiki_unreadable_page unreadable_items
  in
  let* lint_obj = required_object_field body "lint" in
  let* total_findings =
    required_nonnegative_int_field lint_obj "total_findings"
  in
  let* counts_obj = required_object_field lint_obj "counts" in
  let* counts = decode_wiki_lint_counts counts_obj in
  let* log_hole_suppressed =
    required_bool_field lint_obj "log_hole_suppressed"
  in
  let* orphans = optional_string_list lint_obj "orphans" in
  let* dup_items = optional_list_field lint_obj "duplicate_title_candidates" in
  let* duplicate_title_candidates =
    decode_list "duplicate_title_candidates" decode_wiki_duplicate_candidate
      dup_items
  in
  let* finding_items = required_list_field lint_obj "findings" in
  let* findings =
    decode_list "findings" decode_wiki_lint_finding finding_items
  in
  Ok
    {
      pages_total;
      pages_readable;
      pages_unreadable;
      pages;
      unreadable_pages;
      lint =
        {
          total_findings;
          counts;
          log_hole_suppressed;
          orphans;
          duplicate_title_candidates;
          findings;
        };
    }

let decode_wiki_frontmatter json =
  let* title = required_nonblank_string json "title" in
  let* summary = required_string_field json "summary" in
  let* source = decode_enum ~field:"source" wiki_source_of_string json in
  let* author = required_nonblank_string json "author" in
  let* created = required_nonblank_string json "created" in
  let* updated = required_nonblank_string json "updated" in
  let* revision = required_nonnegative_int_field json "revision" in
  let* tags = required_string_list json "tags" in
  Ok { title; summary; source; author; created; updated; revision; tags }

(* The [kind] spellings are the server's [link_to_json] in
   server_dashboard_http_wiki.ml. Only a [page] link carries [exists]. *)
let decode_wiki_link_target json =
  let* kind = required_string_field json "kind" in
  match kind with
  | "page" ->
      let* slug = required_nonblank_string json "target" in
      let* exists = required_bool_field json "exists" in
      Ok (Link_page { slug; exists })
  | "own_file" ->
      let* file = required_nonblank_string json "target" in
      Ok (Link_own_file file)
  | "external" ->
      let* url = required_nonblank_string json "target" in
      Ok (Link_external url)
  | "invalid_name" ->
      let* raw = required_nonblank_string json "target" in
      Ok (Link_invalid_name raw)
  | "unsupported:anchor" -> Ok (Link_unsupported Unsupported_anchor)
  | "unsupported:scheme" -> Ok (Link_unsupported Unsupported_scheme)
  | "unsupported:path" -> Ok (Link_unsupported Unsupported_path)
  | "unsupported:not_markdown" -> Ok (Link_unsupported Unsupported_not_markdown)
  | "unsupported:wikilink" -> Ok (Link_unsupported Unsupported_wikilink)
  | other -> Error (Printf.sprintf "unknown wiki link kind %S" other)

let decode_wiki_outgoing_link json =
  let* text = required_string_field json "text" in
  let* target = decode_wiki_link_target json in
  let* raw = required_string_field json "raw" in
  let* line = required_nonnegative_int_field json "line" in
  Ok ({ text; target; raw; line } : wiki_outgoing_link)

let decode_wiki_page_detail json =
  let* _, body = unwrap_v2_or_raw json in
  let* page = required_nonblank_string body "page" in
  let* slug = required_nonblank_string body "slug" in
  let* file = required_nonblank_string body "file" in
  let* fm_obj = required_object_field body "frontmatter" in
  let* frontmatter = decode_wiki_frontmatter fm_obj in
  let* sha256 = required_nonblank_string body "sha256" in
  let* body_markdown = required_string_field body "body_markdown" in
  let* link_items = required_list_field body "outgoing_links" in
  let* outgoing_links =
    decode_list "outgoing_links" decode_wiki_outgoing_link link_items
  in
  let* backlinks = required_string_list body "backlinks" in
  let* finding_items = required_list_field body "lint_findings" in
  let* lint_findings =
    decode_list "lint_findings" decode_wiki_lint_finding finding_items
  in
  Ok
    {
      page;
      slug;
      file;
      frontmatter;
      sha256;
      body_markdown;
      outgoing_links;
      backlinks;
      lint_findings;
    }

let decode_wiki_log_entry json =
  let* idx = required_nonnegative_int_field json "idx" in
  let* written_at_unix = required_finite_float json "written_at_unix" in
  let* action = required_nonblank_string json "action" in
  let* revision = required_nonnegative_int_field json "revision" in
  let* page = required_nonblank_string json "page" in
  let* author = optional_nonblank_string json "author" in
  let* note = optional_nonblank_string json "note" in
  Ok { idx; written_at_unix; action; revision; page; author; note }

let decode_wiki_log json =
  let* _, body = unwrap_v2_or_raw json in
  let* total_lines = required_nonnegative_int_field body "total_lines" in
  let* unknown_action = required_nonnegative_int_field body "unknown_action" in
  let* unreadable_line =
    required_nonnegative_int_field body "unreadable_line"
  in
  let* limit = required_nonnegative_int_field body "limit" in
  let* items = required_list_field body "entries" in
  let* entries = decode_list "entries" decode_wiki_log_entry items in
  Ok { total_lines; entries; unknown_action; unreadable_line; limit }

let wiki_search_tier_of_string = function
  | "whole_query" -> Some Tier_whole_query
  | "every_term" -> Some Tier_every_term
  | _ -> None

let decode_wiki_search_snippet json =
  let* line = required_nonnegative_int_field json "line" in
  let* text = required_string_field json "text" in
  Ok { line; text }

let decode_wiki_search_result json =
  let* slug = required_nonblank_string json "slug" in
  let* title = required_nonblank_string json "title" in
  let* summary = required_string_field json "summary" in
  let* source = decode_enum ~field:"source" wiki_source_of_string json in
  let* updated = required_nonblank_string json "updated" in
  let* revision = required_nonnegative_int_field json "revision" in
  let* tags = required_string_list json "tags" in
  let* score = required_finite_float json "score" in
  let* match_tier =
    decode_enum ~field:"match_tier" wiki_search_tier_of_string json
  in
  let* snip_items = required_list_field json "snippets" in
  let* snippets =
    decode_list "snippets" decode_wiki_search_snippet snip_items
  in
  Ok
    {
      slug;
      title;
      summary;
      source;
      updated;
      revision;
      tags;
      score;
      match_tier;
      snippets;
    }

let decode_wiki_search json =
  let* _, body = unwrap_v2_or_raw json in
  let* query = required_nonblank_string body "query" in
  let* count = required_nonnegative_int_field body "count" in
  let* limit = required_nonnegative_int_field body "limit" in
  let* items = required_list_field body "results" in
  let* results = decode_list "results" decode_wiki_search_result items in
  Ok { query; count; limit; results }

let decode_wiki_lint json =
  let* _, body = unwrap_v2_or_raw json in
  let* pages_total = required_nonnegative_int_field body "pages_total" in
  let* pages_unreadable =
    required_nonnegative_int_field body "pages_unreadable"
  in
  let* log_hole_suppressed = required_bool_field body "log_hole_suppressed" in
  let* log_unknown_action =
    required_nonnegative_int_field body "log_unknown_action"
  in
  let* log_unreadable_line =
    required_nonnegative_int_field body "log_unreadable_line"
  in
  let* counts_obj = required_object_field body "counts" in
  let* counts = decode_wiki_lint_counts counts_obj in
  let* dup_items = optional_list_field body "duplicate_title_candidates" in
  let* duplicate_title_candidates =
    decode_list "duplicate_title_candidates" decode_wiki_duplicate_candidate
      dup_items
  in
  let* items = required_list_field body "findings" in
  let* findings = decode_list "findings" decode_wiki_lint_finding items in
  Ok
    {
      pages_total;
      pages_unreadable;
      findings;
      counts;
      duplicate_title_candidates;
      log_hole_suppressed;
      log_unknown_action;
      log_unreadable_line;
    }

let encode_wiki_put_request req =
  let rev_field =
    match req.expected_revision with
    | None -> []
    | Some r -> [ ("expected_revision", `Int r) ]
  in
  let sha_field =
    match req.expected_sha256 with
    | None -> []
    | Some s -> [ ("expected_sha256", `String s) ]
  in
  `Assoc
    (rev_field @ sha_field
    @ [
        ("title", `String req.title);
        ("summary", `String req.summary);
        ("source", `String (wiki_source_to_string req.source));
        ("tags", `List (List.map (fun t -> `String t) req.tags));
        ("body", `String req.body);
        ("note", `String req.note);
      ])

type artifact_format = [ `Html | `Markdown ]

type artifact_body = {
  sha256 : string;
  bytes : int;
  mime : string;
}

type artifact_entry = {
  id : string;
  revision : int;
  title : string;
  summary : string;
  author : string;
  created_at_unix : float;
  body : artifact_body;
}

type artifact_revision_summary = {
  revision : int;
  title : string;
  summary : string;
  format : artifact_format;
  author : string;
  created_at_unix : float option;
  sha256 : string;
  bytes : int;
  mime_type : string;
  preview : string option;
  task_id : string option;
  goal_id : string option;
}

type published_artifact_detail = {
  artifact : artifact_entry;
  content : string;
  revisions : artifact_revision_summary list;
  shared : bool;
  share_version : int;
}

let artifact_format_of_mime mime_type =
  let lower_mime = String.lowercase_ascii (String.trim mime_type) in
  if
    String.starts_with ~prefix:"text/html" lower_mime
    || String.starts_with ~prefix:"application/xhtml" lower_mime
  then `Html
  else `Markdown

let artifact_format_of_entry (a : artifact_entry) =
  artifact_format_of_mime a.body.mime

let artifact_extension = function
  | `Html -> ".html"
  | `Markdown -> ".md"

let decode_artifact_format ~mime_type json =
  match optional_nonblank_string json "format" with
  | Error _ as err -> err
  | Ok (Some raw) -> (
      match String.lowercase_ascii (String.trim raw) with
      | "html" -> Ok `Html
      | "markdown" | "md" -> Ok `Markdown
      | other -> Error ("unknown artifact format: " ^ other))
  | Ok None -> Ok (artifact_format_of_mime mime_type)

let decode_optional_text_field json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | bad -> field_type_error key "a string or null" bad

let decode_artifact_created_at json =
  let* ts_primary = decode_optional_timestamp_unix json "created_at" in
  match ts_primary with
  | Some _ as hit -> Ok hit
  | None -> decode_optional_timestamp_unix json "created_at_unix"

(* A row is [Published_artifact.summary_to_json]: the latest revision of one
   artifact, its body a content-addressed [_blob] reference. *)
let decode_artifact_body json =
  let* blob = required_object_field json "_blob" in
  let* sha256 = required_nonblank_string blob "sha256" in
  let* bytes = required_nonnegative_int_field blob "bytes" in
  let* mime = required_nonblank_string blob "mime" in
  Ok ({ sha256; bytes; mime } : artifact_body)

let decode_artifact_entry json =
  let* id = required_nonblank_string json "id" in
  let* revision = required_int_field json "revision" in
  let* () =
    if revision >= 1 then Ok ()
    else Error (Printf.sprintf "field \"revision\" must be >= 1, got %d" revision)
  in
  let* title = required_nonblank_string json "title" in
  let* summary = required_nonblank_string json "summary" in
  let* author = required_nonblank_string json "author" in
  let* created_at_unix = decode_timestamp_unix json "created_at" in
  let* body_obj = required_object_field json "body" in
  let* body = decode_artifact_body body_obj in
  Ok
    ({ id; revision; title; summary; author; created_at_unix; body }
      : artifact_entry)

let decode_artifact_revision_summary json =
  let* revision = required_int_field json "revision" in
  let* title_opt = optional_nonblank_string json "title" in
  let title = Option.value ~default:"" title_opt in
  let* summary_opt = optional_string_field json "summary" in
  let summary = Option.value ~default:"" summary_opt in
  let* author_opt = optional_nonblank_string json "author" in
  let author = Option.value ~default:"" author_opt in
  let* created_at_unix = decode_artifact_created_at json in
  let* body_opt = optional_object_field json "body" in
  let* src =
    match body_opt with
    | None -> Ok json
    | Some body_obj ->
        let* blob_opt = optional_object_field body_obj "_blob" in
        Ok (Option.value ~default:body_obj blob_opt)
  in
  let* sha256 = required_nonblank_string src "sha256" in
  let* bytes = required_nonnegative_int_field src "bytes" in
  let* mime_opt = optional_nonblank_string src "mime" in
  let* mime_type =
    match mime_opt with
    | Some m -> Ok m
    | None -> (
        match optional_nonblank_string src "mime_type" with
        | Ok (Some m) -> Ok m
        | Ok None -> Ok "text/plain"
        | Error _ as err -> err)
  in
  let* preview = decode_optional_text_field src "preview" in
  let* format = decode_artifact_format ~mime_type json in
  let* task_id = optional_nonblank_string json "task_id" in
  let* goal_id = optional_nonblank_string json "goal_id" in
  Ok
    {
      revision;
      title;
      summary;
      format;
      author;
      created_at_unix;
      sha256;
      bytes;
      mime_type;
      preview;
      task_id;
      goal_id;
    }

let decode_artifacts_list json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "artifacts" in
  decode_list "artifacts" decode_artifact_entry items

let decode_published_artifact_detail json =
  let* _, body = unwrap_v2_or_raw json in
  let* artifact_json = required_object_field body "artifact" in
  let* artifact = decode_artifact_entry artifact_json in
  let* content = required_string_field body "content" in
  let* rev_items = optional_list_field body "revisions" in
  let* revisions =
    decode_list "revisions" decode_artifact_revision_summary rev_items
  in
  let* shared_opt = optional_bool_field body "shared" in
  let shared = Option.value ~default:false shared_opt in
  let* share_ver_opt = optional_int_field body "share_version" in
  let share_version = Option.value ~default:0 share_ver_opt in
  Ok { artifact; content; revisions; shared; share_version }

type board_hearth_entry = {
  name : string;
  count : int;
}

let decode_board_hearth_entry json =
  let* name = required_nonblank_string json "name" in
  let* count = required_nonnegative_int_field json "count" in
  Ok { name; count }

let decode_board_hearths json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "hearths" in
  decode_list "hearths" decode_board_hearth_entry items

let encode_board_comment ~post_id ~content ?parent_id () =
  let base =
    [ ("post_id", `String post_id); ("content", `String content) ]
  in
  let fields =
    match parent_id with
    | Some pid when not (String.equal (String.trim pid) "") ->
        base @ [ ("parent_id", `String (String.trim pid)) ]
    | Some _ | None -> base
  in
  `Assoc fields

let vote_dir_str = function `Up -> "up" | `Down -> "down"

let encode_board_vote ~post_id ~direction =
  `Assoc
    [ ("post_id", `String post_id); ("direction", `String (vote_dir_str direction)) ]

let encode_board_comment_vote ~comment_id ~direction =
  `Assoc
    [
      ("comment_id", `String comment_id);
      ("direction", `String (vote_dir_str direction));
    ]

let encode_board_pin ~post_id ~pinned =
  `Assoc [ ("post_id", `String (String.trim post_id)); ("pinned", `Bool pinned) ]

let encode_board_delete ~post_id =
  `Assoc [ ("post_id", `String (String.trim post_id)) ]

type artifact_check = {
  id : string;
  revision : int;
  body_sha256 : string;
  checked : bool;
  change_id : string;
  changed_by : string;
  changed_at : string;
}

type artifact_share_result = {
  id : string;
  shared : bool;
  version : int;
  outcome : [ `Applied | `Conflict ];
}

let decode_artifact_check_entry json =
  let* id = required_nonblank_string json "id" in
  let* revision = required_int_field json "revision" in
  let* body_sha256 = required_nonblank_string json "body_sha256" in
  let* checked = required_bool_field json "checked" in
  let* change_id = required_nonblank_string json "change_id" in
  let* changed_by = required_nonblank_string json "changed_by" in
  let* changed_at = required_nonblank_string json "changed_at" in
  Ok { id; revision; body_sha256; checked; change_id; changed_by; changed_at }

let decode_artifact_checks json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "checks" in
  decode_list "checks" decode_artifact_check_entry items

let decode_artifact_check_reply json =
  let* _, body = unwrap_v2_or_raw json in
  let* check_obj = required_object_field body "check" in
  decode_artifact_check_entry check_obj

let encode_artifact_check_request ?expected_workspace ~id ~revision ~body_sha256
    ~checked ~expected_change_id () =
  let ws_fields =
    match expected_workspace with
    | Some (base_path, masc_root) ->
        [
          ( "expected_workspace",
            `Assoc
              [ ("base_path", `String base_path); ("masc_root", `String masc_root) ] );
        ]
    | None -> []
  in
  let exp_change =
    match expected_change_id with
    | Some cid -> `String cid
    | None -> `Null
  in
  `Assoc
    (ws_fields
    @ [
        ("id", `String id);
        ("revision", `Int revision);
        ("body_sha256", `String body_sha256);
        ("checked", `Bool checked);
        ("expected_change_id", exp_change);
      ])

let encode_artifact_share_request ~expected_workspace:(base_path, masc_root) ~id
    ~shared ~operation_id ~expected_version ~expected_artifact_revision
    ~expected_artifact_sha256 =
  `Assoc
    [
      ( "expected_workspace",
        `Assoc
          [ ("base_path", `String base_path); ("masc_root", `String masc_root) ] );
      ("id", `String id);
      ("shared", `Bool shared);
      ("operation_id", `String operation_id);
      ("expected_version", `Int expected_version);
      ("expected_artifact_revision", `Int expected_artifact_revision);
      ("expected_artifact_sha256", `String expected_artifact_sha256);
    ]

let decode_artifact_share_response json =
  let* _, body = unwrap_v2_or_raw json in
  let* id = required_nonblank_string body "id" in
  let* cur = required_object_field body "current" in
  let* shared = required_bool_field cur "shared" in
  let* version = required_nonnegative_int_field cur "version" in
  let* receipt = required_object_field body "receipt" in
  let* outcome_str = required_nonblank_string receipt "outcome" in
  let* outcome =
    match outcome_str with
    | "applied" -> Ok `Applied
    | "conflict" -> Ok `Conflict
    | other -> Error ("unknown artifact share outcome: " ^ other)
  in
  Ok { id; shared; version; outcome }

type world_ledger_state =
  | World_ledger_missing
  | World_ledger_available

type briefing_status =
  | Briefing_missing
  | Briefing_current
  | Briefing_stale
  | Briefing_unavailable

type writer_state =
  | Writer_open
  | Writer_idle
  | Writer_asking
  | Writer_resting
  | Writer_refused_at_bottom
  | Writer_booting
  | Writer_retired
  | Writer_stopped of string
  | Writer_no_writer

type memory_recovery_act =
  | Act_resume
  | Act_adopt of { observed : string }
  | Act_restart_reading of { observed : string }
  | Act_skip_item of { turn_log : string; line : int }
  | Act_skip_line of { offset : int }

type world_claim = {
  claim_id : string;
  claim : string;
  stage : string;
  supporting_keepers : string list;
  support_count : int;
  has_source_bound : bool;
}

type competing_claim = {
  store_kind : string;
  keeper_id : string;
  path : string option;
  claim_sha256 : string;
  resolved : bool;
  claim : string option;
  category : string option;
  origin : string option;
  first_seen_unix : float option;
  last_seen_unix : float option;
}

type memory_conflict = {
  conflict_id : string;
  description : string;
  member_count : int;
  competing_claims : competing_claim list;
}

type snapshot_file_status =
  | Snapshot_file_present of { sha : string; bytes : int }
  | Snapshot_file_fault of string

type librarian_writer_row = {
  keeper : string;
  state : writer_state;
  available_act_tokens : string list;
  snapshot_file : snapshot_file_status option;
}

type librarian_writers_section =
  | Writers_none_in_process
  | Writers_running of {
      error_count : int;
      warn_count : int;
      keepers : librarian_writer_row list;
    }

type world_briefing = {
  status : briefing_status;
  text : string option;
  source_ids_count : int;
  error : string option;
  building_pass : (int * int) option;
}

type world_memory = {
  ledger_state : world_ledger_state;
  ledger_sha256 : string option;
  claims_count : int;
  facts_count : int;
  conflicts_count : int;
  excluded_count : int;
  claims : world_claim list;
  active_conflicts : memory_conflict list;
  briefing : world_briefing;
  librarian_writers : librarian_writers_section;
  ordinary_absence_detail : string option;
}

type memory_scope =
  | Scope_world
  | Scope_keeper of string

type memory_diff_range = {
  window : string option;
  from_rev : int option;
  to_rev : int option;
  from_unix : float option;
  to_unix : float option;
}

type retrieval_heat_summary = {
  hot : int;
  warm : int;
  cold : int;
  never_retrieved : int;
  total_events : int;
  unreadable_event_lines : int;
}

type memory_heat =
  | Heat_hot
  | Heat_warm
  | Heat_cold
  | Heat_never_retrieved

type modification_relation =
  | Revision
  | Program_revision
  | Program_absorption

type memory_revision_tick = {
  rev : int;
  at_unix : float;
  source : string;
  added : int;
  removed : int;
  invalidated : int;
}

type memory_fact_entry = {
  event_order : int option;
  added_at_rev : int option;
  memory_id : string;
  category : string;
  origin : string;
  text : string;
  first_seen_unix : float;
  last_seen_unix : float option;
  retrieval_count : int;
  last_retrieved_at_unix : float option;
  heat : memory_heat;
}

type successor_body_source = Same_commit | Held_before | Current_snapshot | Archived_fact

type memory_updated_fact = {
  event_order : int option;
  relation : modification_relation;
  at_rev : int option;
  at_unix : float option;
  before : memory_fact_entry;
  after : memory_fact_entry;
  after_source : successor_body_source option;
}

type memory_retracted_fact = {
  event_order : int option;
  memory_id : string;
  category : string;
  text : string;
  removed_at_rev : int option;
  at_unix : float option;
  removed_by : string option;
  drop_reason : string option;
}

type memory_invalidated_fact = {
  event_order : int option;
  memory_id : string;
  text : string;
  at_rev : int option;
  at_unix : float option;
  missing_premise_ids : string list;
}

type history_limit = Live_rows | Live_bytes | Archive_rows | Archive_bytes | Result_rows | Result_bytes

type folded_history =
  { through_seq : int; min_revision : int; max_revision : int; min_at : float; max_at : float }

type keeper_history_coverage =
  | Complete_history
  | Complete_with_retention of folded_history
  | Partial_history of
      { missing_sequences : (int * int) list
      ; unsequenced_in_window : int
      ; unplaced_in_revision_range : int
      ; folded_detail : folded_history option
      ; retention_applies : bool
      ; input_limited : bool
      ; output_limited : bool
      ; limit_causes : history_limit list
      ; conflicting_sequences : int
      ; unreadable_lines : int
      ; unresolved_successors : int
      ; snapshot_ahead : bool
      ; snapshot_behind : bool
      }

type keeper_diff_counts = {
  total_facts_now : int;
  added : int;
  updated : int;
  retracted : int;
  invalidated : int;
  journal_failures_in_window : int;
  journal_quarantines_in_window : int;
  undecodable_journal_lines : int;
  history_coverage : keeper_history_coverage option;
}

type keeper_writer_status =
  | Keeper_writer_none_in_process
  | Keeper_writer_none
  | Keeper_writer_active of {
      state : writer_state;
      available_act_tokens : string list;
      snapshot_file : snapshot_file_status option;
    }

type world_diff_counts = {
  total_claims_now : int;
  added : int;
  updated : int;
  retracted : int;
  incomplete_batches : int;
  aborted_batches : int;
}

type world_change_history = {
  edge_changes : int;
  index_updates : int;
  digest_commits : int;
  missing_evidence : int;
  retained_from_seq : int option;
}

type world_revision_tick = {
  rev : int;
  batch_id : string;
  fact_id : string;
  recorded_at : string;
  op : string;
}

type world_change_entry = {
  seq : int;
  batch_id : string;
  fact_id : string;
  summary : string;
  recorded_at : string;
  claim_text : string option;
  payload : Yojson.Safe.t;
}

type world_updated_entry = {
  seq : int;
  fact_id : string;
  summary : string;
  recorded_at : string;
  before_text : string option;
  claim_text : string option;
  before : Yojson.Safe.t;
  after : Yojson.Safe.t;
}

type memory_diff_body =
  | Keeper_diff of {
      counts : keeper_diff_counts;
      revisions : memory_revision_tick list;
      added : memory_fact_entry list;
      updated : memory_updated_fact list;
      retracted : memory_retracted_fact list;
      invalidated : memory_invalidated_fact list;
      writer_status : keeper_writer_status option;
    }
  | World_diff of {
      counts : world_diff_counts;
      history : world_change_history option;
      unparseable_timestamps : int;
      revisions : world_revision_tick list;
      added : world_change_entry list;
      updated : world_updated_entry list;
      retracted : world_change_entry list;
    }

type memory_diff = {
  scope : memory_scope;
  range : memory_diff_range;
  retrieval_heat : retrieval_heat_summary;
  body : memory_diff_body;
}

type memory_act_answer =
  | Memory_act_done of writer_state
  | Memory_act_refused of { code : string; detail : string option }
  | Memory_act_invalid of string
  | Memory_act_no_writer

let world_ledger_state_of_string = function
  | "missing" -> Some World_ledger_missing
  | "available" -> Some World_ledger_available
  | _ -> None

let briefing_status_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "missing" -> Some Briefing_missing
  | "current" -> Some Briefing_current
  | "stale" -> Some Briefing_stale
  | "unavailable" -> Some Briefing_unavailable
  | _ -> None

let decode_writer_state_string json field =
  let* raw = required_nonblank_string json field in
  match String.lowercase_ascii raw with
  | "open" -> Ok Writer_open
  | "idle" -> Ok Writer_idle
  | "asking" -> Ok Writer_asking
  | "resting" -> Ok Writer_resting
  | "refused_at_bottom" -> Ok Writer_refused_at_bottom
  | "booting" -> Ok Writer_booting
  | "retired" -> Ok Writer_retired
  | "no_writer" -> Ok Writer_no_writer
  | "stopped" ->
      let* reason =
        match optional_nonblank_string json "stop" with
        | Ok (Some r) -> Ok r
        | Ok None -> (
            match optional_nonblank_string json "stopped" with
            | Ok (Some r) -> Ok r
            | Ok None -> (
                match optional_nonblank_string json "stop_reason" with
                | Ok (Some r) -> Ok r
                | Ok None -> Ok "stopped"
                | Error _ as err -> err)
            | Error _ as err -> err)
        | Error _ as err -> err
      in
      Ok (Writer_stopped reason)
  | other -> Error (Printf.sprintf "unknown memory writer state %S" other)

let decode_world_claim json =
  let* claim_id = required_nonblank_string json "claim_id" in
  let* claim = required_string_field json "claim" in
  let* stage = required_nonblank_string json "stage" in
  let* supporting_keepers = required_string_list json "supporting_keepers" in
  let* support_count = required_nonnegative_int_field json "support_count" in
  let* has_source_bound = required_bool_field json "has_source_bound" in
  Ok { claim_id; claim; stage; supporting_keepers; support_count; has_source_bound }

let decode_competing_claim json =
  let* store_kind = required_nonblank_string json "store_kind" in
  let* keeper_id = required_nonblank_string json "keeper_id" in
  let* path = optional_nonblank_string json "path" in
  let* claim_sha256 = required_nonblank_string json "claim_sha256" in
  let* resolved = required_bool_field json "resolved" in
  let* claim = optional_nonblank_string json "claim" in
  let* category = optional_nonblank_string json "category" in
  let* origin = optional_nonblank_string json "origin" in
  let* first_seen_unix = optional_finite_float json "first_seen_unix" in
  let* last_seen_unix = optional_finite_float json "last_seen_unix" in
  Ok
    {
      store_kind;
      keeper_id;
      path;
      claim_sha256;
      resolved;
      claim;
      category;
      origin;
      first_seen_unix;
      last_seen_unix;
    }

let decode_conflict json =
  let* conflict_id = required_nonblank_string json "conflict_id" in
  let* description = required_string_field json "description" in
  let* member_count = required_nonnegative_int_field json "member_count" in
  let* items = required_list_field json "competing_claims" in
  let* competing_claims =
    decode_list "competing_claims" decode_competing_claim items
  in
  Ok { conflict_id; description; member_count; competing_claims }

let decode_snapshot_file_opt json =
  match optional_object_field json "snapshot_file" with
  | Ok None -> Ok None
  | Error _ as err -> err
  | Ok (Some sf) -> (
      match optional_nonblank_string sf "sha", optional_int_field sf "bytes" with
      | Ok (Some sha), Ok (Some bytes) ->
          Ok (Some (Snapshot_file_present { sha; bytes = max 0 bytes }))
      | Ok (Some sha), Ok None ->
          Ok (Some (Snapshot_file_present { sha; bytes = 0 }))
      | Ok None, _ -> (
          match optional_nonblank_string sf "fault" with
          | Ok (Some f) -> Ok (Some (Snapshot_file_fault f))
          | Ok None -> Ok None
          | Error _ as err -> err)
      | Error _ as err, _ | _, (Error _ as err) -> err)

let decode_librarian_writer_entry json =
  let* keeper = required_nonblank_string json "keeper" in
  let* row_obj = required_object_field json "row" in
  let* state = decode_writer_state_string row_obj "state" in
  let* available_act_tokens = optional_string_list row_obj "available_acts" in
  let* snapshot_file = decode_snapshot_file_opt row_obj in
  Ok { keeper; state; available_act_tokens; snapshot_file }

let decode_librarian_writers_section json =
  let* writers_mode = required_nonblank_string json "writers" in
  match writers_mode with
  | "none_in_process" -> Ok Writers_none_in_process
  | "running" ->
      let* error_count = required_nonnegative_int_field json "error" in
      let* warn_count = required_nonnegative_int_field json "warn" in
      let* keeper_items = required_list_field json "keepers" in
      let* keepers =
        decode_list "keepers" decode_librarian_writer_entry keeper_items
      in
      Ok (Writers_running { error_count; warn_count; keepers })
  | other -> Error (Printf.sprintf "unknown librarian_writers state %S" other)

let decode_world_briefing json =
  let* status = decode_enum ~field:"status" briefing_status_of_string json in
  let* text = optional_nonblank_string json "text" in
  let* source_ids_count =
    required_nonnegative_int_field json "source_ids_count"
  in
  let* error = optional_nonblank_string json "error" in
  let* building_pass =
    match optional_object_field json "building_pass" with
    | Ok None -> Ok None
    | Ok (Some bp) ->
        let* target = required_nonnegative_int_field bp "target" in
        let* remaining = required_nonnegative_int_field bp "remaining" in
        Ok (Some (target, remaining))
    | Error _ as err -> err
  in
  Ok { status; text; source_ids_count; error; building_pass }

let decode_world_memory json =
  let* _, body = unwrap_v2_or_raw json in
  let* ledger_state =
    decode_enum ~field:"ledger_state" world_ledger_state_of_string body
  in
  let* inv_obj = required_object_field body "inventory" in
  let* ledger_sha256 = optional_nonblank_string inv_obj "ledger_sha256" in
  let* claims_count = required_nonnegative_int_field inv_obj "claims_count" in
  let* facts_count = required_nonnegative_int_field inv_obj "facts_count" in
  let* conflicts_count =
    required_nonnegative_int_field inv_obj "conflicts_count"
  in
  let* excluded_count =
    required_nonnegative_int_field inv_obj "excluded_count"
  in
  let* ordinary_absence_detail =
    match optional_object_field inv_obj "ordinary_absence" with
    | Ok (Some oa) -> optional_nonblank_string oa "detail"
    | Ok None -> Ok None
    | Error _ as err -> err
  in
  let* claim_items = required_list_field body "claims" in
  let* claims = decode_list "claims" decode_world_claim claim_items in
  let* conflict_items = required_list_field body "active_conflicts" in
  let* active_conflicts =
    decode_list "active_conflicts" decode_conflict conflict_items
  in
  let* briefing_obj = required_object_field body "briefing" in
  let* briefing = decode_world_briefing briefing_obj in
  let* writers_obj = required_object_field body "librarian_writers" in
  let* librarian_writers = decode_librarian_writers_section writers_obj in
  Ok
    {
      ledger_state;
      ledger_sha256;
      claims_count;
      facts_count;
      conflicts_count;
      excluded_count;
      claims;
      active_conflicts;
      briefing;
      librarian_writers;
      ordinary_absence_detail;
    }

let decode_workspace_memory_inventory_as_world_memory json =
  let* _, body = unwrap_v2_or_raw json in
  let* status_str = required_nonblank_string body "status" in
  let* ledger_state =
    match String.lowercase_ascii (String.trim status_str) with
    | "available" -> Ok World_ledger_available
    | "missing" -> Ok World_ledger_missing
    | other ->
        Error
          (Printf.sprintf "unknown workspace-memory-inventory status %S" other)
  in
  let* ledger_sha256 = optional_nonblank_string body "ledger_sha256" in
  let* claims_count = optional_nonnegative_count body "claim_count" in
  let* conflicts_count = optional_nonnegative_count body "conflict_count" in
  let* excluded_count = optional_nonnegative_count body "excluded_count" in
  let* oa_opt = optional_object_field body "ordinary_absence" in
  let* facts_count, ordinary_absence_detail =
    match oa_opt with
    | None -> Ok (0, None)
    | Some oa ->
        let* facts = optional_nonnegative_count oa "facts" in
        let* detail = optional_nonblank_string oa "detail" in
        let* status_oa = optional_nonblank_string oa "status" in
        let detail' =
          match detail with Some _ as d -> d | None -> status_oa
        in
        Ok (facts, detail')
  in
  let* briefing_opt = optional_object_field body "briefing" in
  let* briefing =
    match briefing_opt with
    | None ->
        Ok
          {
            status = Briefing_missing;
            text = None;
            source_ids_count = 0;
            error = None;
            building_pass = None;
          }
    | Some br ->
        let* raw_status = required_nonblank_string br "status" in
        let* status =
          match String.lowercase_ascii (String.trim raw_status) with
          | "current" -> Ok Briefing_current
          | "stale" -> Ok Briefing_stale
          | "missing" | "pending" -> Ok Briefing_missing
          | "unavailable" -> Ok Briefing_unavailable
          | other ->
              Error (Printf.sprintf "unknown inventory briefing status %S" other)
        in
        let* building_pass =
          match optional_object_field br "building" with
          | Ok None -> Ok None
          | Ok (Some bp) ->
              let* target = required_nonnegative_int_field bp "target" in
              let* remaining = required_nonnegative_int_field bp "remaining" in
              Ok (Some (target, remaining))
          | Error _ as err -> err
        in
        Ok
          {
            status;
            text = None;
            source_ids_count = claims_count;
            error = None;
            building_pass;
          }
  in
  Ok
    {
      ledger_state;
      ledger_sha256;
      claims_count;
      facts_count;
      conflicts_count;
      excluded_count;
      claims = [];
      active_conflicts = [];
      briefing;
      librarian_writers = Writers_none_in_process;
      ordinary_absence_detail;
    }

let memory_heat_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "hot" -> Some Heat_hot
  | "warm" -> Some Heat_warm
  | "cold" -> Some Heat_cold
  | "never_retrieved" -> Some Heat_never_retrieved
  | _ -> None

let relation_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "revision" -> Some Revision
  | "program_revision" -> Some Program_revision
  | "program_absorption" -> Some Program_absorption
  | _ -> None

let decode_diff_range json =
  let* window = optional_nonblank_string json "window" in
  let* from_rev = optional_int_field json "from_rev" in
  let* to_rev = optional_int_field json "to_rev" in
  let* from_unix = optional_finite_float json "from_unix" in
  let* to_unix = optional_finite_float json "to_unix" in
  Ok { window; from_rev; to_rev; from_unix; to_unix }

let decode_retrieval_heat json =
  let* hot = required_nonnegative_int_field json "hot" in
  let* warm = required_nonnegative_int_field json "warm" in
  let* cold = required_nonnegative_int_field json "cold" in
  let* never_retrieved =
    required_nonnegative_int_field json "never_retrieved"
  in
  let* total_events = required_nonnegative_int_field json "total_events" in
  let* unreadable_event_lines =
    required_nonnegative_int_field json "unreadable_event_lines"
  in
  Ok { hot; warm; cold; never_retrieved; total_events; unreadable_event_lines }

let decode_revision_tick json =
  let* rev = required_nonnegative_int_field json "rev" in
  let* at_unix = required_finite_float json "at_unix" in
  let* source = required_nonblank_string json "source" in
  let* added = required_nonnegative_int_field json "added" in
  let* removed = required_nonnegative_int_field json "removed" in
  let* invalidated = required_nonnegative_int_field json "invalidated" in
  Ok { rev; at_unix; source; added; removed; invalidated }

let decode_fact_entry json =
  let* event_order = optional_int_field json "order" in
  let* added_at_rev = optional_int_field json "added_at_rev" in
  let* memory_id = required_nonblank_string json "memory_id" in
  let* category = required_nonblank_string json "category" in
  let* origin = required_nonblank_string json "origin" in
  let* text = required_string_field json "text" in
  let* first_seen_unix = required_finite_float json "first_seen_unix" in
  let* last_seen_unix = optional_finite_float json "last_seen_unix" in
  let* retrieval_count =
    required_nonnegative_int_field json "retrieval_count"
  in
  let* last_retrieved_at_unix =
    optional_finite_float json "last_retrieved_at_unix"
  in
  let* heat = decode_enum ~field:"heat" memory_heat_of_string json in
  Ok
    {
      event_order;
      added_at_rev;
      memory_id;
      category;
      origin;
      text;
      first_seen_unix;
      last_seen_unix;
      retrieval_count;
      last_retrieved_at_unix;
      heat;
    }

let event_coordinates json key =
  let* revision = optional_int_field json key in
  let* at = optional_finite_float json "at_unix" in
  match revision, at with
  | Some rev, _ when rev < 0 -> Error ("negative revision in " ^ key)
  | None, None -> Error ("missing revision and event time in " ^ key)
  | Some _, _ | None, Some _ -> Ok (revision, at)

let decode_updated_fact json =
  let* relation = decode_enum ~field:"relation" relation_of_string json in
  let* event_order = optional_int_field json "order" in
  let* at_rev, at_unix = event_coordinates json "at_rev" in
  let* before_obj = required_object_field json "before" in
  let* before = decode_fact_entry before_obj in
  let* after_obj = required_object_field json "after" in
  let* after = decode_fact_entry after_obj in
  let* source = optional_nonblank_string json "after_source" in
  let* after_source = match source with
    | None -> Ok None | Some "same_commit" -> Ok (Some Same_commit)
    | Some "held_before" -> Ok (Some Held_before) | Some "current_snapshot" -> Ok (Some Current_snapshot)
    | Some "archived_fact" -> Ok (Some Archived_fact) | Some other -> Error ("unknown successor source: " ^ other)
  in
  Ok { event_order; relation; at_rev; at_unix; before; after; after_source }

let decode_retracted_fact json =
  let* memory_id = required_nonblank_string json "memory_id" in
  let* category = required_nonblank_string json "category" in
  let* text = required_string_field json "text" in
  let* event_order = optional_int_field json "order" in
  let* removed_at_rev, at_unix = event_coordinates json "removed_at_rev" in
  let* removed_by = optional_nonblank_string json "removed_by" in
  let* drop_reason = optional_nonblank_string json "drop_reason" in
  Ok { event_order; memory_id; category; text; removed_at_rev; at_unix; removed_by; drop_reason }

let decode_invalidated_fact json =
  let* memory_id = required_nonblank_string json "memory_id" in
  let* text = required_string_field json "text" in
  let* event_order = optional_int_field json "order" in
  let* at_rev, at_unix = event_coordinates json "at_rev" in
  let* missing_premise_ids = required_string_list json "missing_premise_ids" in
  Ok { event_order; memory_id; text; at_rev; at_unix; missing_premise_ids }

let decode_keeper_history_coverage data =
  let* object_ = optional_object_field data "coverage" in
  match object_ with
  | None -> Ok None
  | Some obj ->
    let* state = required_nonblank_string obj "status" in
    let* folded = optional_object_field obj "folded_detail" in
    let* folded_detail = match folded with
      | None -> Ok None
      | Some f ->
        let* through_seq = required_nonnegative_int_field f "through_seq" in
        let* min_revision = required_nonnegative_int_field f "min_revision" in
        let* max_revision = required_nonnegative_int_field f "max_revision" in
        let* min_at = required_finite_float f "min_at" in
        let* max_at = required_finite_float f "max_at" in
        if through_seq < 1 || min_revision > max_revision || min_at > max_at then Error "invalid folded history range"
        else Ok (Some { through_seq; min_revision; max_revision; min_at; max_at }) in
    (match state with
     | "complete" -> Ok (Some (match folded_detail with None -> Complete_history | Some f -> Complete_with_retention f))
     | "partial" ->
       let flag key = Result.map (Option.value ~default:false) (optional_bool_field obj key) in
       let* retention_applies = flag "retention_applies" in
       let* input_limited = flag "input_limited" in
       let* output_limited = flag "output_limited" in
       let* causes = optional_list_field obj "limit_causes" in
       let* limit_causes = decode_list "limit_causes" (function
         | `String "live_rows" -> Ok Live_rows | `String "live_bytes" -> Ok Live_bytes
         | `String "archive_rows" -> Ok Archive_rows | `String "archive_bytes" -> Ok Archive_bytes
         | `String "result_rows" -> Ok Result_rows | `String "result_bytes" -> Ok Result_bytes
         | _ -> Error "unknown memory history limit") causes in
       let* conflicting_sequences = optional_nonnegative_count obj "conflicting_sequences" in
       let* gaps = required_list_field obj "missing_sequences" in
       let* missing_sequences = decode_list "missing_sequences" (fun json ->
         let* first = required_nonnegative_int_field json "first" in
         let* last = required_nonnegative_int_field json "last" in
         if first < 1 || last < first then Error "invalid missing sequence range" else Ok (first, last)) gaps in
       let* unsequenced_in_window = required_nonnegative_int_field obj "unsequenced_in_window" in
       let* unplaced_in_revision_range = required_nonnegative_int_field obj "unplaced_in_revision_range" in
       let* unreadable_lines = required_nonnegative_int_field obj "unreadable_lines" in
       let* unresolved_successors = required_nonnegative_int_field obj "unresolved_successors" in
       let* snapshot_ahead = required_bool_field obj "snapshot_ahead" in
       let* snapshot_behind = required_bool_field obj "snapshot_behind" in
       Ok (Some (Partial_history { missing_sequences; unsequenced_in_window; unplaced_in_revision_range;
                                   folded_detail; retention_applies; input_limited; output_limited; limit_causes; conflicting_sequences;
                                   unreadable_lines; unresolved_successors; snapshot_ahead; snapshot_behind }))
     | other -> Error ("unknown keeper history coverage: " ^ other))

let decode_keeper_writer_status json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "none_in_process" -> Ok Keeper_writer_none_in_process
  | "no_writer" -> Ok Keeper_writer_none
  | "writer" ->
      let* row = required_object_field json "row" in
      let* state = decode_writer_state_string row "state" in
      let* available_act_tokens = optional_string_list row "available_acts" in
      let* snapshot_file = decode_snapshot_file_opt row in
      Ok (Keeper_writer_active { state; available_act_tokens; snapshot_file })
  | other -> Error (Printf.sprintf "unknown keeper writer_status kind %S" other)

let decode_world_revision_tick json =
  let* rev = required_nonnegative_int_field json "rev" in
  let* batch_id = required_nonblank_string json "batch_id" in
  let* fact_id = required_nonblank_string json "fact_id" in
  let* recorded_at = required_nonblank_string json "recorded_at" in
  let* op = required_nonblank_string json "op" in
  Ok { rev; batch_id; fact_id; recorded_at; op }

let decode_world_change_entry json =
  let* seq = required_nonnegative_int_field json "seq" in
  let* batch_id = required_nonblank_string json "batch_id" in
  let* fact_id = required_nonblank_string json "fact_id" in
  let* summary = required_string_field json "summary" in
  let* recorded_at = required_nonblank_string json "recorded_at" in
  let* claim_text = optional_nonblank_string json "claim_text" in
  let payload = member "payload" json in
  Ok { seq; batch_id; fact_id; summary; recorded_at; claim_text; payload }

let decode_world_updated_entry json =
  let* seq = required_nonnegative_int_field json "seq" in
  let* fact_id = required_nonblank_string json "fact_id" in
  let* summary = required_string_field json "summary" in
  let* recorded_at = required_nonblank_string json "recorded_at" in
  let* before_text = optional_nonblank_string json "before_text" in
  let* claim_text = optional_nonblank_string json "claim_text" in
  let before = member "before" json in
  let after = member "after" json in
  Ok { seq; fact_id; summary; recorded_at; before_text; claim_text; before; after }

let decode_world_change_history body =
  let* history = optional_object_field body "history" in
  match history with
  | None -> Ok None
  | Some history ->
      let* edge_changes = required_nonnegative_int_field history "edge_changes" in
      let* index_updates = required_nonnegative_int_field history "index_updates" in
      let* digest_commits = required_nonnegative_int_field history "digest_commits" in
      let* missing_evidence = required_nonnegative_int_field history "missing_evidence" in
      let* retained_from_seq = optional_int_field history "retained_from_seq" in
      Ok (Some { edge_changes; index_updates; digest_commits; missing_evidence; retained_from_seq })

let decode_memory_diff json =
  let* _, body = unwrap_v2_or_raw json in
  let* scope_obj = required_object_field body "scope" in
  let* scope_kind = required_nonblank_string scope_obj "kind" in
  let* scope =
    match scope_kind with
    | "world" -> Ok Scope_world
    | "keeper" ->
        let* keeper = required_nonblank_string scope_obj "keeper" in
        Ok (Scope_keeper keeper)
    | other -> Error (Printf.sprintf "unknown memory diff scope %S" other)
  in
  let* range_obj = required_object_field body "range" in
  let* range = decode_diff_range range_obj in
  let* heat_obj = required_object_field body "retrieval_heat" in
  let* retrieval_heat = decode_retrieval_heat heat_obj in
  let* counts_obj = required_object_field body "counts" in
  let* diff_body =
    match scope with
    | Scope_keeper _ ->
        let* total_facts_now =
          required_nonnegative_int_field counts_obj "total_facts_now"
        in
        let* added_c = required_nonnegative_int_field counts_obj "added" in
        let* updated_c = required_nonnegative_int_field counts_obj "updated" in
        let* retracted_c =
          required_nonnegative_int_field counts_obj "retracted"
        in
        let* invalidated_c =
          required_nonnegative_int_field counts_obj "invalidated"
        in
        let* journal_failures_in_window =
          required_nonnegative_int_field counts_obj "journal_failures_in_window"
        in
        let* journal_quarantines_in_window =
          required_nonnegative_int_field counts_obj
            "journal_quarantines_in_window"
        in
        let* history_coverage = decode_keeper_history_coverage body in
        let* undecodable_journal_lines =
          required_nonnegative_int_field counts_obj "undecodable_journal_lines"
        in
        let* rev_items = required_list_field body "revisions" in
        let* revisions =
          decode_list "revisions" decode_revision_tick rev_items
        in
        let* added_items = required_list_field body "added" in
        let* added = decode_list "added" decode_fact_entry added_items in
        let* updated_items = required_list_field body "updated" in
        let* updated = decode_list "updated" decode_updated_fact updated_items in
        let* retracted_items = required_list_field body "retracted" in
        let* retracted =
          decode_list "retracted" decode_retracted_fact retracted_items
        in
        let* inv_items = required_list_field body "invalidated" in
        let* invalidated =
          decode_list "invalidated" decode_invalidated_fact inv_items
        in
        let* writer_status =
          match optional_object_field body "writer_status" with
          | Ok None -> Ok None
          | Ok (Some ws) ->
              let* decoded = decode_keeper_writer_status ws in
              Ok (Some decoded)
          | Error _ as err -> err
        in
        Ok
          (Keeper_diff
             {
               counts =
                 {
                   total_facts_now;
                   added = added_c;
                   updated = updated_c;
                   retracted = retracted_c;
                   invalidated = invalidated_c;
                   journal_failures_in_window;
                   journal_quarantines_in_window;
                   undecodable_journal_lines;
                   history_coverage;
                 };
               revisions;
               added;
               updated;
               retracted;
               invalidated;
               writer_status;
             })
    | Scope_world ->
        let* history = decode_world_change_history body in
        let* total_claims_now =
          required_nonnegative_int_field counts_obj "total_claims_now"
        in
        let* added_c = required_nonnegative_int_field counts_obj "added" in
        let* updated_c = required_nonnegative_int_field counts_obj "updated" in
        let* retracted_c =
          required_nonnegative_int_field counts_obj "retracted"
        in
        let* incomplete_batches =
          required_nonnegative_int_field counts_obj "incomplete_batches"
        in
        let* aborted_batches =
          required_nonnegative_int_field counts_obj "aborted_batches"
        in
        let* unparseable_timestamps =
          int_field_or body "unparseable_timestamps" ~default:0
        in
        let* rev_items = required_list_field body "revisions" in
        let* revisions =
          decode_list "revisions" decode_world_revision_tick rev_items
        in
        let* added_items = required_list_field body "added" in
        let* added = decode_list "added" decode_world_change_entry added_items in
        let* updated_items = required_list_field body "updated" in
        let* updated =
          decode_list "updated" decode_world_updated_entry updated_items
        in
        let* retracted_items = required_list_field body "retracted" in
        let* retracted =
          decode_list "retracted" decode_world_change_entry retracted_items
        in
        Ok
          (World_diff
             {
               counts =
                 {
                   total_claims_now;
                   added = added_c;
                   updated = updated_c;
                   retracted = retracted_c;
                   incomplete_batches;
                   aborted_batches;
                 };
               history;
               unparseable_timestamps;
               revisions;
               added;
               updated;
               retracted;
             })
  in
  Ok { scope; range; retrieval_heat; body = diff_body }

let encode_memory_act_request = function
  | Act_resume -> `Assoc [ ("action", `String "resume") ]
  | Act_adopt { observed } ->
      `Assoc [ ("action", `String "adopt"); ("observed", `String observed) ]
  | Act_restart_reading { observed } ->
      `Assoc
        [
          ("action", `String "restart_reading"); ("observed", `String observed);
        ]
  | Act_skip_item { turn_log; line } ->
      `Assoc
        [
          ("action", `String "skip_item");
          ( "target"
          , `Assoc
              [
                ("kind", `String "unreadable_unit");
                ("turn_log", `String turn_log);
                ("line", `Int line);
              ] );
        ]
  | Act_skip_line { offset } ->
      (* [server_dashboard_http_keeper_memory_act.ml] parses integer ["offset"]. *)
      `Assoc [ ("action", `String "skip_line"); ("offset", `Int offset) ]

let decode_memory_act_answer ~status_code json =
  match status_code with
  | 200 ->
      let* st = decode_writer_state_string json "store" in
      Ok (Memory_act_done st)
  | 409 ->
      let* code = required_nonblank_string json "code" in
      let* detail = optional_nonblank_string json "stopped" in
      Ok (Memory_act_refused { code; detail })
  | 400 ->
      let* msg = required_nonblank_string json "error" in
      Ok (Memory_act_invalid msg)
  | 503 -> Ok Memory_act_no_writer
  | other ->
      Error
        (Printf.sprintf "unexpected status code %d for keeper memory act" other)

type compaction_internals = {
  present : bool;
  epoch_count : int;
  archived_turns_count : int;
  anchor_bytes : int;
  latest_epoch_id : int option;
  covers_through_turn : string option;
  archived_epochs_through : int option;
  observations_count : int option;
  read_error : string option;
}

type canonical_turns_internals = {
  present : bool;
  turn_count : int;
  latest_turn_id : string option;
  latest_runtime_kind : string option;
  latest_runtime_id : string option;
  compaction_watermark_seq : int option;
  compaction_watermark_epoch : int option;
  history_resets_count : int;
  latest_reset_at_unix : float option;
  read_error : string option;
}

type memory_digest_internals = {
  present : bool;
  revision : int option;
  digest_sha256 : string option;
  bytes : int;
  fact_count : int;
  derived_count : int;
}

type librarian_molt_internals = {
  writer_kind : string;
  writer_state : string option;
  pending_molt_kind : string option;
  pending_molt_categories : string list;
  available_act_tokens : string list;
}

type memory_os_internals = {
  keeper : string;
  compaction : compaction_internals;
  canonical_turns : canonical_turns_internals;
  memory_digest : memory_digest_internals;
  librarian_molt : librarian_molt_internals;
}

let decode_memory_os_internals json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* comp_obj = required_object_field body "compaction" in
  let* comp_present = required_bool_field comp_obj "present" in
  let* epoch_count = required_nonnegative_int_field comp_obj "epoch_count" in
  let* archived_turns_count =
    required_nonnegative_int_field comp_obj "archived_turns_count"
  in
  let* anchor_bytes = required_nonnegative_int_field comp_obj "anchor_bytes" in
  let* latest_epoch_id = optional_int_field comp_obj "latest_epoch_id" in
  let* covers_through_turn =
    optional_nonblank_string comp_obj "covers_through_turn"
  in
  let* archived_epochs_through =
    optional_int_field comp_obj "archived_epochs_through"
  in
  let* observations_count = optional_nonnegative_count_field comp_obj "observations_count" in
  let* comp_read_error = optional_nonblank_string comp_obj "read_error" in
  let* turns_obj = required_object_field body "canonical_turns" in
  let* turns_present = required_bool_field turns_obj "present" in
  let* turn_count = required_nonnegative_int_field turns_obj "turn_count" in
  let* latest_turn_id = optional_nonblank_string turns_obj "latest_turn_id" in
  let* latest_runtime_kind =
    optional_nonblank_string turns_obj "latest_runtime_kind"
  in
  let* latest_runtime_id =
    optional_nonblank_string turns_obj "latest_runtime_id"
  in
  let* compaction_watermark_seq =
    optional_int_field turns_obj "compaction_watermark_seq"
  in
  let* compaction_watermark_epoch =
    optional_int_field turns_obj "compaction_watermark_epoch"
  in
  let* history_resets_count =
    optional_nonnegative_count turns_obj "history_resets_count"
  in
  let* latest_reset_at_unix =
    decode_optional_timestamp_unix turns_obj "latest_reset_at"
  in
  let* turns_read_error = optional_nonblank_string turns_obj "read_error" in
  let* dig_obj = required_object_field body "memory_digest" in
  let* dig_present = required_bool_field dig_obj "present" in
  let* revision = optional_int_field dig_obj "revision" in
  let* digest_sha256 = optional_nonblank_string dig_obj "digest_sha256" in
  let* bytes = optional_nonnegative_count dig_obj "bytes" in
  let* fact_count = optional_nonnegative_count dig_obj "fact_count" in
  let* derived_count = optional_nonnegative_count dig_obj "derived_count" in
  let* molt_obj = required_object_field body "librarian_molt" in
  let* writer_kind = required_nonblank_string molt_obj "writer_kind" in
  let* writer_state = optional_nonblank_string molt_obj "writer_state" in
  let* pending_molt_kind =
    match optional_object_field molt_obj "pending_molt" with
    | Ok None -> Ok None
    | Ok (Some pm) -> (
        match optional_nonblank_string pm "kind" with
        | Ok (Some k) -> Ok (Some k)
        | Ok None -> Ok (Some "pending")
        | Error _ as err -> err)
    | Error _ -> optional_nonblank_string molt_obj "pending_molt"
  in
  let* pending_molt_categories =
    optional_string_list molt_obj "pending_molt_categories"
  in
  let* available_act_tokens = optional_string_list molt_obj "available_acts" in
  Ok
    {
      keeper;
      compaction =
        {
          present = comp_present;
          epoch_count;
          archived_turns_count;
          anchor_bytes;
          latest_epoch_id;
          covers_through_turn;
          archived_epochs_through;
          observations_count;
          read_error = comp_read_error;
        };
      canonical_turns =
        {
          present = turns_present;
          turn_count;
          latest_turn_id;
          latest_runtime_kind;
          latest_runtime_id;
          compaction_watermark_seq;
          compaction_watermark_epoch;
          history_resets_count;
          latest_reset_at_unix;
          read_error = turns_read_error;
        };
      memory_digest =
        {
          present = dig_present;
          revision;
          digest_sha256;
          bytes;
          fact_count;
          derived_count;
        };
      librarian_molt =
        {
          writer_kind;
          writer_state;
          pending_molt_kind;
          pending_molt_categories;
          available_act_tokens;
        };
    }
(* {1 Per-Keeper Memory Facts ([/api/v1/keepers/:name/memory-facts])} *)

type memory_fact_category =
  | Cat_code_change
  | Cat_fact
  | Cat_preference
  | Cat_blocker
  | Cat_goal
  | Cat_constraint
  | Cat_validated_approach
  | Cat_lesson
  | Cat_custom of string

type memory_fact_origin =
  | Origin_authored
  | Origin_injected

type memory_board_ref = {
  post_id : string;
  comment_id : string option;
}

type memory_derivation_ref = {
  rule_id : string;
  premise_ids : string list;
}

type memory_fact_basis =
  | Basis_observed
  | Basis_observed_board of memory_board_ref
  | Basis_derived of memory_derivation_ref list

type memory_retrieval_state =
  | Never_retrieved
  | Retrieved of {
      count : int;
      distinct_days : int;
      last_at_unix : float;
    }

type memory_fact_events = {
  retrieval : memory_retrieval_state;
  retracted_count : int;
  revised_from : string list;
}

type keeper_ordinary_fact = {
  memory_id : string;
  claim : string;
  category : memory_fact_category;
  origin : memory_fact_origin;
  basis : memory_fact_basis;
  first_seen_unix : float;
  last_seen_unix : float;
  events : memory_fact_events;
}

type keeper_support_invalidation = {
  memory_id : string;
  claim : string;
  basis : memory_fact_basis;
  missing_premise_ids : string list;
}

type keeper_ordinary_memory = {
  revision : int;
  snapshot_sha256 : string;
  updated_at_unix : float;
  facts : keeper_ordinary_fact list;
  support_invalidations : keeper_support_invalidation list;
}

type keeper_source_fact = {
  claim : string;
  first_seen_unix : float;
  path : string;
  sha256 : string;
}

type source_invalidation_reason =
  | Source_changed
  | Source_unavailable

type keeper_source_invalidation = {
  source_path : string;
  invalidated_at_unix : float;
  reason : source_invalidation_reason;
}

type keeper_source_memory = {
  revision : int;
  updated_at_unix : float;
  facts : keeper_source_fact list;
  invalidations : keeper_source_invalidation list;
}

type 'a memory_store_state =
  | Memory_store_read_error of string
  | Memory_store_absent
  | Memory_store_present of 'a

type keeper_memory_facts = {
  keeper : string;
  ordinary : keeper_ordinary_memory memory_store_state;
  source_bound : keeper_source_memory memory_store_state;
  events_unreadable_lines : int;
  events_read_error : string option;
}

let memory_fact_category_to_string = function
  | Cat_code_change -> "code_change"
  | Cat_fact -> "fact"
  | Cat_preference -> "preference"
  | Cat_blocker -> "blocker"
  | Cat_goal -> "goal"
  | Cat_constraint -> "constraint"
  | Cat_validated_approach -> "validated_approach"
  | Cat_lesson -> "lesson"
  | Cat_custom s -> s

let memory_fact_origin_to_string = function
  | Origin_authored -> "authored"
  | Origin_injected -> "injected"

let source_invalidation_reason_to_string = function
  | Source_changed -> "source_changed"
  | Source_unavailable -> "source_unavailable"

let is_valid_custom_category raw =
  let letter = function 'a' .. 'z' -> true | _ -> false in
  let word_char c = letter c || (c >= '0' && c <= '9') in
  let len = String.length raw in
  let rec valid i after_sep =
    if i = len then not after_sep
    else if word_char raw.[i] then valid (i + 1) false
    else if raw.[i] = '_' && not after_sep then valid (i + 1) true
    else false
  in
  len > 0 && letter raw.[0] && valid 1 false

let decode_memory_fact_category raw =
  match raw with
  | "code_change" -> Ok Cat_code_change
  | "fact" -> Ok Cat_fact
  | "preference" -> Ok Cat_preference
  | "blocker" -> Ok Cat_blocker
  | "goal" -> Ok Cat_goal
  | "constraint" -> Ok Cat_constraint
  | "validated_approach" -> Ok Cat_validated_approach
  | "lesson" -> Ok Cat_lesson
  | "all" | "source" | "dropped" ->
      Error (Printf.sprintf "forbidden fact category %S" raw)
  | other ->
      if is_valid_custom_category other then Ok (Cat_custom other)
      else Error (Printf.sprintf "invalid fact category %S" other)

let memory_fact_origin_of_string = function
  | "authored" -> Some Origin_authored
  | "injected" -> Some Origin_injected
  | _ -> None

let source_invalidation_reason_of_string = function
  | "source_changed" -> Some Source_changed
  | "source_unavailable" -> Some Source_unavailable
  | _ -> None

let decode_nonblank_string_list json key =
  let* raw_items = required_list_field json key in
  decode_list key
    (function
      | `String s ->
          if String.equal (String.trim s) "" then
            Error (Printf.sprintf "field %S contains blank string" key)
          else Ok s
      | other -> field_type_error key "non-blank string" other)
    raw_items

let decode_derivation_ref json =
  let* rule_id = required_nonblank_string json "rule_id" in
  let* premise_ids = decode_nonblank_string_list json "premise_ids" in
  if premise_ids = [] then
    Error "field \"premise_ids\" must not be empty"
  else Ok { rule_id; premise_ids }

let decode_memory_fact_basis json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "observed" -> (
      match optional_object_field json "board" with
      | Error _ as err -> err
      | Ok None -> Ok Basis_observed
      | Ok (Some board_obj) ->
          let* post_id = required_nonblank_string board_obj "post_id" in
          let* comment_id = optional_nonblank_string board_obj "comment_id" in
          Ok (Basis_observed_board { post_id; comment_id }))
  | "derived" ->
      let* raw_derivs = required_list_field json "derivations" in
      let* derivs =
        decode_list "basis.derivations" decode_derivation_ref raw_derivs
      in
      if derivs = [] then Error "basis.derivations must not be empty"
      else Ok (Basis_derived derivs)
  | other -> Error (Printf.sprintf "unknown memory fact basis kind %S" other)

let decode_memory_fact_events json =
  let* retrieved_count =
    required_nonnegative_int_field json "retrieved_count"
  in
  let* retrieved_distinct_days =
    required_nonnegative_int_field json "retrieved_distinct_days"
  in
  let* last_retrieved_at =
    required_nullable_float_field json "last_retrieved_at"
  in
  let* retracted_count =
    required_nonnegative_int_field json "retracted_count"
  in
  let* revised_from = required_string_list json "revised_from" in
  let* retrieval =
    match retrieved_count, retrieved_distinct_days, last_retrieved_at with
    | 0, 0, None -> Ok Never_retrieved
    | c, d, Some t when c > 0 && d > 0 && d <= c && Float.is_finite t ->
        Ok (Retrieved { count = c; distinct_days = d; last_at_unix = t })
    | _ ->
        Error
          (Printf.sprintf
             "inconsistent retrieval events (count=%d, distinct_days=%d, \
              has_last=%b)"
             retrieved_count retrieved_distinct_days
             (Option.is_some last_retrieved_at))
  in
  Ok { retrieval; retracted_count; revised_from }

let decode_keeper_ordinary_fact json =
  let* memory_id = required_nonblank_string json "memory_id" in
  let* claim = required_nonblank_string json "claim" in
  let* cat_raw = required_nonblank_string json "category" in
  let* category = decode_memory_fact_category cat_raw in
  let* origin =
    decode_enum ~field:"origin" memory_fact_origin_of_string json
  in
  let* first_seen_unix = required_finite_float json "first_seen" in
  let* last_seen_unix = required_finite_float json "last_seen" in
  let* basis_obj = required_object_field json "basis" in
  let* basis = decode_memory_fact_basis basis_obj in
  let* events_obj = required_object_field json "events" in
  let* events = decode_memory_fact_events events_obj in
  Ok
    {
      memory_id;
      claim;
      category;
      origin;
      basis;
      first_seen_unix;
      last_seen_unix;
      events;
    }

let decode_keeper_support_invalidation json =
  let* memory_id = required_nonblank_string json "memory_id" in
  let* claim = required_nonblank_string json "claim" in
  let* basis_obj = required_object_field json "basis" in
  let* basis = decode_memory_fact_basis basis_obj in
  let* missing_premise_ids =
    decode_nonblank_string_list json "missing_premise_ids"
  in
  if missing_premise_ids = [] then
    Error "field \"missing_premise_ids\" must not be empty"
  else Ok { memory_id; claim; basis; missing_premise_ids }

let decode_ordinary_memory_state json =
  if has_field json "read_error" then
    let* err_msg = required_nonblank_string json "read_error" in
    Ok (Memory_store_read_error err_msg)
  else
    let* present = required_bool_field json "present" in
    if not present then Ok Memory_store_absent
    else
      let* revision = required_nonnegative_int_field json "revision" in
      let* snapshot_sha256 = required_nonblank_string json "snapshot_sha256" in
      let* updated_at_unix = required_finite_float json "updated_at" in
      let* raw_facts = required_list_field json "facts" in
      let* facts =
        decode_list "ordinary.facts" decode_keeper_ordinary_fact raw_facts
      in
      let* raw_invs = required_list_field json "support_invalidations" in
      let* support_invalidations =
        decode_list "ordinary.support_invalidations"
          decode_keeper_support_invalidation raw_invs
      in
      Ok
        (Memory_store_present
           {
             revision;
             snapshot_sha256;
             updated_at_unix;
             facts;
             support_invalidations;
           })

let decode_keeper_source_fact json =
  let* claim = required_nonblank_string json "claim" in
  let* first_seen_unix = required_finite_float json "first_seen" in
  let* path = required_nonblank_string json "path" in
  let* sha256 = required_nonblank_string json "sha256" in
  Ok { claim; first_seen_unix; path; sha256 }

let decode_keeper_source_invalidation json =
  let* source_path = required_nonblank_string json "source_path" in
  let* invalidated_at_unix = required_finite_float json "invalidated_at" in
  let* reason =
    decode_enum ~field:"reason" source_invalidation_reason_of_string json
  in
  Ok { source_path; invalidated_at_unix; reason }

let decode_source_memory_state json =
  if has_field json "read_error" then
    let* err_msg = required_nonblank_string json "read_error" in
    Ok (Memory_store_read_error err_msg)
  else
    let* present = required_bool_field json "present" in
    if not present then Ok Memory_store_absent
    else
      let* revision = required_nonnegative_int_field json "revision" in
      let* updated_at_unix = required_finite_float json "updated_at" in
      let* raw_facts = required_list_field json "facts" in
      let* facts =
        decode_list "source_bound.facts" decode_keeper_source_fact raw_facts
      in
      let* raw_invs = required_list_field json "invalidations" in
      let* invalidations =
        decode_list "source_bound.invalidations"
          decode_keeper_source_invalidation raw_invs
      in
      Ok (Memory_store_present { revision; updated_at_unix; facts; invalidations })

let decode_keeper_memory_facts json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* ord_obj = required_object_field body "ordinary" in
  let* ordinary = decode_ordinary_memory_state ord_obj in
  let* src_obj = required_object_field body "source_bound" in
  let* source_bound = decode_source_memory_state src_obj in
  let* events_unreadable_lines =
    required_nonnegative_int_field body "events_unreadable_lines"
  in
  let* events_read_error =
    required_nullable_nonblank_string_field body "events_read_error"
  in
  Ok
    {
      keeper;
      ordinary;
      source_bound;
      events_unreadable_lines;
      events_read_error;
    }

(* {1 Per-Keeper Memory Evolution / Activity ([/api/v1/keepers/:name/memory-journal?activity=1])} *)

type memory_activity_kind =
  | Activity_created
  | Activity_reobserved
  | Activity_revised
  | Activity_absorbed
  | Activity_retracted
  | Activity_removed
  | Activity_invalidated
  | Activity_relation_unavailable

type memory_activity_fact = {
  memory_id : string;
  claim : string option;
}

type memory_activity_event = {
  identity : string;
  recorded_at_unix : float;
  revision : int;
  kind : memory_activity_kind;
  before : memory_activity_fact list;
  after : memory_activity_fact list;
  reason : string option;
}

type keeper_memory_activity = {
  keeper : string;
  limit : int;
  journal_lines : int;
  undecodable_lines : int;
  events : memory_activity_event list;
  notes : string list;
}

let memory_activity_kind_rank = function
  | Activity_created -> 0
  | Activity_reobserved -> 1
  | Activity_revised -> 2
  | Activity_absorbed -> 3
  | Activity_retracted -> 4
  | Activity_removed -> 5
  | Activity_invalidated -> 6
  | Activity_relation_unavailable -> 7

let equal_memory_activity_kind a b =
  Int.equal (memory_activity_kind_rank a) (memory_activity_kind_rank b)

let memory_activity_kind_to_string = function
  | Activity_created -> "created"
  | Activity_reobserved -> "reobserved"
  | Activity_revised -> "revised"
  | Activity_absorbed -> "absorbed"
  | Activity_retracted -> "retracted"
  | Activity_removed -> "removed"
  | Activity_invalidated -> "invalidated"
  | Activity_relation_unavailable -> "relation_unavailable"

let memory_activity_kind_of_string = function
  | "created" -> Some Activity_created
  | "reobserved" -> Some Activity_reobserved
  | "revised" -> Some Activity_revised
  | "absorbed" -> Some Activity_absorbed
  | "retracted" -> Some Activity_retracted
  | "removed" -> Some Activity_removed
  | "invalidated" -> Some Activity_invalidated
  | "relation_unavailable" -> Some Activity_relation_unavailable
  | _ -> None

let decode_memory_activity_fact json =
  let* memory_id = required_nonblank_string json "memory_id" in
  let* claim = required_nullable_nonblank_string_field json "claim" in
  Ok { memory_id; claim }

let validate_activity_event_shape (ev : memory_activity_event) =
  let complete facts =
    List.for_all
      (fun (f : memory_activity_fact) -> Option.is_some f.claim)
      facts
  in
  let has_before = ev.before <> [] in
  let has_after = ev.after <> [] in
  let has_reason =
    match ev.reason with
    | Some r -> not (String.equal (String.trim r) "")
    | None -> false
  in
  match ev.kind with
  | Activity_created ->
      if (not has_before) && has_after && complete ev.after then Ok ()
      else
        Error
          "created activity event requires empty before and non-empty complete \
           after"
  | Activity_reobserved | Activity_revised | Activity_absorbed ->
      if has_before && has_after && complete ev.before && complete ev.after then
        Ok ()
      else
        Error
          (Printf.sprintf
             "%s activity event requires non-empty complete before and after"
             (memory_activity_kind_to_string ev.kind))
  | Activity_retracted | Activity_removed | Activity_invalidated ->
      if has_before && (not has_after) && complete ev.before then Ok ()
      else
        Error
          (Printf.sprintf
             "%s activity event requires non-empty complete before and empty \
              after"
             (memory_activity_kind_to_string ev.kind))
  | Activity_relation_unavailable ->
      if has_before && complete ev.before && has_reason then Ok ()
      else
        Error
          "relation_unavailable activity event requires non-empty complete \
           before and a non-blank reason"

let decode_memory_activity_event json =
  let* identity = required_nonblank_string json "identity" in
  let* recorded_at_unix = decode_timestamp_unix json "recorded_at" in
  let* () =
    if Float.is_finite recorded_at_unix && recorded_at_unix >= 0.0 then Ok ()
    else
      Error
        (Printf.sprintf "field \"recorded_at\" must be finite and >= 0, got %g"
           recorded_at_unix)
  in
  let* revision = required_nonnegative_int_field json "revision" in
  let* kind = decode_enum ~field:"kind" memory_activity_kind_of_string json in
  let* raw_before = required_list_field json "before" in
  let* before = decode_list "before" decode_memory_activity_fact raw_before in
  let* raw_after = required_list_field json "after" in
  let* after = decode_list "after" decode_memory_activity_fact raw_after in
  let* reason = required_nullable_nonblank_string_field json "reason" in
  let ev =
    { identity; recorded_at_unix; revision; kind; before; after; reason }
  in
  let* () = validate_activity_event_shape ev in
  Ok ev

let ensure_unique_activity_identities events =
  let seen = Hashtbl.create (max 16 (List.length events)) in
  let rec loop = function
    | [] -> Ok ()
    | (ev : memory_activity_event) :: rest ->
        if Hashtbl.mem seen ev.identity then
          Error (Printf.sprintf "duplicate activity event identity %S" ev.identity)
        else begin
          Hashtbl.add seen ev.identity ();
          loop rest
        end
  in
  loop events

let decode_keeper_memory_activity json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* undecodable_lines =
    required_nonnegative_int_field body "undecodable_lines"
  in
  let* act_obj = required_object_field body "activity" in
  let* limit = required_int_field act_obj "limit" in
  let* () =
    if limit > 0 then Ok ()
    else Error (Printf.sprintf "activity.limit must be > 0, got %d" limit)
  in
  let* journal_lines = required_nonnegative_int_field act_obj "journal_lines" in
  let* () =
    if journal_lines <= limit then Ok ()
    else
      Error
        (Printf.sprintf "activity.journal_lines (%d) exceeds activity.limit (%d)"
           journal_lines limit)
  in
  let* raw_events = required_list_field act_obj "events" in
  let* events =
    decode_list "activity.events" decode_memory_activity_event raw_events
  in
  let* () = ensure_unique_activity_identities events in
  let* notes = required_string_list act_obj "notes" in
  Ok { keeper; limit; journal_lines; undecodable_lines; events; notes }

(* {1 Fleet Keeper Memory Health ([/api/v1/dashboard/keeper-memory-health])} *)

type memory_health_alert_severity =
  | Alert_warn
  | Alert_error

type memory_health_alert = {
  code : string;
  severity : memory_health_alert_severity;
  target : string;
  label : string;
  message : string;
}

type keeper_memory_health_row = {
  keeper_id : string;
  revision : int;
  updated_at_unix : float option;
  facts : int;
  observed_facts : int;
  derived_facts : int;
  support_invalidations : int;
  snapshot_bytes : int;
  added : int;
  removed : int;
  snapshot_present : bool;
  age_bins : int array option;
  facts_by_hour : (float * int) list;
  librarian_failures : int;
  vision_ingest_errors : int;
  read_error : string option;
  source_revision : int;
  source_facts : int;
  source_invalidations : int;
  source_snapshot_bytes : int;
  source_snapshot_present : bool;
  source_read_error : string option;
  alerts : memory_health_alert list;
}

type keeper_memory_health_fleet = {
  schema : string;
  generated_at_unix : float;
  keepers : keeper_memory_health_row list;
}

let memory_health_alert_severity_of_string = function
  | "warn" -> Some Alert_warn
  | "error" -> Some Alert_error
  | _ -> None

let decode_memory_health_alert json =
  let* code = required_nonblank_string json "code" in
  let* severity =
    decode_enum ~field:"severity" memory_health_alert_severity_of_string json
  in
  let* target = required_nonblank_string json "target" in
  let* label = required_string_field json "label" in
  let* message = required_string_field json "message" in
  Ok { code; severity; target; label; message }

let decode_age_bins_opt json =
  let* raw = required_member json "age_bins" in
  match raw with
  | `Null -> Ok None
  | `List xs ->
      if List.length xs <> 24 then
        Error
          (Printf.sprintf "field \"age_bins\" must have 24 bins, got %d"
             (List.length xs))
      else
        let* vals =
          decode_list "age_bins"
            (function
              | `Int n when n >= 0 -> Ok n
              | `Int n ->
                  Error (Printf.sprintf "age_bins entry must be >= 0, got %d" n)
              | other -> field_type_error "age_bins" "non-negative int" other)
            xs
        in
        Ok (Some (Array.of_list vals))
  | other -> field_type_error "age_bins" "array of 24 ints or null" other

let decode_facts_by_hour_point json =
  let* recorded_at = required_finite_float json "recorded_at" in
  let* facts = required_nonnegative_int_field json "facts" in
  Ok (recorded_at, facts)

let decode_keeper_memory_health_row json =
  let* keeper_id = required_nonblank_string json "keeper_id" in
  let* revision = required_nonnegative_int_field json "revision" in
  let* updated_at_unix = required_nullable_float_field json "updated_at" in
  let* () =
    match updated_at_unix with
    | Some t when not (Float.is_finite t) ->
        Error "field \"updated_at\" must be finite"
    | Some _ | None -> Ok ()
  in
  let* facts = required_nonnegative_int_field json "facts" in
  let* observed_facts = required_nonnegative_int_field json "observed_facts" in
  let* derived_facts = required_nonnegative_int_field json "derived_facts" in
  let* support_invalidations =
    required_nonnegative_int_field json "support_invalidations"
  in
  let* snapshot_bytes = required_nonnegative_int_field json "snapshot_bytes" in
  let* added = required_nonnegative_int_field json "added" in
  let* removed = required_nonnegative_int_field json "removed" in
  let* snapshot_present = required_bool_field json "snapshot_present" in
  let* age_bins = decode_age_bins_opt json in
  let* raw_fbh = required_list_field json "facts_by_hour" in
  let* facts_by_hour =
    decode_list "facts_by_hour" decode_facts_by_hour_point raw_fbh
  in
  let* librarian_failures =
    required_nonnegative_int_field json "librarian_failures"
  in
  let* vision_ingest_errors =
    required_nonnegative_int_field json "vision_ingest_errors"
  in
  let* read_error = required_nullable_nonblank_string_field json "read_error" in
  let* source_revision = required_nonnegative_int_field json "source_revision" in
  let* source_facts = required_nonnegative_int_field json "source_facts" in
  let* source_invalidations =
    required_nonnegative_int_field json "source_invalidations"
  in
  let* source_snapshot_bytes =
    required_nonnegative_int_field json "source_snapshot_bytes"
  in
  let* source_snapshot_present =
    required_bool_field json "source_snapshot_present"
  in
  let* source_read_error =
    required_nullable_nonblank_string_field json "source_read_error"
  in
  let* raw_alerts = required_list_field json "alerts" in
  let* alerts = decode_list "alerts" decode_memory_health_alert raw_alerts in
  Ok
    {
      keeper_id;
      revision;
      updated_at_unix;
      facts;
      observed_facts;
      derived_facts;
      support_invalidations;
      snapshot_bytes;
      added;
      removed;
      snapshot_present;
      age_bins;
      facts_by_hour;
      librarian_failures;
      vision_ingest_errors;
      read_error;
      source_revision;
      source_facts;
      source_invalidations;
      source_snapshot_bytes;
      source_snapshot_present;
      source_read_error;
      alerts;
    }

let memory_health_alert_severity_to_string = function
  | Alert_warn -> "warn"
  | Alert_error -> "error"

let memory_health_fleet_totals (fleet : keeper_memory_health_fleet) =
  List.fold_left
    (fun (tf, ti, ta, tw, te) (row : keeper_memory_health_row) ->
      let w, e =
        List.fold_left
          (fun (w, e) (al : memory_health_alert) ->
            match al.severity with
            | Alert_warn -> (w + 1, e)
            | Alert_error -> (w, e + 1))
          (0, 0) row.alerts
      in
      ( tf + row.facts
      , ti + row.support_invalidations
      , ta + List.length row.alerts
      , tw + w
      , te + e ))
    (0, 0, 0, 0, 0) fleet.keepers

let decode_keeper_memory_health_fleet json =
  let* _, body = unwrap_v2_or_raw json in
  let* schema = required_nonblank_string body "schema" in
  let* () =
    if String.equal schema "keeper.memory_os.current_health.v19" then Ok ()
    else
      Error
        (Printf.sprintf
           "unsupported keeper memory health schema %S (expected \
            \"keeper.memory_os.current_health.v19\")"
           schema)
  in
  let* generated_at_unix = required_finite_float body "generated_at" in
  let* keepers =
    if has_field body "keepers" then
      let* raw_rows = required_list_field body "keepers" in
      decode_list "keepers" decode_keeper_memory_health_row raw_rows
    else if has_field body "keeper" then
      match required_member body "keeper" with
      | Error _ as err -> err
      | Ok `Null -> Ok []
      | Ok row_json ->
          let* row = decode_keeper_memory_health_row row_json in
          Ok [ row ]
    else missing_field "keepers"
  in
  Ok { schema; generated_at_unix; keepers }

(* [PUT /api/v1/wiki/:slug] answers in the v2 envelope with the action it
   took, the revision it wrote, and the journal or index writes that failed
   after the page itself was saved ([put_page_json] in
   server_dashboard_http_wiki.ml). It carries no rendered page. *)
type wiki_put_action =
  | Wiki_page_created
  | Wiki_page_updated

type wiki_put_result = {
  action : wiki_put_action;
  revision : int;
  warnings : string list;
}

let wiki_put_action_of_string = function
  | "created" -> Some Wiki_page_created
  | "updated" -> Some Wiki_page_updated
  | _ -> None

let decode_wiki_put_result json =
  let* _, body = unwrap_v2_or_raw json in
  let* action = decode_enum ~field:"action" wiki_put_action_of_string body in
  let* revision = required_nonnegative_int_field body "revision" in
  let* warnings = required_string_list body "warnings" in
  Ok { action; revision; warnings }

let decode_keeper_memory_health_single json =
  let* fleet = decode_keeper_memory_health_fleet json in
  Ok (List.nth_opt fleet.keepers 0)

(* --- Workspace Memory Ledger, Context & Keeper Journal --- *)

let workspace_memory_ledger_path = "/api/v1/dashboard/workspace-memory-ledger"
let workspace_memory_context_path = "/api/v1/dashboard/workspace-memory-context"

let keeper_memory_journal_path ~keeper ?(limit = 50) ?(activity = true) () =
  Printf.sprintf "/api/v1/keepers/%s/memory-journal?limit=%d%s"
    (percent_encode keeper) (max 1 limit)
    (if activity then "&activity=1" else "")

type workspace_ledger_fact = {
  claim_text : string option;
  disposition_kind : string;
  disposition_detail : string option;
  source_state : string;
}

type workspace_memory_ledger = {
  status : string;
  ledger_sha256 : string option;
  claims : (string * string) list;
  conflicts : (string * string) list;
  facts : workspace_ledger_fact list;
}

type workspace_context_obs =
  | Ctx_missing
  | Ctx_unavailable of string
  | Ctx_available of { revision : int option; fact_count : int }

type workspace_context_keeper = {
  keeper_id : string;
  ordinary : workspace_context_obs;
  source_bound : workspace_context_obs;
}

type workspace_memory_context = {
  generated_at : float;
  discovery_status : string;
  discovery_detail : string option;
  keepers : workspace_context_keeper list;
}

type memory_journal_entry = {
  structural_id : string;
  ok : bool;
  outcome : string option;
  recorded_at : float option;
  revision : int option;
  source_kind : string option;
  added : int;
  removed : int;
  retained : int;
  invalidated : int;
  error : string option;
}

type journal_activity_event = {
  identity : string;
  recorded_at : float;
  revision : int;
  kind : string;
  before_claims : string list;
  after_claims : string list;
  reason : string option;
}

type keeper_memory_journal = {
  keeper : string;
  returned : int;
  undecodable_lines : int;
  entries : memory_journal_entry list;
  activity_events : journal_activity_event list;
  activity_notes : string list;
}

let int_or_zero_k json key =
  match optional_int_field json key with
  | Ok (Some v) -> v
  | Ok None | Error _ -> 0

let float_or_zero_k json key =
  match optional_finite_float json key with
  | Ok (Some v) -> v
  | Ok None | Error _ -> 0.0

let decode_workspace_ledger_fact json =
  let* claim_text = optional_nonblank_string json "current_claim" in
  let source_state =
    match optional_nonblank_string json "source_state" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "present"
  in
  let disposition_kind, disposition_detail =
    match optional_object_field json "disposition" with
    | Ok (Some d) ->
        let k =
          match optional_nonblank_string d "kind" with
          | Ok (Some s) -> s
          | Ok None | Error _ -> "claim"
        in
        let detail =
          match optional_nonblank_string d "claim_id" with
          | Ok (Some s) -> Some s
          | Ok None | Error _ -> (
              match optional_nonblank_string d "conflict_id" with
              | Ok (Some s) -> Some s
              | Ok None | Error _ -> (
                  match optional_nonblank_string d "reason" with
                  | Ok v -> v
                  | Error _ -> None))
        in
        (k, detail)
    | Ok None | Error _ -> ("unknown", None)
  in
  Ok { claim_text; disposition_kind; disposition_detail; source_state }

let decode_workspace_memory_ledger json =
  let* _, body = unwrap_v2_or_raw json in
  let* status = required_nonblank_string body "status" in
  let* ledger_sha256 = optional_nonblank_string body "ledger_sha256" in
  match optional_object_field body "ledger" with
  | Error _ as err -> err
  | Ok None -> Ok { status; ledger_sha256; claims = []; conflicts = []; facts = [] }
  | Ok (Some ledger) ->
      let* claim_items = optional_list_field ledger "claims" in
      let claims =
        List.filter_map
          (fun c ->
            match
              optional_nonblank_string c "claim_id",
              optional_string_field c "claim"
            with
            | Ok (Some cid), Ok (Some txt) -> Some (cid, txt)
            | Ok None, _ | Error _, _ | Ok (Some _), (Ok None | Error _) -> None)
          claim_items
      in
      let* conflict_items = optional_list_field ledger "conflicts" in
      let conflicts =
        List.filter_map
          (fun c ->
            match
              optional_nonblank_string c "conflict_id",
              optional_string_field c "description"
            with
            | Ok (Some cid), Ok (Some txt) -> Some (cid, txt)
            | Ok None, _ | Error _, _ | Ok (Some _), (Ok None | Error _) -> None)
          conflict_items
      in
      let* fact_items = optional_list_field ledger "facts" in
      let* facts = decode_list "facts" decode_workspace_ledger_fact fact_items in
      Ok { status; ledger_sha256; claims; conflicts; facts }

let decode_workspace_context_obs json =
  let* status = required_nonblank_string json "status" in
  match status with
  | "missing" -> Ok Ctx_missing
  | "unavailable" ->
      let detail =
        match optional_string_field json "detail" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> "unavailable"
      in
      Ok (Ctx_unavailable detail)
  | "available" ->
      let rev, count =
        match optional_object_field json "snapshot" with
        | Ok (Some snap) ->
            let r =
              match optional_int_field snap "revision" with
              | Ok v -> v
              | Error _ -> None
            in
            let fc =
              match optional_list_field snap "facts" with
              | Ok xs -> List.length xs
              | Error _ -> 0
            in
            (r, fc)
        | Ok None | Error _ -> (None, 0)
      in
      Ok (Ctx_available { revision = rev; fact_count = count })
  | other -> Error (Printf.sprintf "unknown workspace context status %S" other)

let decode_workspace_context_keeper json =
  let* keeper_id = required_nonblank_string json "keeper_id" in
  let* ord_obj = required_object_field json "ordinary" in
  let* ordinary = decode_workspace_context_obs ord_obj in
  let* src_obj = required_object_field json "source_bound" in
  let* source_bound = decode_workspace_context_obs src_obj in
  Ok { keeper_id; ordinary; source_bound }

let decode_workspace_memory_context json =
  let* _, body = unwrap_v2_or_raw json in
  let generated_at = float_or_zero_k body "generated_at" in
  let discovery_status, discovery_detail =
    match optional_object_field body "discovery" with
    | Ok (Some d) ->
        let st =
          match optional_nonblank_string d "status" with
          | Ok (Some s) -> s
          | Ok None | Error _ -> "available"
        in
        let det =
          match optional_nonblank_string d "detail" with
          | Ok v -> v
          | Error _ -> None
        in
        (st, det)
    | Ok None | Error _ -> ("available", None)
  in
  let* items = optional_list_field body "keepers" in
  let* keepers = decode_list "keepers" decode_workspace_context_keeper items in
  Ok { generated_at; discovery_status; discovery_detail; keepers }

let decode_memory_journal_entry json =
  let structural_id =
    match optional_string_field json "structural_id" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let ok =
    match optional_bool_field json "ok" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> true
  in
  let* outcome = optional_nonblank_string json "outcome" in
  let* recorded_at = optional_finite_float json "recorded_at" in
  let* revision = optional_int_field json "revision" in
  let source_kind =
    match optional_object_field json "source" with
    | Ok (Some s) -> (
        match optional_nonblank_string s "kind" with Ok v -> v | Error _ -> None)
    | Ok None | Error _ -> None
  in
  let count_list_or_int obj key =
    match member key obj with
    | `List xs -> List.length xs
    | `Int n -> n
    | `Float f -> int_of_float f
    | _ -> 0
  in
  let added, removed, retained, invalidated =
    match optional_object_field json "change" with
    | Ok (Some c) ->
        ( count_list_or_int c "added",
          count_list_or_int c "removed",
          int_or_zero_k c "retained",
          count_list_or_int c "invalidated" )
    | Ok None | Error _ -> (0, 0, 0, 0)
  in
  let* error = optional_nonblank_string json "error" in
  Ok
    {
      structural_id;
      ok;
      outcome;
      recorded_at;
      revision;
      source_kind;
      added;
      removed;
      retained;
      invalidated;
      error;
    }

let extract_claim_texts json key =
  match optional_list_field json key with
  | Error _ -> []
  | Ok items ->
      List.filter_map
        (fun item ->
          match optional_nonblank_string item "claim" with
          | Ok (Some c) -> Some c
          | Ok None | Error _ -> None)
        items

let decode_journal_activity_event json =
  let identity =
    match optional_string_field json "identity" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let recorded_at = float_or_zero_k json "recorded_at" in
  let revision = int_or_zero_k json "revision" in
  let* kind = required_nonblank_string json "kind" in
  let before_claims = extract_claim_texts json "before" in
  let after_claims = extract_claim_texts json "after" in
  let* reason = optional_nonblank_string json "reason" in
  Ok { identity; recorded_at; revision; kind; before_claims; after_claims; reason }

let decode_keeper_memory_journal json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let returned = int_or_zero_k body "returned" in
  let undecodable_lines = int_or_zero_k body "undecodable_lines" in
  let* entry_items = optional_list_field body "entries" in
  let* entries = decode_list "entries" decode_memory_journal_entry entry_items in
  let* activity_events, activity_notes =
    match optional_object_field body "activity" with
    | Error _ as err -> err
    | Ok None -> Ok ([], [])
    | Ok (Some act) ->
        let* ev_items = optional_list_field act "events" in
        let* events =
          decode_list "activity.events" decode_journal_activity_event ev_items
        in
        let* notes = optional_string_list act "notes" in
        Ok (events, notes)
  in
  Ok
    {
      keeper;
      returned;
      undecodable_lines;
      entries;
      activity_events;
      activity_notes;
    }
