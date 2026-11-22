(** Knowledge domain wire codecs: Board posts/comments/quarantines, Wiki
    ([/api/v1/wiki*]), Artifacts, World Memory ([/api/v1/memory/world]),
    Temporal Memory Diff ([/api/v1/memory/diff]), and Keeper Memory Recovery
    Acts ([/api/v1/keepers/:name/memory/act]). *)

open Masc_tui_core

(** {1 Endpoint Builders} *)

val board_list_path :
  ?sort_by:string ->
  ?hearth:string ->
  ?signal_only:bool ->
  ?limit:int ->
  ?offset:int ->
  unit ->
  string

val board_post_path :
  post_id:string -> ?comment_offset:int -> ?comment_limit:int -> unit -> string

val keeper_quarantines_path : keeper:string -> string
val keeper_quarantine_requeue_path : keeper:string -> partition_id:string -> string

val wiki_index_path :
  ?tag:string -> ?source:string -> ?sort:string -> unit -> string

val wiki_page_path : page:string -> string
val wiki_log_path : ?limit:int -> ?before_idx:int -> ?page:string -> unit -> string
val wiki_search_path : query:string -> ?limit:int -> unit -> string
val wiki_lint_path : string
val world_memory_path : string
val workspace_memory_inventory_path : string

val memory_diff_path :
  keeper:string option ->
  ?window:string ->
  ?from_rev:int ->
  ?to_rev:int ->
  unit ->
  string

val keeper_memory_act_path : keeper:string -> string

(** {1 Board Posts, Comments & Quarantines} *)

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

type quarantine_candidate = {
  partition_id : string;
  quarantine_id : string;
  keeper : string;
  post_id : string;
  status : string;
  failure_reason : string;
  quarantined_at_unix : float option;
}

val is_signal_board_post :
  post_kind:post_kind option ->
  hearth:string option ->
  title:string ->
  body:string ->
  bool
(** Client-side signal classifier used as defense-in-depth when a server omits
    [is_signal]: filters out [System_post], [hearth = Some "verification"], and
    automated verification/approval noise ([Verify:], [[verify]],
    [Approved task], [Rejected task]). *)

val decode_board_feed :
  observed_at:Clock.Mono.t -> Yojson.Safe.t -> (board_feed, string) result

val decode_board_thread :
  observed_at:Clock.Mono.t ->
  Yojson.Safe.t ->
  (board_post * board_comment list, string) result

val decode_quarantines :
  Yojson.Safe.t -> (quarantine_candidate list, string) result

val encode_quarantine_requeue_request :
  quarantine_id:string -> reason:string option -> Yojson.Safe.t

(** {1 Wiki ([/api/v1/wiki*])} *)

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

type wiki_outgoing_link = {
  text : string;
  kind : string;
  target : string;
  raw : string;
  line : int;
  exists : bool option;
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

val wiki_source_to_string : wiki_source -> string
val wiki_source_of_string : string -> wiki_source option

val decode_wiki_index : Yojson.Safe.t -> (wiki_index, string) result
val decode_wiki_page_detail : Yojson.Safe.t -> (wiki_page_detail, string) result
val decode_wiki_log : Yojson.Safe.t -> (wiki_log_response, string) result
val decode_wiki_search : Yojson.Safe.t -> (wiki_search_response, string) result
val decode_wiki_lint : Yojson.Safe.t -> (wiki_lint_report, string) result
val encode_wiki_put_request : wiki_put_request -> Yojson.Safe.t

(** {1 Artifacts} *)

type artifact_entry = {
  sha256 : string;
  name : string;
  mime_type : string;
  bytes : int;
  created_at_unix : float option;
  producer : string option;
  title : string option;
}

val decode_artifacts_list : Yojson.Safe.t -> (artifact_entry list, string) result

(** {1 World Memory, Temporal Memory Diff & Keeper Memory Recovery Acts} *)

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

type librarian_writer_row = {
  keeper : string;
  state : writer_state;
  available_act_tokens : string list;
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

type memory_updated_fact = {
  relation : modification_relation;
  at_rev : int;
  before : memory_fact_entry;
  after : memory_fact_entry;
}

type memory_retracted_fact = {
  memory_id : string;
  category : string;
  text : string;
  removed_at_rev : int;
  removed_by : string;
  drop_reason : string option;
}

type memory_invalidated_fact = {
  memory_id : string;
  text : string;
  at_rev : int;
  missing_premise_ids : string list;
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
}

type keeper_writer_status =
  | Keeper_writer_none_in_process
  | Keeper_writer_none
  | Keeper_writer_active of {
      state : writer_state;
      available_act_tokens : string list;
    }

type world_diff_counts = {
  total_claims_now : int;
  added : int;
  updated : int;
  retracted : int;
  incomplete_batches : int;
  aborted_batches : int;
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
  payload : Yojson.Safe.t;
}

type world_updated_entry = {
  seq : int;
  fact_id : string;
  summary : string;
  recorded_at : string;
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

val decode_world_memory : Yojson.Safe.t -> (world_memory, string) result
val decode_workspace_memory_inventory_as_world_memory :
  Yojson.Safe.t -> (world_memory, string) result
(** Decode [GET /api/v1/dashboard/workspace-memory-inventory] into a
    {!world_memory} summary as a graceful fallback when [/api/v1/memory/world]
    returns HTTP 404 on older servers. *)
val decode_memory_diff : Yojson.Safe.t -> (memory_diff, string) result
val encode_memory_act_request : memory_recovery_act -> Yojson.Safe.t
val decode_memory_act_answer :
  status_code:int -> Yojson.Safe.t -> (memory_act_answer, string) result
