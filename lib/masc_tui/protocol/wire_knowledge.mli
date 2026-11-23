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
  score : int;  (** [votes_up - votes_down] from the server row. *)
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

(** The link shapes the wiki does not follow, one per server
    [unsupported:<shape>] kind. *)
type wiki_unsupported_link =
  | Unsupported_anchor
  | Unsupported_scheme
  | Unsupported_path
  | Unsupported_not_markdown
  | Unsupported_wikilink

(** Where a page link points, one case per server [kind]. An unsupported link
    keeps only its shape: the server's target for it is the link's [raw]
    text, which is blank for [[x]()] and [[x](<>)]. *)
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

val wiki_source_to_string : wiki_source -> string
val wiki_source_of_string : string -> wiki_source option

val decode_wiki_index : Yojson.Safe.t -> (wiki_index, string) result
val decode_wiki_page_detail : Yojson.Safe.t -> (wiki_page_detail, string) result
val decode_wiki_log : Yojson.Safe.t -> (wiki_log_response, string) result
val decode_wiki_search : Yojson.Safe.t -> (wiki_search_response, string) result
val decode_wiki_lint : Yojson.Safe.t -> (wiki_lint_report, string) result
val encode_wiki_put_request : wiki_put_request -> Yojson.Safe.t

(** {1 Artifacts} *)

(** The content-addressed body of an artifact's latest revision. *)
type artifact_body = {
  sha256 : string;
  bytes : int;
  mime : string;
}

(** One [GET /api/v1/published-artifacts] row: the latest revision of a
    published artifact. [id] is the stable [artifact-<32hex>] key; [body]
    changes with every revision. *)
type artifact_entry = {
  id : string;
  revision : int;
  title : string;
  summary : string;
  author : string;
  created_at_unix : float;
  body : artifact_body;
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

(** {1 Per-Keeper Memory OS Internals ([/api/v1/keepers/:name/memory-os-internals])} *)

val keeper_memory_os_internals_path : keeper:string -> string
val keeper_memory_facts_path : keeper:string -> string
val keeper_memory_activity_path : keeper:string -> ?limit:int -> unit -> string
val keeper_memory_health_path : ?keeper:string -> unit -> string

type compaction_internals = {
  present : bool;
  epoch_count : int;
  archived_turns_count : int;
  anchor_bytes : int;
  latest_epoch_id : int option;
  covers_through_turn : string option;
  archived_epochs_through : int option;
  verified_facts_count : int;
  decisions_count : int;
  open_threads_count : int;
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

val decode_memory_os_internals :
  Yojson.Safe.t -> (memory_os_internals, string) result

(** {1 Per-Keeper Memory Facts ([/api/v1/keepers/:name/memory-facts])} *)

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

val memory_fact_category_to_string : memory_fact_category -> string
val memory_fact_origin_to_string : memory_fact_origin -> string
val source_invalidation_reason_to_string : source_invalidation_reason -> string

val decode_keeper_memory_facts :
  Yojson.Safe.t -> (keeper_memory_facts, string) result

(** {1 Per-Keeper Memory Evolution / Activity ([/api/v1/keepers/:name/memory-journal?activity=1&limit=50])} *)

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

val equal_memory_activity_kind :
  memory_activity_kind -> memory_activity_kind -> bool
val memory_activity_kind_to_string : memory_activity_kind -> string

val decode_keeper_memory_activity :
  Yojson.Safe.t -> (keeper_memory_activity, string) result

(** {1 Fleet Keeper Memory Health ([/api/v1/dashboard/keeper-memory-health])} *)

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

val decode_keeper_memory_health_fleet :
  Yojson.Safe.t -> (keeper_memory_health_fleet, string) result
