open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_context_runtime
module StringSet = Set_util.StringSet
module StringMap = Set_util.StringMap
module IntMap = Map.Make (Int)


(* Issue #8484: Variant SSOT for memory search scope. Adding a new
   constructor forces compilation in [memory_search_source_to_string]
   AND extends [valid_memory_search_source_strings]; the schema in
   [tool_shard.ml] mirrors the SSOT (cycle: Tool_shard ->
   Keeper_tool_memory_runtime -> ... -> Tool_shard prevented via local mirror,
   sync test catches drift). The previous code used a string match
   with a wildcard `_ -> current` branch which silently routed any
   unknown source to the current-memory search. Now unknown values are rejected at the
   tool boundary. *)
type memory_search_source =
  | Current
  | Absorbed
  | Dropped
  | History
  | All

let memory_search_source_to_string = function
  | Current -> "current"
  | Absorbed -> "absorbed"
  | Dropped -> "dropped"
  | History -> "history"
  | All -> "all"
;;

let memory_search_source_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "current" -> Some Current
  | "absorbed" -> Some Absorbed
  | "dropped" -> Some Dropped
  | "history" -> Some History
  | "all" -> Some All
  | _ -> None
;;

let all_memory_search_sources = [ Current; Absorbed; Dropped; History; All ]

let valid_memory_search_source_strings =
  List.map memory_search_source_to_string all_memory_search_sources
;;

(* --- Durable fact search (Memory OS store) --- *)

type fact_store = Keeper_tool_memory_validation.fact_store =
  | Ordinary_current
  | Source_bound_current

let fact_store_to_string = function
  | Ordinary_current -> "current_memory_snapshot"
  | Source_bound_current -> "source_bound_current_memory"
;;

(* [origin] and [last_seen] travel with the memory_id because only an
   ordinary current fact has them. [origin] tells the keeper which matches
   [supersedes] accepts; [last_seen] is when the same claim bytes were last
   observed again. A file-bound fact keeps no such time: every read checks it
   against its file. *)
type fact_identity =
  | Ordinary_memory_id of
      { memory_id : string
      ; origin : Keeper_memory_os_types.origin_kind
      ; last_seen : float
      }
  | Source_sha256 of string

(* [first_seen] is the stored insertion time. Every current fact has one, so
   it is a field of the match, not of an identity. *)
type fact_match =
  { identity : fact_identity
  ; claim : string
  ; category : string
  ; basis : Keeper_memory_os_types.basis
  ; store : fact_store
  ; first_seen : float
  ; lookup_evidence : Keeper_memory_os_current.admission_recall_binding option
  ; successor_evidence : Keeper_memory_os_current.successor_recall_candidate option
  }

(* The durable stores a search reads. Either failing is the store, not the
   query: the arguments were never judged, so the failure is typed as a
   dependency that did not answer rather than raised as an exception the
   dispatcher would print back to the model as [Failure(...)]. *)
type durable_search_error =
  | Snapshot_read_failed of string
  | Source_revalidate_failed of string
  | Memory_log_read_failed of string
  | Cursor_invalid
  | Cursor_stale
  | Cursor_scope_unsupported

let durable_search_error_kind_to_string = function
  | Snapshot_read_failed _ -> "snapshot_read_failed"
  | Source_revalidate_failed _ -> "source_revalidate_failed"
  | Memory_log_read_failed _ -> "memory_log_read_failed"
  | Cursor_invalid -> "invalid_memory_search_cursor"
  | Cursor_stale -> "stale_memory_search_cursor"
  | Cursor_scope_unsupported -> "unsupported_memory_search_cursor_scope"
;;

let durable_search_error_detail = function
  | Snapshot_read_failed detail
  | Source_revalidate_failed detail
  | Memory_log_read_failed detail -> detail
  | Cursor_invalid -> "Pass the next_cursor returned by the previous current-memory page."
  | Cursor_stale -> "Current memory or query changed. Restart the search without cursor."
  | Cursor_scope_unsupported -> "Pagination is available only for source=current."
;;

let read_current_facts ~keepers_dir ~keeper_id =
  match
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id)
  with
  | Ok None -> Ok []
  | Ok (Some snapshot) -> Ok snapshot.facts
  | Error detail -> Error (Snapshot_read_failed detail)
;;

let fact_match_lookup_text (matched : fact_match) =
  match matched.lookup_evidence with
  | None -> matched.claim
  | Some binding -> binding.source_fact.claim
;;

(* Set by the first ranking failure {!answering} logs. *)
let ranking_failure_logged = Atomic.make false

(* Which of [items], given in store order, answer [query], in two tiers.
   First the ones whose claim holds the whole query as one run of text, in
   store order, so what an exact phrase finds is never displaced by the
   broader tier. Then the ones holding any whitespace-separated term of it,
   as the trigram index ({!Keeper_memory_search_index}) finds them, together
   with the ones holding every query term. Short ASCII terms require word
   boundaries; longer and UTF-8 terms use substring matching. That tier is ordered by the index's
   BM25 score, best first; an item the index did not rank follows the ranked
   ones in store order. Choosing among many exact matches is the recall
   judgment's work, not a lexical score's. When the index cannot be built, the
   second tier keeps store order, the same query matching still answers, and
   the log says so once per process: a host whose SQLite lacks the trigram
   tokenizer (older than 3.34) fails every search the same way. *)
let answering_with_rank ~rank_fn ~claim_of ~query items =
  if String.equal query ""
  then items, []
  else (
    let scores =
      match rank_fn () with
      | Ok ranked ->
        List.fold_left
          (fun acc (position, score) -> IntMap.add position score acc)
          IntMap.empty ranked
      | Error error ->
        if Atomic.compare_and_set ranking_failure_logged false true
        then
          Log.Keeper.warn
            "keeper_memory_search answers in store order; the ranking index failed \
             (logged once per process): %s"
            (Keeper_memory_search_index.error_to_string error);
        IntMap.empty
    in
    let score (position, _) = IntMap.find_opt position scores in
    let best_first a b =
      match score a, score b with
      | Some x, Some y -> Float.compare x y
      | Some _, None -> -1
      | None, Some _ -> 1
      | None, None -> 0
    in
    let ordered tier = List.stable_sort best_first tier |> List.map snd in
    let whole_query, rest =
      List.partition
        (fun (_, item) -> String_util.contains_query_term_ci (claim_of item) query)
        (List.mapi (fun position item -> position, item) items)
    in
    ( List.map snd whole_query
    , ordered
        (List.filter
           (fun ((_, item) as entry) ->
              Option.is_some (score entry)
              || String_util.contains_all_query_terms_ci (claim_of item) query)
           rest) ))
;;

let answering ~claim_of ~query items =
  answering_with_rank
    ~rank_fn:(fun () -> Keeper_memory_search_index.rank ~query (List.map claim_of items))
    ~claim_of ~query items
;;

(* The keeper's current facts that answer the query ({!answering}): ordinary
   then source-bound facts holding the whole query, then ordinary then
   source-bound facts holding its fragments. *)
let search_durable_facts
      ~(config : Workspace.config)
      ~(keepers_dir : string)
      ~(meta : keeper_meta)
      ~(facts : Keeper_memory_os_types.fact list)
      ~(recall_bindings : Keeper_memory_os_current.admission_recall_binding list)
      ~(query : string)
      ~(limit : int option)
  : (fact_match list * int * Keeper_memory_source_current.file_source list * (unit -> string),
     durable_search_error) result
  =
  let selected_sources =
    match Keeper_memory_source_current.read_for_keepers_dir
        ~keepers_dir ~keeper_id:meta.name with
    | Error detail -> Error (Source_revalidate_failed detail)
    | Ok None -> Ok ([], [])
    | Ok (Some snapshot) ->
      Ok (answering
          ~claim_of:(fun (fact : Keeper_memory_source_current.fact) -> fact.claim)
          ~query snapshot.facts) in
  match Result.bind selected_sources (fun (whole, fragments) ->
    let sources = List.map (fun (fact : Keeper_memory_source_current.fact) -> fact.source)
        (whole @ fragments) in
    Result.map (fun projection -> projection, whole, fragments)
      (Result.map_error (fun detail -> Source_revalidate_failed detail)
        (Keeper_memory_source_current.revalidate
          ~scope:(Keeper_memory_source_current.Selected_sources sources)
          ~config ~meta ~keepers_dir ~now:(Time_compat.now ()) ())))
  with
  | Error _ as error -> error
  | Ok (source_projection, source_whole, source_fragments) ->
  (* A retained claim is not a verified search result. Recall exposes only
     deferred source identities until this read boundary can validate bytes. *)
  let unverified_paths = StringSet.of_list source_projection.unverified_paths in
  let source_facts = List.filter
      (fun (fact : Keeper_memory_source_current.fact) ->
        not (StringSet.mem fact.source.path unverified_paths))
      source_projection.facts in
  let total_candidates = List.length facts + List.length source_projection.facts in
  let ordinary_entries = List.map (fun fact -> fact, None) facts in
  let by_id = List.fold_left (fun indexed (fact : Keeper_memory_os_types.fact) ->
    StringMap.add (Keeper_memory_os_types.memory_id fact) fact indexed) StringMap.empty facts in
  let lookup_entries = if query = "" then [] else
    List.filter_map (fun (binding : Keeper_memory_os_current.admission_recall_binding) ->
      Option.map (fun target -> target, Some binding)
        (StringMap.find_opt binding.target_memory_id by_id)) recall_bindings in
  let ordinary_whole, ordinary_fragments =
    let claim_of
        ((fact : Keeper_memory_os_types.fact),
         (evidence : Keeper_memory_os_current.admission_recall_binding option)) =
      match evidence with None -> fact.claim | Some binding -> binding.source_fact.claim
    in
    if lookup_entries = []
    then
      answering_with_rank
        ~rank_fn:(fun () ->
          Keeper_memory_search_index.rank_persistent_for_facts
            ~keepers_dir ~keeper_id:meta.name ~query facts)
        ~query ~claim_of ordinary_entries
    else answering ~query ~claim_of (ordinary_entries @ lookup_entries)
  in
  (* Keep the query's ranked order without building a second index. A
     concurrently rewritten claim is not the selected claim, even if its
     path/digest stayed equal: withhold it until another query selects it. *)
  let current_by_path = List.fold_left
      (fun indexed (fact : Keeper_memory_source_current.fact) ->
        StringMap.add fact.source.path fact indexed) StringMap.empty source_facts in
  let still_current (fact : Keeper_memory_source_current.fact) =
    match StringMap.find_opt fact.source.path current_by_path with
    | Some current -> current = fact
    | None -> false in
  (* Only query-selected identities count as a deferred lookup. Other
     unverified paths were deliberately not read and are not search failures. *)
  let deferred_sources = List.filter_map
      (fun (fact : Keeper_memory_source_current.fact) ->
        if StringSet.mem fact.source.path unverified_paths then Some fact.source
        else None) (source_whole @ source_fragments) in
  let source_whole = List.filter still_current source_whole in
  let source_fragments = List.filter still_current source_fragments in
  let ordinary_match ((fact : Keeper_memory_os_types.fact), lookup_evidence) : fact_match =
    { claim = fact.claim
    ; identity =
        Ordinary_memory_id
          { memory_id = Keeper_memory_os_types.memory_id fact
          ; origin = fact.origin.kind
          ; last_seen = fact.last_seen
          }
    ; category = Keeper_memory_os_types.category_to_string fact.category
    ; basis = fact.basis
    ; store = Ordinary_current
    ; first_seen = fact.first_seen
    ; lookup_evidence
    ; successor_evidence = None
    }
  in
  let source_match (fact : Keeper_memory_source_current.fact) : fact_match =
    { identity = Source_sha256 fact.source.sha256
    ; claim = fact.claim
    ; category = "fact"
    ; basis = Keeper_memory_os_types.Observed Keeper_memory_os_types.Transcript
    ; store = Source_bound_current
    ; first_seen = fact.first_seen
    ; lookup_evidence = None
    ; successor_evidence = None
    }
  in
  let deduplicate_targets matches =
    let _, reversed = List.fold_left (fun (seen, kept) (matched : fact_match) ->
      match matched.identity with
      | Source_sha256 _ -> seen, matched :: kept
      | Ordinary_memory_id {memory_id; _} ->
        if StringSet.mem memory_id seen then seen, kept
        else StringSet.add memory_id seen, matched :: kept) (StringSet.empty, []) matches in
    List.rev reversed in
  Ok
    ( (let matches = deduplicate_targets (List.map ordinary_match ordinary_whole
           @ List.map source_match source_whole
           @ List.map ordinary_match ordinary_fragments
           @ List.map source_match source_fragments) in
       match limit with None -> matches | Some limit -> take limit matches)
    , total_candidates
    , deferred_sources
    (* Only paged current search needs a corpus revision. Capture this read's
       immutable values; combined all-store search never serializes or hashes
       the corpus merely to discard its revision. *)
    , (fun () -> Snapshot_protocol.revision_of_json ~namespace:"keeper-current-memory-corpus"
        (`Assoc
           [ "ordinary", `List (List.map Keeper_memory_os_types.fact_to_json facts)
           ; "source", (match source_projection.snapshot with
               | None -> `Null
               | Some snapshot -> Keeper_memory_source_current.to_json snapshot)
           ; "unverified_paths", `List (List.map (fun path -> `String path)
               source_projection.unverified_paths)
           ])) )
;;

let successor_candidates_for_query ~query candidates =
  if query="" then [] else
  let whole,fragments = answering ~query
    ~claim_of:(fun (candidate : Keeper_memory_os_current.successor_recall_candidate) ->
      candidate.binding.source_fact.claim) candidates in
  whole @ fragments
;;

let search_current_with_successors ~clock ~config ~keepers_dir ~(meta : keeper_meta) ~query ~limit =
  let module Current = Keeper_memory_os_current in
  let module Selector = Keeper_memory_successor_selection in
  match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id:meta.name) with
  | Error detail -> Error (Snapshot_read_failed detail)
  | Ok state ->
    let relevant claim_of rows = if query="" then [] else
      let whole,fragments = answering ~claim_of ~query rows in whole @ fragments in
    let candidates = successor_candidates_for_query ~query state.successor_candidates in
    let judged = Selector.run ~clock ~config ~keepers_dir ~keeper_id:meta.name ~query
      ~snapshot:state.snapshot candidates in
    let fresh = if candidates=[] then Ok state else
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id:meta.name) in
    (match fresh with
    | Error detail -> Error (Snapshot_read_failed detail)
    | Ok fresh ->
    let judged = Selector.revalidate ~snapshot:state.snapshot ~candidates ~current:fresh judged in
    let facts = match fresh.snapshot with None -> [] | Some snapshot -> snapshot.Current.facts in
    let history_unresolved = relevant (fun (row : Current.recall_unresolved) ->
      row.binding.source_fact.claim) fresh.unresolved
      |> List.filter (fun (row : Current.recall_unresolved) -> match row.reason with
        | Current.Retired_without_successor _ -> false
        | History_unavailable _ | Missing_transition _ | Invalid_transition _ | Unrecorded_lineage _ -> true) in
    let unresolved = List.map (fun ((candidate : Current.successor_recall_candidate),issue) -> `Assoc
      ["request_id",`String candidate.Current.binding.candidate_id.request_id;
       "issue",Selector.issue_to_json issue]) judged.unresolved
      @ List.map (fun (row : Current.recall_unresolved) -> `Assoc
        ["request_id",`String row.binding.candidate_id.request_id;
         "issue",Current.recall_unresolved_reason_to_json row.reason]) history_unresolved in
    let unresolved = match fresh.receipt_verification with
      | Ok () -> unresolved
      | Error detail -> `Assoc ["issue", `Assoc
          ["kind", `String "receipt_unavailable"; "detail", `String detail]] :: unresolved in
    let extra_fields = if unresolved=[] then [] else
      ["successor_recall",`Assoc ["status",`String "incomplete";"unresolved",`List unresolved;
        "guidance",`String "Some historical lookup paths could not be resolved. Existing direct results remain usable; absence of further results is not evidence that no current successor exists."]] in
    (* Keep direct results even when judging a successor fails. Deduplication
       and the caller's limit happen only after merging both query tiers. *)
    match search_durable_facts ~config ~keepers_dir ~meta ~facts
      ~recall_bindings:fresh.direct_bindings ~query ~limit with
    | Error _ as error -> error
    | Ok (direct,total,deferred,corpus_revision) ->
      let successors = List.map (fun (candidate : Current.successor_recall_candidate) ->
        let fact = candidate.target in
        {identity=Ordinary_memory_id {memory_id=Keeper_memory_os_types.memory_id fact;origin=fact.origin.kind;
           last_seen=fact.last_seen};
         claim=fact.claim;category=Keeper_memory_os_types.category_to_string fact.category;
         basis=fact.basis;store=Ordinary_current;first_seen=fact.first_seen;lookup_evidence=Some candidate.binding;
         successor_evidence=Some candidate}) judged.selected in
      let whole,fragments = if successors=[] then direct,[] else
        answering ~claim_of:fact_match_lookup_text ~query (direct @ successors) in
      let _,rev = List.fold_left (fun (seen,kept) (matched : fact_match) -> match matched.identity with
        | Source_sha256 _ -> seen,matched::kept
        | Ordinary_memory_id {memory_id;_} -> if StringSet.mem memory_id seen then seen,kept
          else StringSet.add memory_id seen,matched::kept) (StringSet.empty,[]) (whole @ fragments) in
      let merged = List.rev rev in
      let merged = match limit with None -> merged | Some limit -> take limit merged in
      Ok (facts,merged,total,deferred,extra_fields,unresolved<>[],corpus_revision))
;;

(* [first_seen] and [last_seen] are absolute UTC ISO 8601, the form of the
   [Temporal] line the keeper compares them with. A relative age would be
   wrong in every later turn that rereads this result from history. *)
let fact_match_to_json (m : fact_match) : Yojson.Safe.t =
  `Assoc
    ([ "text", `String m.claim
     ; "category", `String m.category
     ; "basis", Keeper_memory_os_types.basis_to_json m.basis
     ; "store", `String (fact_store_to_string m.store)
     ; "first_seen", `String (Masc_domain.iso8601_of_unix_seconds m.first_seen)
     ]
     @ (match m.successor_evidence with
        | None -> []
        | Some evidence -> ["successor_lookup_evidence", `Assoc
            ["kind",`String "historical_source_with_judged_committed_successor";
             "evidence",Keeper_memory_successor_selection.candidate_to_json evidence;
             "guidance",`String "Historical lookup provenance only. Returned text and memory_id describe the current target, whose policy may differ from the historical source."]])
     @ (match m.lookup_evidence, m.successor_evidence with
        | None, _ | Some _, Some _ -> []
        | Some binding, None ->
          [ "lookup_evidence", `Assoc
              [ "kind", `String "historical_admission_source"
              ; "request_id", `String binding.candidate_id.request_id
              ; "source_fact", Keeper_memory_os_types.fact_to_json binding.source_fact
              ; "target_memory_id", `String binding.target_memory_id
              ; "guidance", `String "Historical observation used to locate the current target. The returned text and memory_id describe current Memory; this evidence is not a separate current claim."
              ] ])
     @
     match m.identity with
     | Ordinary_memory_id { memory_id; origin; last_seen } ->
       [ "memory_id", `String memory_id
       ; "origin", `String (Keeper_memory_os_types.origin_kind_to_string origin)
       ; "last_seen", `String (Masc_domain.iso8601_of_unix_seconds last_seen)
       ]
     | Source_sha256 sha256 -> [ "source_sha256", `String sha256 ])
;;

(* --- The Memory writer beside a search (RFC librarian-call-only-proposes §11.5) --- *)

(* The snapshot is read whatever the writer's state, and the answer says
   what that state was. An open store says nothing. A stopped one says why.
   A writer that has not opened its store, or none at all, means the snapshot
   was read before it was checked against the commit log, so it can be one
   write behind (§8.6). The table is only read: a search makes no writer. *)
let memory_writer_fields ~(config : Workspace.config) ~keeper_name =
  let not_checked state =
    [ ( "memory_writer"
      , `Assoc
          [ "state", `String state
          ; ( "guidance"
            , `String
                "Memory was read before its writer checked it against the commit log; it can be one write behind." )
          ] )
    ]
  in
  match Keeper_memory_writers.find ~base_path:config.base_path with
  | None -> not_checked "none_in_process"
  | Some writers ->
    (match List.assoc_opt keeper_name (Librarian_writers.statuses writers) with
     | None -> not_checked "not_started"
     | Some Booting -> not_checked "booting"
     | Some Retired -> not_checked "retired"
     | Some (Open (_ : Librarian_log.line)) -> []
     | Some (Stopped stop) ->
       [ ( "memory_writer"
         , `Assoc
             [ "state", `String "stopped"
             ; ( "stop"
               , `String
                   (Keeper_tool_memory_validation.memory_unwritable_to_string
                      (Keeper_tool_memory_validation.Store_stopped stop)) )
             ; ( "guidance"
               , `String
                   "Memory writes are refused until an operator resumes or adopts the store. This is the snapshot the store last held." )
             ] )
       ])
;;

(* --- Facts that left Memory (RFC librarian-call-only-proposes §11.5) --- *)

let read_left ~keepers_dir ~keeper_id ~current =
  match
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Keeper_memory_left.read ~keepers_dir ~keeper_id ~current)
  with
  | Error detail -> Error (Memory_log_read_failed detail)
  | Ok left -> Ok left
;;

let absorbed_claim (absorbed : Keeper_memory_left.absorbed) =
  absorbed.left.fact.Keeper_memory_os_types.claim
;;

let dropped_claim (dropped : Keeper_memory_left.dropped) =
  dropped.left.fact.Keeper_memory_os_types.claim
;;

(* The absorbed facts that answer the query the way current facts do
   ({!answering}). [answered_by] names the current facts that answer this
   search themselves. An absorbed fact that went into one of them says the
   same thing again, so it is left out before [limit] is taken: the facts
   that went into one answering claim do not take the places of facts that
   went somewhere else. *)
let answering_absorbed ~answered_by ~query ~limit absorbed =
  let whole_query, fragments = answering ~claim_of:absorbed_claim ~query absorbed in
  whole_query @ fragments
  |> List.filter (fun (absorbed : Keeper_memory_left.absorbed) ->
    not (StringSet.mem absorbed.into answered_by))
  |> take limit
;;

let answering_dropped ~query ~limit dropped =
  let whole_query, fragments = answering ~claim_of:dropped_claim ~query dropped in
  take limit (whole_query @ fragments)
;;

let left_guidance =
  "Historical removed claims, not current facts. Check the removal reason and original evidence before using or explicitly writing a current claim. Search never restores a fact. A fact removed before the Memory commit log started is not here."
;;

(* --- History search (checkpoint + current trace) --- *)
type history_search =
  { matches : string list
  ; unreadable_rows : int
  ; unavailable_traces : (string * Keeper_memory_recall_exn_class.t) list
  }

let empty_history_search = { matches = []; unreadable_rows = 0; unavailable_traces = [] }

let history_has_read_errors history =
  history.unreadable_rows > 0 || history.unavailable_traces <> []
;;

let history_read_error_fields history =
  if not (history_has_read_errors history) then []
  else
    [ ( "history_read_errors"
      , `Assoc
          [ "unreadable_rows", `Int history.unreadable_rows
          ; ( "unavailable_traces"
            , `List
                (List.map
                   (fun (trace_id, error) ->
                      `Assoc
                        [ "trace_id", `String trace_id
                        ; "error_kind", `String (Keeper_memory_recall_exn_class.to_label error)
                        ])
                   history.unavailable_traces) )
          ] )
    ]
;;

let search_history ~config ~(meta : keeper_meta) ~ctx_work ~query ~limit =
  if query = "" || limit <= 0 then empty_history_search
  else
    let whole_query content = String_util.contains_query_term_ci content query in
    let fragments content =
      (not (whole_query content))
      && String_util.contains_all_query_terms_ci content query
    in
    let exact_seen = ref StringSet.empty in
    let fragment_seen = ref StringSet.empty in
    let checkpoint_exact = ref [] in
    let checkpoint_fragments = ref [] in
    Keeper_memory_recall.user_messages_newest_first (messages_of_context ctx_work)
    |> List.iter (fun content ->
      if whole_query content && not (StringSet.mem content !exact_seen)
      then (
        exact_seen := StringSet.add content !exact_seen;
        if List.length !checkpoint_exact < limit
        then checkpoint_exact := !checkpoint_exact @ [ content ])
      else if fragments content
              && not (StringSet.mem content !fragment_seen)
              && List.length !checkpoint_fragments < limit
      then (
        fragment_seen := StringSet.add content !fragment_seen;
        checkpoint_fragments := !checkpoint_fragments @ [ content ]));
    let rec read_traces remaining exact_seen fragment_seen exact_matches
        fragment_matches unreadable_rows unavailable_traces = function
      | [] ->
        { matches = exact_matches @ take remaining fragment_matches
        ; unreadable_rows
        ; unavailable_traces = List.rev unavailable_traces
        }
      | _ when remaining = 0 ->
        { matches = exact_matches @ take remaining fragment_matches
        ; unreadable_rows
        ; unavailable_traces = List.rev unavailable_traces
        }
      | trace_id :: rest ->
        (* Selection belongs to this read until it succeeds. A failed scan
           must not hide the same body in a later readable trace. Fragment
           candidates stay side effects of the same scan so malformed rows
           and unavailable traces are observed exactly once. *)
        let local_exact_seen = ref exact_seen in
        let local_fragment_seen = ref fragment_seen in
        let local_fragments = ref fragment_matches in
        let select content =
          if whole_query content
             && not (StringSet.mem content !local_exact_seen)
          then (
            local_exact_seen := StringSet.add content !local_exact_seen;
            true)
          else if fragments content
                  && not (StringSet.mem content !local_fragment_seen)
                  && List.length !local_fragments < limit
          then (
            local_fragment_seen := StringSet.add content !local_fragment_seen;
            local_fragments := !local_fragments @ [ content ];
            false)
          else false
        in
        let result, unreadable =
          Keeper_memory_recall.load_history_user_messages_result
            ~path:(Keeper_types_support.keeper_history_path config trace_id)
            ~limit:remaining ~accept:select
        in
        (match result with
         | Ok selected ->
           read_traces (remaining - List.length selected) !local_exact_seen
             !local_fragment_seen (exact_matches @ selected) !local_fragments
             (unreadable_rows + unreadable) unavailable_traces rest
         | Error error ->
           read_traces remaining exact_seen fragment_seen exact_matches fragment_matches
             (unreadable_rows + unreadable) ((trace_id, error) :: unavailable_traces)
             rest)
    in
    let exact_matches = !checkpoint_exact in
    read_traces (limit - List.length exact_matches) !exact_seen !fragment_seen
      exact_matches !checkpoint_fragments 0 []
      [ Keeper_id.Trace_id.to_string meta.runtime.trace_id ]
;;

type all_search_match =
  | All_fact of fact_match
  | All_absorbed of Keeper_memory_left.absorbed
  | All_dropped of Keeper_memory_left.dropped
  | All_history of string

let all_search_match_text = function
  | All_fact match_ -> fact_match_lookup_text match_
  | All_absorbed match_ -> absorbed_claim match_
  | All_dropped match_ -> dropped_claim match_
  | All_history message -> message
;;

let all_search_match_to_json = function
  | All_fact match_ -> fact_match_to_json match_
  | All_absorbed match_ -> Keeper_memory_left.absorbed_to_json match_
  | All_dropped match_ -> Keeper_memory_left.dropped_to_json match_
  | All_history message ->
    `Assoc
      [ "source", `String (memory_search_source_to_string History)
      ; "text", `String message
      ]
;;

let ordinary_memory_id_of_all_match = function
  | All_fact { identity = Ordinary_memory_id { memory_id; _ }; _ } -> Some memory_id
  | All_fact { identity = Source_sha256 _; _ }
  | All_absorbed _
  | All_dropped _
  | All_history _ -> None
;;

(* Append one memory use event per id to the keeper's events sidecar.
   The caller's result is already decided; a failed append is
   reported in the log and does not change it. *)
let record_memory_events ~keepers_dir ~(meta : keeper_meta) ~now ~kind memory_ids =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    Keeper_memory_os_events.append_all
      ~keepers_dir
      ~keeper_id:meta.name
      (List.map
         (fun memory_id : Keeper_memory_os_events.event ->
            { recorded_at = now; memory_id; trace_id; kind })
         memory_ids))
  |> List.iter (fun error ->
    Log.Keeper.warn
      ~keeper_name:meta.name
      "%s"
      (Keeper_memory_os_events.append_error_to_string error))
;;

(* --- Unified keeper_memory_search dispatch --- *)

(* How one search ended, counted per source so the share of searches that
   found nothing is visible without reading the decision logs. A search that
   found nothing while a store or history file could not be read is its own
   case: better ranking cannot answer it, so it stays out of the misses a
   ranking change is measured against. *)
type memory_search_outcome =
  | Matched
  | No_match
  | No_match_partial_read
  | Store_unavailable

let memory_search_outcome_to_string = function
  | Matched -> "matched"
  | No_match -> "no_match"
  | No_match_partial_read -> "no_match_partial_read"
  | Store_unavailable -> "store_unavailable"
;;

(* What one search answered, before it is recorded. [durable_candidates]
   counts the durable facts and absorbed rows searched; history has no such
   count, so a source=all search can match more than it counts. *)
type search_answer =
  { output : Yojson.Safe.t
  ; match_count : int
  ; durable_candidates : int option
  ; read_errors : bool
  ; matched_memory_ids : string list
  }

(* The cursor names a current corpus and a position in its ordered answer.
   It carries no fact bodies and never authorizes mutation. *)
let current_cursor_of_json = function
  | `Null -> Ok None
  | `String raw ->
    (match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet raw with
     | Error _ -> Error Cursor_invalid
     | Ok bytes ->
       (match Yojson.Safe.from_string bytes with
        | `Assoc fields when List.length fields = 2 ->
          (match List.assoc_opt "revision" fields, List.assoc_opt "offset" fields with
           | Some (`String previous), Some (`Int offset) when offset > 0 ->
             Ok (Some (previous, offset))
           | _ -> Error Cursor_invalid)
        | _ -> Error Cursor_invalid
        | exception Yojson.Json_error _ -> Error Cursor_invalid))
  | _ -> Error Cursor_invalid
;;

let current_page_offset ~revision ~count = function
  | None -> Ok 0
  | Some (previous, offset) ->
    if not (String.equal previous revision) then Error Cursor_stale
    else if offset >= count then Error Cursor_stale
    else Ok offset
;;

let current_page_cursor ~revision ~offset =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
    (Yojson.Safe.to_string
       (`Assoc [ "revision", `String revision; "offset", `Int offset ]))
;;

let keeper_memory_search_with_outcome
      ?turn_ref
      ?clock
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t)
      ()
  =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  (* [Safe_ops.json_string] returns its default for an absent key and for a key
     whose value is not a string, so {"source": ["current"]} could otherwise
     reach Current
     while the merely misspelled {"source": "currnt"} was refused below. Read the
     member so a non-string lands on the same rejection a bad string does; the
     schema documents "current" as the default for absence only. *)
  let source_member = Safe_ops.safe_member "source" args in
  let source_raw =
    match source_member with
    | `Null -> memory_search_source_to_string Current
    | `String raw -> raw
    | other -> Yojson.Safe.to_string other
  in
  let parsed_source =
    match source_member with
    | `Null -> Some Current
    | `String raw -> memory_search_source_of_string_opt raw
    | _ -> None
  in
  match parsed_source with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json
         ~fields:
           [ "error_kind", `String "invalid_memory_search_source"
           ; "provided_source", `String source_raw
           ; ( "supported_sources"
             , `List (List.map (fun s -> `String s) valid_memory_search_source_strings) )
           ]
         "invalid keeper_memory_search source")
  | Some source ->
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    let source_label = memory_search_source_to_string source in
    let durable_json ~fact_jsons ~fact_total ~total_matches ~extra_matches ~read_errors ~read_error_fields =
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int fact_total
         ; "match_count", `Int total_matches
         ; "matches", `List (fact_jsons @ extra_matches)
         ]
         @ (if total_matches = 0 && not read_errors then [ "no_match", `Bool true ] else [])
         @ read_error_fields
         @ memory_writer_fields ~config ~keeper_name:meta.name)
    in
    (* A commit log line that does not decode is left out of the results, and
       both the model and the operator are told: what it removed is not known,
       so an empty answer is not proof. The log is append-only, so the same
       count comes back on every search. For source=all, a log that cannot be
       read at all is named beside the stores that answered rather than taking
       their results with it. *)
    let left_fields ~(left : Keeper_memory_left.t option) ~unavailable =
      (match left with
       | None -> []
       | Some { unreadable = 0; _ } -> []
       | Some { unreadable; _ } ->
         Log.Keeper.warn
           ~keeper_name:meta.name
           "keeper_memory_search left out %d Memory commit log line(s) it could not read"
           unreadable;
         [ "memory_log_unreadable_lines", `Int unreadable ])
      @
      match unavailable with
      | None -> []
      | Some error ->
        Log.Keeper.warn
          ~keeper_name:meta.name
          "keeper_memory_search answered source=%s without the Memory commit log: %s"
          source_label
          (durable_search_error_detail error);
        [ ( "unavailable_stores"
          , `List
              [ `Assoc
                  [ "store", `String "memory_log"
                  ; "error_kind", `String (durable_search_error_kind_to_string error)
                  ; "detail", `String (durable_search_error_detail error)
                  ]
              ] )
        ]
    in
    let source_verification_fields deferred =
      match deferred with
      | [] -> []
      | sources ->
        [ "source_verification", `Assoc
            [ "status", `String "incomplete"
            ; "deferred_sources", `List (List.map
                (fun (source : Keeper_memory_source_current.file_source) ->
                  `Assoc ["source_path", `String source.path;
                          "source_sha256", `String source.sha256]) sources)
            ; "guidance", `String "Query-matching stored claims could not be verified and were withheld. Retry relevant retrieval before drawing a negative conclusion; no claim body is supplied."
            ] ] in
    let current_stores cursor =
      match search_current_with_successors ~clock ~config ~keepers_dir ~meta ~query ~limit:None with
      | Error _ as error -> error
      | Ok (_facts, matches, fact_total, deferred_sources, successor_fields, successor_incomplete, corpus_revision) ->
        (* Rank the complete current answer, successors included, before
           slicing. The per-page bound must not discard the facts later
           pages need. *)
        let revision = Snapshot_protocol.revision_of_json
            ~namespace:"keeper-current-memory-search-page"
            (`Assoc [ "corpus", `String (corpus_revision ())
                    ; "keeper", `String meta.name
                    ; "workspace", `String config.base_path
                    ; "query", `String query
                    ; "matches", `List (List.map fact_match_to_json matches) ]) in
        (match current_page_offset ~revision ~count:(List.length matches) cursor with
         | Error _ as error -> error
         | Ok offset ->
           let fact_matches = take limit (List.drop offset matches) in
           let next_offset = offset + List.length fact_matches in
           let truncated = next_offset < List.length matches in
           let page_fields =
             [ "truncated", `Bool truncated; "revision", `String revision ]
             @ (if truncated then
                  [ "next_cursor", `String (current_page_cursor ~revision ~offset:next_offset) ]
                else []) in
           Ok
             { output =
                 durable_json
                   ~fact_jsons:(List.map fact_match_to_json fact_matches)
                   ~fact_total
                   ~total_matches:(List.length fact_matches)
                   ~extra_matches:[]
                   ~read_errors:(deferred_sources <> [] || successor_incomplete)
                   ~read_error_fields:(page_fields @ source_verification_fields deferred_sources
                      @ successor_fields)
             ; match_count = List.length fact_matches
             ; durable_candidates = Some fact_total
             ; read_errors = deferred_sources <> [] || successor_incomplete
             ; matched_memory_ids =
                 List.filter_map
                   (fun (matched : fact_match) ->
                      match matched.identity with
                      | Ordinary_memory_id { memory_id; _ } -> Some memory_id
                      | Source_sha256 _ -> None)
                   fact_matches
             })
    in
    (* Source=all combines current facts, absorbed/dropped rows, and history. The match
       tier before the store order ({!answering}): a weaker current fact does
       not take a slot from an absorbed row holding the whole query. The
       explicit all scope is the only combined view. The default current scope
       never silently widens into absorbed history. Only ordinary current facts are
       retrievals; an absorbed row leaves no Retrieved event. *)
    let all_stores () =
      match search_current_with_successors ~clock ~config ~keepers_dir ~meta ~query ~limit:(Some limit) with
      | Error _ as error -> error
      | Ok (facts, fact_matches, fact_total, deferred_sources, successor_fields, successor_incomplete, _corpus_revision) ->
        (
           (* An absorbed fact names the claim that now says it. When that
              claim answers this search too, the absorbed fact says the same
              thing again and is left out, so the claim is not crowded out
              of the limit by the facts it took in. An absorbed fact whose
              claim does not answer is the only way to what it says and
              stays. A claim answers here only when it holds the whole query
              or every term of it: one that shares a single term was found,
              but it does not say what the absorbed fact says. *)
           let answering_claims =
             List.fold_left
               (fun ids (m : fact_match) ->
                  match m.identity with
                  | Ordinary_memory_id { memory_id; _ }
                    when String_util.contains_query_term_ci (fact_match_lookup_text m) query
                         || String_util.contains_all_query_terms_ci (fact_match_lookup_text m) query ->
                    StringSet.add memory_id ids
                  | Ordinary_memory_id _ | Source_sha256 _ -> ids)
               StringSet.empty
               fact_matches
           in
           let left, unavailable =
             match read_left ~keepers_dir ~keeper_id:meta.name ~current:facts with
             | Ok left -> Some left, None
             | Error error -> None, Some error
           in
           let absorbed, dropped =
             match left with
             | None -> [], []
             | Some (left : Keeper_memory_left.t) ->
               ( answering_absorbed ~answered_by:answering_claims ~query ~limit left.absorbed
               , answering_dropped ~query ~limit left.dropped )
           in
           let left_total =
             match left with
             | None -> 0
             | Some left -> List.length left.absorbed + List.length left.dropped
           in
           let history = search_history ~config ~meta ~ctx_work ~query ~limit in
           let candidates =
             List.map (fun match_ -> All_fact match_) fact_matches
             @ List.map (fun match_ -> All_absorbed match_) absorbed
             @ List.map (fun match_ -> All_dropped match_) dropped
             @ List.map (fun message -> All_history message) history.matches
           in
           let whole_query, fragments =
             answering ~claim_of:all_search_match_text ~query candidates
           in
           let selected = take limit (whole_query @ fragments) in
           let read_errors =
             deferred_sources <> []
             || successor_incomplete
             || history_has_read_errors history
             || (match left with Some { unreadable; _ } -> unreadable > 0 | None -> false)
             || unavailable <> None
           in
           Ok
             { output =
                 durable_json
                   ~fact_jsons:(List.map all_search_match_to_json selected)
                   ~fact_total:(fact_total + left_total)
                   ~total_matches:(List.length selected)
                   ~extra_matches:[]
                   ~read_errors
                   ~read_error_fields:
                     ([ "left_guidance", `String left_guidance ]
                      @ left_fields ~left ~unavailable
                      @ history_read_error_fields history
                      @ source_verification_fields deferred_sources
                      @ successor_fields)
             ; match_count = List.length selected
             ; durable_candidates = Some (fact_total + left_total)
             ; read_errors
             ; matched_memory_ids = List.filter_map ordinary_memory_id_of_all_match selected
             })
    in
    (* source=absorbed and source=dropped. No Retrieved event: a fact that
       left is not a current memory, and the events sidecar is about current
       memories. [page] picks the facts of one source and counts
       them. *)
    let left_answer page =
      match read_current_facts ~keepers_dir ~keeper_id:meta.name with
      | Error _ as error -> error
      | Ok current ->
        (match read_left ~keepers_dir ~keeper_id:meta.name ~current with
         | Error _ as error -> error
         | Ok left ->
           let fact_jsons, total = page left in
           let read_errors = left.Keeper_memory_left.unreadable > 0 in
           Ok
             { output =
                 durable_json
                   ~fact_jsons
                   ~fact_total:total
                   ~total_matches:(List.length fact_jsons)
                   ~extra_matches:[]
                   ~read_errors
                   ~read_error_fields:
                     ([ "left_guidance", `String left_guidance ]
                      @ left_fields ~left:(Some left) ~unavailable:None)
             ; match_count = List.length fact_jsons
             ; durable_candidates = Some total
             ; read_errors
             ; matched_memory_ids = []
             })
    in
    let result =
      match source, Safe_ops.safe_member "cursor" args with
      | (Absorbed | Dropped | History | All), (`String _ | `Int _ | `Intlit _ | `Bool _ | `Float _ | `List _ | `Assoc _) ->
        Error Cursor_scope_unsupported
      | (Current | Absorbed | Dropped | History | All), _ ->
      match source with
      | History ->
        let history = search_history ~config ~meta ~ctx_work ~query ~limit in
        let matches = history.matches in
        let no_match = matches = [] && not (history_has_read_errors history) in
        let match_jsons = List.map (fun msg -> `String msg) matches in
        Ok
          { output =
              `Assoc
                ([ "query", `String query
                 ; "source", `String source_label
                 ; "match_count", `Int (List.length matches)
                 ; "matches", `List match_jsons
                 ]
                 @ (if no_match then [ "no_match", `Bool true ] else [])
                 @ history_read_error_fields history)
          ; match_count = List.length matches
          ; durable_candidates = None
          ; read_errors = history_has_read_errors history
          ; matched_memory_ids = []
          }
      | All -> all_stores ()
      | Dropped ->
        left_answer (fun (left : Keeper_memory_left.t) ->
          ( List.map Keeper_memory_left.dropped_to_json
              (answering_dropped ~query ~limit left.dropped)
          , List.length left.dropped ))
      | Absorbed ->
        left_answer (fun (left : Keeper_memory_left.t) ->
          ( List.map Keeper_memory_left.absorbed_to_json
              (answering_absorbed ~answered_by:StringSet.empty ~query ~limit left.absorbed)
          , List.length left.absorbed ))
      | Current ->
        (match current_cursor_of_json (Safe_ops.safe_member "cursor" args) with
         | Error _ as error -> error
         | Ok cursor -> current_stores cursor)
    in
    let record_search_outcome outcome =
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string MemorySearch)
        ~labels:
          [ "source", source_label; "outcome", memory_search_outcome_to_string outcome ]
        ()
    in
    match result with
    | Error error ->
      let rejection = match error with
        | Cursor_invalid | Cursor_stale | Cursor_scope_unsupported -> true
        | Snapshot_read_failed _ | Source_revalidate_failed _
        | Memory_log_read_failed _ -> false in
      if not rejection then record_search_outcome Store_unavailable;
      Keeper_tool_execution.failure
        ~class_:(if rejection then Tool_result.Policy_rejection else Tool_result.Dependency_unavailable)
        ~effect_disposition:(match error with
          | Cursor_stale -> Tool_result.Effect_outcome_unknown
          | Cursor_invalid | Cursor_scope_unsupported
          | Snapshot_read_failed _ | Source_revalidate_failed _
          | Memory_log_read_failed _ -> Tool_result.Proven_pre_effect)
        (error_json
           ~fields:
             [ "error_kind", `String (durable_search_error_kind_to_string error)
             ; "source", `String source_label
             ; "detail", `String (durable_search_error_detail error)
             ]
           (if rejection then "keeper_memory_search refused the page cursor"
            else "keeper_memory_search could not read the durable memory store"))
    | Ok { output = result; match_count; durable_candidates; read_errors; matched_memory_ids } ->
    record_search_outcome
      (match match_count > 0, read_errors with
       | true, (true | false) -> Matched
       | false, false -> No_match
       | false, true -> No_match_partial_read);
    (* Each ordinary fact the model was shown is a retrieval: the
       event is what later says this memory was used. A sidecar that cannot be
       written does not take the results away from the model; it is said in
       the log. *)
    record_memory_events
      ~keepers_dir
      ~meta
      ~now:(Time_compat.now ())
      ~kind:(Keeper_memory_os_events.Retrieved { query })
      matched_memory_ids;
    (* Day-1 search logging: append search event to decisions log. *)
    (try
       let log_entry =
         `Assoc
           ([ "ts_unix", `Float (Time_compat.now ())
            ; "event", `String "memory_search"
            ; "query", `String query
            ; "source", `String source_label
            ; "match_count", `Int match_count
            ; ( "matched_memory_ids"
              , `List (List.map (fun id -> `String id) matched_memory_ids) )
            ; "read_errors", `Bool read_errors
            ]
            @ (* History reads messages, not a store with a candidate count. *)
            (match durable_candidates with
             | Some total -> [ "durable_candidates", `Int total ]
             | None -> [])
            @
            (* The turn that searched, so searches per turn can be counted. A
               direct call outside a Keeper turn has none. *)
            match turn_ref with
            | Some turn_ref -> [ "turn_ref", `String (Ids.Turn_ref.to_string turn_ref) ]
            | None -> [])
       in
       Keeper_types_support.append_decision_record config meta.name log_entry
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string DecisionAuditFlushFailures)
         ~labels:[ "keeper", meta.name ]
         ();
       Log.Keeper.warn ~keeper_name:meta.name
         "memory_search decision-log append failed: %s"
         (Printexc.to_string exn));
    Keeper_tool_execution.success (Yojson.Safe.to_string result)
;;

let keeper_memory_search_json ~config ~meta ~ctx_work ~args =
  (keeper_memory_search_with_outcome ~config ~meta ~ctx_work ~args ()).raw_output
;;

let keeper_context_status_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
  =
  let checkpoint_bytes =
    match Keeper_post_turn.durable_checkpoint_bytes ~config ~meta with
    | Ok bytes -> bytes
    | Error detail -> failwith ("checkpoint byte count unavailable: " ^ detail)
  in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  let memory_facts =
    match read_current_facts ~keepers_dir ~keeper_id:meta.name with
    | Ok facts -> facts
    | Error error -> failwith (durable_search_error_detail error)
  in
  let source_memory_facts_total, source_memory_invalidations_total =
    match
      Keeper_memory_source_current.revalidate
        ~config
        ~meta
        ~keepers_dir
        ~now:(Time_compat.now ())
        ()
    with
    | Ok projection -> List.length projection.facts, List.length projection.invalidations
    | Error detail ->
      Log.Keeper.warn
        ~keeper_name:meta.name
        "source-bound memory status unavailable: %s"
        detail;
      0, 0
  in
  (* Give the keeper sandbox-relative paths from the SSOT so it never needs
     to interpolate host storage paths such as ".masc/playground/<name>/". *)
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  (* The tool description promises sandbox health and paths, not checkout
     identity. Inspecting checkouts runs git inside the guest, and a microvm
     guest that does not answer holds every call for the full 5s remote
     timeout before the status comes back as [filesystem_unavailable]: 3,111 of
     3,113 calls in the 2026-11-10..13 ledger, 2,544 of them 4s or longer.
     [masc_keeper_status] leaves the inspection off by default and takes it as
     an opt-in. *)
  let sandbox_live =
    Keeper_sandbox_control.live_status_json
      ~include_preflight:true
      ~include_repository_checkouts:false
      ~config
      ~meta
      ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
      ~verbose:false
      ()
  in
  Yojson.Safe.to_string
    (`Assoc
        ([ "name", `String meta.name
         ; "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         ; "checkpoint_bytes", Json_util.int_opt_to_json checkpoint_bytes
         ; "message_count", `Int (List.length (messages_of_context ctx_work))
         ]
         @ Keeper_sandbox.context_status_fields sandbox
         @ [ "sandbox_live", sandbox_live
           ; "memory_facts_total", `Int (List.length memory_facts)
           ; "memory_limits", Keeper_memory_limits.to_json
               (Keeper_memory_limits.current memory_facts)
           ; "source_memory_facts_total", `Int source_memory_facts_total
           ; ( "source_memory_invalidations_total"
             , `Int source_memory_invalidations_total )
           ]))
;;

(* --- Explicit memory write surface ------------------------------- *)

include (Keeper_tool_memory_validation :
  module type of Keeper_tool_memory_validation with type fact_store := fact_store)

(* An explicit write is a claim a later turn reads back. It goes to the
   Keeper's Memory writer, which commits it in one line and answers with
   that line (RFC librarian-call-only-proposes §8.5). No local importance,
   recency, or echo heuristic participates.

   With [supersedes] the named fact leaves in the commit the claim arrives
   in. Whose fact it was does not matter: one the Librarian put there is
   superseded like one the Keeper wrote. A [supersedes] that names no
   current fact is refused unless the claim is already current.

   [None]: this process started no Memory writers for the workspace. *)
let write_through_writer
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      (write : Librarian_direct.write)
  : Librarian_machine.write_answer option
  =
  Keeper_memory_writers.find ~base_path:config.base_path
  |> Option.map (fun writers ->
    Librarian_writers.write
      writers
      meta.name
      ~by:Librarian_effects.Keeper
      ~trace:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
      write)
;;

(* The keys of a [keeper_memory_write] receipt that say what the write did.
   The receipts below write them through these names and the repeat guard's
   answer ([memory_write_answer_of_output]) keeps exactly [answer], so the two
   cannot drift apart without the compiler seeing it. Snapshot stamps
   ([revision], [recorded_at]) and counts and prose ([rows_written],
   [what_committed]) are not answer keys. *)
module Write_receipt_key = struct
  let ok = "ok"
  let error_kind = "error_kind"
  let effect_disposition = "effect_disposition"
  let detail = "detail"
  let outcome = "outcome"
  let store = "store"
  let memory_id = "memory_id"
  let identity_disposition = "identity_disposition"
  let basis = "basis"
  let superseded_memory_id = "superseded_memory_id"
  let supersedes = "supersedes"
  let unwritable = "unwritable"
  let source_path = "source_path"
  let source_sha256 = "source_sha256"
  let missing_premise_ids = "missing_premise_ids"
  let removed_memory_ids = "removed_memory_ids"
  let support_invalidations = "support_invalidations"

  let answer =
    [ ok
    ; error_kind
    ; effect_disposition
    ; detail
    ; outcome
    ; store
    ; memory_id
    ; identity_disposition
    ; basis
    ; superseded_memory_id
    ; supersedes
    ; unwritable
    ; source_path
    ; source_sha256
    ; missing_premise_ids
    ; removed_memory_ids
    ; support_invalidations
    ]
  ;;
end

(* What a commit took out of Memory: every fact that left, and the derived
   facts among them that left because a premise did. A retraction and a
   supersession report it in the same two fields. *)
let removal_receipt (effects : Librarian_effects.t) =
  let lost_support
        ((fact : Keeper_memory_os_types.fact), (removal : Librarian_effects.removal))
    =
    match removal with
    | Support_lost { missing } ->
      Some
        (`Assoc
            [ "memory_id", `String (Keeper_memory_os_types.memory_id fact)
            ; ( "missing_premise_ids"
              , `List (List.map (fun premise_id -> `String premise_id) missing) )
            ])
    | Dropped _ | Merged_into _ | Revised_into _ | Superseded_by _ | Retracted _ | Molted _ -> None
  in
  [ ( Write_receipt_key.removed_memory_ids
    , `List
        (List.map
           (fun ((fact : Keeper_memory_os_types.fact), (_ : Librarian_effects.removal)) ->
              `String (Keeper_memory_os_types.memory_id fact))
           effects.removed) )
  ; ( Write_receipt_key.support_invalidations
    , `List (List.filter_map lost_support effects.removed) )
  ]
;;

type memory_write_identity_disposition =
  | Inserted of Keeper_memory_os_types.fact
  | Reobserved

(* What the commit did with the claim it states: added it, or moved the
   [last_seen] of the fact that already said it. [None]: the commit names
   the claim in neither list. *)
let memory_write_identity_disposition ~memory_id (effects : Librarian_effects.t) =
  match
    List.find_opt
      (fun fact -> String.equal (Keeper_memory_os_types.memory_id fact) memory_id)
      effects.added
  with
  | Some fact -> Some (Inserted fact)
  | None -> if List.exists (String.equal memory_id) effects.touched then Some Reobserved else None
;;

(* The basis is the receipt's only for a fact the commit added. A fact seen
   again keeps the basis it had, which the commit does not carry. *)
let memory_write_identity_receipt = function
  | Inserted fact ->
    [ Write_receipt_key.identity_disposition, `String "inserted"
    ; "what_committed", `String "One current fact was inserted. Its memory_id identifies the exact claim bytes; writing those bytes again reuses this identity, without creating another copy."
    ; Write_receipt_key.basis, memory_write_basis_receipt fact.basis
    ]
  | Reobserved ->
    [ Write_receipt_key.identity_disposition, `String "reobserved"
    ; "what_committed", `String "The existing current fact was seen again: only its last_seen moved. No duplicate copy was created. Retracting this memory_id would remove the current fact." ]
;;

(* The receipt fields that say what a write did. [revision] and [recorded_at]
   stamp the snapshot the write landed in and move on every write, including
   a re-observation that changed nothing, so the repeat guard reads the answer
   without them (sangsu 2026-10-05: twelve claims rewritten 1,861 times, each
   receipt different only there). A field this list does not name stays out
   of the answer: a new stamp then cannot hide a loop, and a new field that
   does carry a change costs at most one resume. *)
let memory_write_answer_fields = Write_receipt_key.answer

let memory_write_answer_of_output output_text =
  let names_answer (key, _) = List.exists (String.equal key) memory_write_answer_fields in
  match Yojson.Safe.from_string output_text with
  | `Assoc fields
    when List.exists (fun (key, _) -> String.equal key Write_receipt_key.ok) fields ->
    Some (`Assoc (List.filter names_answer fields))
  | `Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
  | exception Yojson.Json_error _ -> None
;;

let keeper_memory_write_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let respond ~ok ~error_kind extras =
    let head =
      [ Write_receipt_key.ok, `Bool ok
      ; Write_receipt_key.error_kind, `String (memory_write_error_kind_to_string error_kind)
      ]
    in
    if ok
    then Keeper_tool_execution.success (Yojson.Safe.to_string (`Assoc (head @ extras)))
    else (
      let effect_disposition, what_committed = memory_write_failure_effect error_kind in
      let payload =
        `Assoc
          (head
           @ [ ( Write_receipt_key.effect_disposition
               , `String (Tool_result.failure_effect_disposition_to_string effect_disposition) )
             ; "what_committed", `String what_committed
             ]
           @ extras
           (* Which field to change follows from the kind, so no failure site
              states it. *)
           @ memory_write_rejection_fields error_kind)
      in
      Keeper_tool_execution.failure
        ~class_:(class_of_memory_write_error_kind error_kind)
        ~effect_disposition
        (Yojson.Safe.to_string payload))
  in
  match validate_memory_write_args args with
  | Memory_write_invalid { error_kind; extras } ->
    respond ~ok:false ~error_kind extras
  | Memory_write_ok { body; source_path; basis; supersedes } ->
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    (match source_path, basis, supersedes with
     | Some source_path, _, _ ->
       (match
          Result.bind
            (Keeper_memory_os_current.recover_publication ~keepers_dir ~keeper_id:meta.name
             |> Result.map_error (fun detail -> Keeper_memory_source_current.Store_write_failed detail))
            (fun () -> Keeper_memory_source_current.upsert_file_fact
            ~ordinary_facts:(fun () ->
              match
                Keeper_memory_os_current.read_locked_for_keepers_dir
                  ~keepers_dir
                  ~keeper_id:meta.Keeper_meta_contract.name
              with
              | Ok None -> Ok []
              | Ok (Some snapshot) -> Ok snapshot.Keeper_memory_os_current.facts
              | Error message -> Error message)
            ~config
            ~meta
            ~keepers_dir
            ~now:(Time_compat.now ())
            ~claim:body
            ~source_path
            ())
        with
        | Ok snapshot ->
          (match
            List.find_map
              (fun fact ->
                 if String.equal fact.Keeper_memory_source_current.source.path source_path
                 then Some fact.source.sha256
                 else None)
              snapshot.facts
           with
           | Some source_sha256 ->
             respond
               ~ok:true
               ~error_kind:No_memory_write_error
               [ "rows_written", `Int 1
               ; "revision", `Int snapshot.revision
                 (* Same persisted-stamp echo as the current-snapshot branch. *)
               ; ( "recorded_at"
                 , `String
                     (Masc_domain.iso8601_of_unix_seconds snapshot.updated_at) )
               ; Write_receipt_key.outcome, `String "persisted_source_bound_current"
               ; Write_receipt_key.store, `String "source_bound_current_memory"
               ; Write_receipt_key.source_path, `String source_path
               ; Write_receipt_key.source_sha256, `String source_sha256
               ]
           | None ->
             let detail =
               Printf.sprintf
                 "source-bound memory commit omitted its written path: %s"
                 source_path
             in
             Log.Keeper.warn
               "explicit source-bound memory write invariant failed keeper=%s: %s"
               meta.name
               detail;
             respond
               ~ok:false
               ~error_kind:Commit_receipt_inconsistent
               [ "revision", `Int snapshot.revision; Write_receipt_key.detail, `String detail ])
        | Error (Keeper_memory_source_current.Source_read_failed failure) ->
          respond
            ~ok:false
            ~error_kind:(Source_read_failed failure)
            [ Write_receipt_key.detail
            , `String (Keeper_memory_source_current.source_read_failure_to_string failure)
            ]
        | Error (Keeper_memory_source_current.Store_write_failed detail) ->
          Log.Keeper.warn
            "explicit source-bound memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond ~ok:false ~error_kind:(Persistence_failed Source_bound_current) [ Write_receipt_key.detail, `String detail ]
        | exception (Eio.Cancel.Cancelled _ as error) -> raise error
        | exception exn ->
          let detail = Printexc.to_string exn in
          Log.Keeper.warn
            "explicit source-bound memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond ~ok:false ~error_kind:(Persistence_failed Source_bound_current) [ Write_receipt_key.detail, `String detail ])
     | None, _, _ ->
       let memory_id = Keeper_memory_os_types.memory_id_of_claim body in
       let category = Keeper_memory_os_types.Fact in
       let write : Librarian_direct.write =
         match supersedes with
         | None -> Remember { claim = body; category; basis }
         | Some old -> Supersede { old; claim = body; category; basis }
       in
       let named_supersedes =
         Option.fold
           ~none:[]
           ~some:(fun old -> [ Write_receipt_key.supersedes, `String old ])
           supersedes
       in
       let unwritable reason =
         respond
           ~ok:false
           ~error_kind:(Memory_unwritable reason)
           [ Write_receipt_key.unwritable, `String (memory_unwritable_to_string reason) ]
       in
       (* The claim is current and this call changed nothing. *)
       let unchanged ~outcome ~what_committed =
         respond
           ~ok:true
           ~error_kind:No_memory_write_error
           ([ "rows_written", `Int 0
            ; Write_receipt_key.outcome, `String outcome
            ; Write_receipt_key.store, `String "current_memory_snapshot"
            ; Write_receipt_key.memory_id, `String memory_id
            ; "what_committed", `String what_committed
            ]
            @ named_supersedes)
       in
       (match write_through_writer ~config ~meta write with
        | None -> unwritable No_writer_in_process
        | Some (Written commit) ->
          (match memory_write_identity_disposition ~memory_id commit.effects with
           | Some disposition ->
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string MemoryOsExplicitFactWrite)
               ~labels:[ "keeper", meta.name ]
               ();
             respond
               ~ok:true
               ~error_kind:No_memory_write_error
               (memory_write_identity_receipt disposition
                @ [ "rows_written", `Int 1
                  ; "revision", `Int commit.revision
                    (* [recorded_at] echoes the commit line's stamp rather than
                       reading a second clock: the receipt and the stored fact
                       cannot disagree, and the authoring model gets an
                       authoritative UTC time at the exact moment it writes
                       prose claims — hand-typed timestamps in claims have
                       drifted by whole hours (lane-smith, 2026-09-01: a
                       02:42Z event recorded as "03:42Z"). *)
                  ; "recorded_at", `String (Masc_domain.iso8601_of_unix_seconds commit.at)
                  ; Write_receipt_key.outcome, `String "persisted_current_snapshot"
                  ; Write_receipt_key.store, `String "current_memory_snapshot"
                  ; Write_receipt_key.memory_id, `String memory_id
                  ]
                @
                match supersedes with
                | None -> []
                | Some old ->
                  (Write_receipt_key.superseded_memory_id, `String old)
                  :: removal_receipt commit.effects)
           | None ->
             let detail = "the commit names the written claim in neither added nor touched" in
             Log.Keeper.warn
               "explicit current Memory write invariant failed keeper=%s revision=%d: %s"
               meta.name
               commit.revision
               detail;
             respond
               ~ok:false
               ~error_kind:Commit_receipt_inconsistent
               [ "revision", `Int commit.revision; Write_receipt_key.detail, `String detail ])
        | Some Already_held ->
          unchanged
            ~outcome:"already_held"
            ~what_committed:
              "Nothing was written. This claim is already a current fact with another \
               category or basis, and that fact is as it was. To state it this way, \
               retract its memory_id and write the claim again."
        | Some Already_done ->
          unchanged
            ~outcome:"already_superseded"
            ~what_committed:
              "Nothing was written. The claim is current and the fact supersedes names \
               is not."
        | Some Already_absent -> unwritable Answer_of_another_write
        | Some (Refused Unknown_fact) ->
          respond ~ok:false ~error_kind:Supersedes_not_current named_supersedes
        | Some (Refused Supersedes_itself) ->
          respond ~ok:false ~error_kind:Supersedes_self named_supersedes
        | Some (Refused Blank_claim) -> respond ~ok:false ~error_kind:Content_empty []
        | Some (Refused ((Blank_trace | Malformed_derivation) as refusal)) ->
          unwritable (Refused_past_validation refusal)
        | Some (Refused (Premises_missing missing)) ->
          (* A premise that is missing because this write removes it is the
             fact [supersedes] names. *)
          let error_kind =
            match supersedes with
            | Some old when List.exists (String.equal old) missing ->
              Supersedes_premise_of_successor
            | Some _ | None -> Unsupported_derivation
          in
          respond
            ~ok:false
            ~error_kind
            (( Write_receipt_key.missing_premise_ids
             , `List (List.map (fun premise_id -> `String premise_id) missing) )
             :: named_supersedes)
        | Some (Not_a_snapshot refusal) -> unwritable (Not_a_snapshot refusal)
        | Some (Unavailable (Store_stopped stop)) -> unwritable (Store_stopped stop)
        | Some (Unavailable Keeper_retired) -> unwritable Keeper_not_registered
        | exception (Eio.Cancel.Cancelled _ as e) -> raise e
        | exception exn ->
          (* The writer did not answer, so whether its line was appended is
             not known. Presenting the claim as saved would lose it
             silently. *)
          let detail = Printexc.to_string exn in
          Log.Keeper.warn
            "explicit current Memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond
            ~ok:false
            ~error_kind:(Persistence_failed Ordinary_current)
            [ Write_receipt_key.detail, `String detail ]))
;;

(* --- Explicit memory retraction surface -------------------------- *)

let keeper_memory_retract_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let respond ~ok ~error_kind extras =
    let head =
      [ "ok", `Bool ok
      ; "error_kind", `String (memory_retract_error_kind_to_string error_kind)
      ]
    in
    if ok
    then Keeper_tool_execution.success (Yojson.Safe.to_string (`Assoc (head @ extras)))
    else (
      let effect_disposition, what_committed = memory_retract_failure_effect error_kind in
      let payload =
        `Assoc
          (head
           @ [ ( "effect_disposition"
               , `String (Tool_result.failure_effect_disposition_to_string effect_disposition) )
             ; "what_committed", `String what_committed
             ]
           @ extras)
      in
      Keeper_tool_execution.failure
        ~class_:(class_of_memory_retract_error_kind error_kind)
        ~effect_disposition
        (Yojson.Safe.to_string payload))
  in
  match validate_memory_retract_args args with
  | Memory_retract_invalid error_kind -> respond ~ok:false ~error_kind []
  | Memory_retract_ok { memory_id; reason } ->
    let unwritable why =
      respond
        ~ok:false
        ~error_kind:(Retract_unwritable why)
        [ "unwritable", `String (memory_unwritable_to_string why) ]
    in
    (match write_through_writer ~config ~meta (Retract { id = memory_id; reason }) with
     | None -> unwritable No_writer_in_process
     | Some (Written commit) ->
       (* The fact is gone from the snapshot. The commit line keeps it with
          the reason, so it stays in the history if the same claim is later
          stored again. *)
       Log.Keeper.info
         "explicit current Memory retracted keeper=%s revision=%d memory_id=%s removed=%d"
         meta.name
         commit.revision
         memory_id
         (List.length commit.effects.removed);
       respond
         ~ok:true
         ~error_kind:No_memory_retract_error
         ([ "revision", `Int commit.revision
          ; "recorded_at", `String (Masc_domain.iso8601_of_unix_seconds commit.at)
          ; "outcome", `String "retracted_current_fact"
          ; "store", `String "current_memory_snapshot"
          ; "memory_id", `String memory_id
          ; "reason", `String reason
          ]
          @ removal_receipt commit.effects)
     | Some Already_absent ->
       respond ~ok:false ~error_kind:Fact_not_found [ "memory_id", `String memory_id ]
     | Some (Already_held | Already_done) -> unwritable Answer_of_another_write
     | Some (Refused refusal) -> unwritable (Refused_past_validation refusal)
     | Some (Not_a_snapshot refusal) -> unwritable (Not_a_snapshot refusal)
     | Some (Unavailable (Store_stopped stop)) -> unwritable (Store_stopped stop)
     | Some (Unavailable Keeper_retired) -> unwritable Keeper_not_registered
     | exception (Eio.Cancel.Cancelled _ as error) -> raise error
     | exception exn ->
       let detail = Printexc.to_string exn in
       Log.Keeper.warn
         "explicit current Memory retraction failed keeper=%s memory_id=%s: %s"
         meta.name
         memory_id
         detail;
       respond
         ~ok:false
         ~error_kind:Retract_persistence_failed
         [ "detail", `String detail ])
;;

module For_testing = struct
  let successor_candidates_for_query = successor_candidates_for_query
  let read_current_facts ~keepers_dir ~keeper_id =
    Result.map_error
      durable_search_error_detail
      (read_current_facts ~keepers_dir ~keeper_id)
  ;;
end
