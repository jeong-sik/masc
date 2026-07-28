open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_context_runtime
module StringSet = Set_util.StringSet


(* Issue #8484: Variant SSOT for memory search scope. Adding a new
   constructor forces compilation in [memory_search_source_to_string]
   AND extends [valid_memory_search_source_strings]; the schema in
   [tool_shard.ml] mirrors the SSOT (cycle: Tool_shard ->
   Keeper_tool_memory_runtime -> ... -> Tool_shard prevented via local mirror,
   sync test catches drift). The previous code used a string match
   with a wildcard `_ -> memory` branch which silently routed any
   unknown source to memory. Now unknown values are rejected at the
   tool boundary. *)
type memory_search_source =
  | Memory
  | History
  | All

let memory_search_source_to_string = function
  | Memory -> "memory"
  | History -> "history"
  | All -> "all"
;;

let memory_search_source_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "memory" -> Some Memory
  | "history" -> Some History
  | "all" -> Some All
  | _ -> None
;;

let all_memory_search_sources = [ Memory; History; All ]

let valid_memory_search_source_strings =
  List.map memory_search_source_to_string all_memory_search_sources
;;

(* --- Durable fact search (Memory OS store) --- *)

type fact_match =
  { claim : string
  ; category : string
  ; claim_kind : string option
  ; first_seen : float
  ; valid_until : float option
  ; score : float
  }

(* Match + rank over the keeper's Memory OS durable facts. Ranking is the
   matched-token ratio against the claim text, tie-broken by recency
   ([first_seen] desc). Expired facts (past [valid_until]) are excluded the
   same way recall excludes them ([fact_is_current]). *)
let search_durable_facts
      ~(meta : keeper_meta)
      ~(query : string)
      ~(limit : int)
  : fact_match list * int
  =
  let now = Time_compat.now () in
  let current =
    Keeper_memory_os_io.read_facts_all ~keeper_id:meta.name
    |> List.filter (Keeper_memory_os_types.fact_is_current ~now)
  in
  let total_candidates = List.length current in
  let matched =
    if query = ""
    then current
    else
      List.filter
        (fun (fact : Keeper_memory_os_types.fact) ->
          String_util.count_matched_tokens_ci fact.claim query > 0)
        current
  in
  let scored =
    matched
    |> List.map (fun (fact : Keeper_memory_os_types.fact) ->
      let score =
        if query = ""
        then 1.0
        else String_util.matched_token_ratio_ci fact.claim query
      in
      { claim = fact.claim
      ; category = Keeper_memory_os_types.category_to_string fact.category
      ; claim_kind =
          Option.map Keeper_memory_os_types.claim_kind_to_string fact.claim_kind
      ; first_seen = fact.first_seen
      ; valid_until = fact.valid_until
      ; score = Float.round (score *. 1000.0) /. 1000.0
      })
    |> List.sort (fun a b ->
      match Float.compare b.score a.score with
      | 0 -> Float.compare b.first_seen a.first_seen
      | c -> c)
  in
  take limit scored, total_candidates
;;

let fact_match_to_json (m : fact_match) : Yojson.Safe.t =
  `Assoc
    [ "text", `String m.claim
    ; "category", `String m.category
    ; "claim_kind", Json_util.string_opt_to_json m.claim_kind
    ; "first_seen_ts_unix", `Float m.first_seen
    ; "valid_until_ts_unix", Json_util.float_opt_to_json m.valid_until
    ; "score", `Float m.score
    ]
;;

(* --- History search (checkpoint + trace history) --- *)

let search_history
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(query : string)
      ~(limit : int)
  : string list
  =
  (* RFC-0149 §3.1 — aggregation site.  Multiple history files are
     concatenated for search; a per-path Read failure is dropped to
     [[]] so a single corrupt history does not suppress matches from
     the others.  The decision to elide is made *here* rather than
     hidden inside a silent facade — failures still surface via the
     [metric_keeper_memory_recall_read_errors] counter emitted by
     [Keeper_memory_recall.load_history_user_messages_result]. *)
  let current_history =
    match
      Keeper_memory_recall.load_history_user_messages_result
        ~path:
          (Keeper_types_support.keeper_history_path
             config
             (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
        ~max_n:50
    with
    | Ok msgs -> msgs
    | Error _ -> []
  in
  let prev_history =
    meta.runtime.trace_history
    |> List.concat_map (fun old_trace_id ->
      match
        Keeper_memory_recall.load_history_user_messages_result
          ~path:(Keeper_types_support.keeper_history_path config old_trace_id)
          ~max_n:20
      with
      | Ok msgs -> msgs
      | Error _ -> [])
  in
  let checkpoint_user_msgs =
    Keeper_memory_recall.recent_user_messages (messages_of_context ctx_work) ~max_n:100
  in
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  let seen0 =
    List.fold_left
      (fun acc s -> StringSet.add (key_of s) acc)
      StringSet.empty
      checkpoint_user_msgs
  in
  let dedup seen lst =
    List.fold_left
      (fun (acc, seen) s ->
         let k = key_of s in
         if StringSet.mem k seen then acc, seen else s :: acc, StringSet.add k seen)
      ([], seen)
      lst
    |> fun (acc, seen) -> List.rev acc, seen
  in
  let all_candidates =
    checkpoint_user_msgs
    @ fst (dedup seen0 current_history)
    @ fst (dedup (snd (dedup seen0 current_history)) prev_history)
  in
  all_candidates
  |> List.filter (fun msg -> query <> "" && String_util.contains_all_tokens_ci msg query)
  |> List.rev
  |> take limit
;;

(* --- Unified keeper_memory_search dispatch --- *)

let keeper_memory_search_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t)
  =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  let source_raw = Safe_ops.json_string ~default:"memory" "source" args in
  let kind_raw = Safe_ops.json_string ~default:"" "kind" args |> String.trim in
  match memory_search_source_of_string_opt source_raw with
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
  | Some _ when kind_raw <> "" ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json
         ~fields:
           [ "error_kind", `String "memory_search_kind_removed"
           ; "provided_kind", `String kind_raw
           ]
         "the kind filter was removed with the memory bank; matches carry \
          claim_kind and category fields instead")
  | Some source ->
    let source_label = memory_search_source_to_string source in
    let result =
    match source with
    | History ->
      let matches = search_history ~config ~meta ~ctx_work ~query ~limit in
      let no_match = matches = [] in
      let match_jsons = List.map (fun msg -> `String msg) matches in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "match_count", `Int (List.length matches)
         ; "matches", `List match_jsons
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
    | All ->
      let fact_matches, fact_total = search_durable_facts ~meta ~query ~limit in
      let history_limit = max 0 (limit - List.length fact_matches) in
      let history_matches =
        if history_limit > 0
        then search_history ~config ~meta ~ctx_work ~query ~limit:history_limit
        else []
      in
      let total_matches = List.length fact_matches + List.length history_matches in
      let no_match = total_matches = 0 in
      let fact_jsons = List.map fact_match_to_json fact_matches in
      let history_jsons =
        List.map
          (fun msg ->
             `Assoc
               [ "source", `String (memory_search_source_to_string History)
               ; "text", `String msg
               ])
          history_matches
      in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int fact_total
         ; "match_count", `Int total_matches
         ; "matches", `List (fact_jsons @ history_jsons)
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
    | Memory ->
      let matches, total_candidates = search_durable_facts ~meta ~query ~limit in
      let no_match = matches = [] in
      let match_jsons = List.map fact_match_to_json matches in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int total_candidates
         ; "match_count", `Int (List.length matches)
         ; "matches", `List match_jsons
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
  in
  (* Day-1 search logging: append search event to decisions log.
     Extract match_count and top_score from the already-computed result. *)
  let log_match_count =
    match result with
    | `Assoc fields ->
      (match List.assoc_opt "match_count" fields with
       | Some (`Int n) -> n
       | _ -> 0)
    | _ -> 0
  in
  let log_top_score =
    match result with
    | `Assoc fields ->
      (match List.assoc_opt "matches" fields with
       | Some (`List (first :: _)) ->
         (match first with
          | `Assoc mfields ->
            (match List.assoc_opt "score" mfields with
             | Some (`Float s) -> Some s
             | _ -> None)
          | _ -> None)
       | _ -> None)
    | _ -> None
  in
  (try
     let log_entry =
       `Assoc
         ([ "ts_unix", `Float (Time_compat.now ())
          ; "event", `String "memory_search"
          ; "query", `String query
          ; "source", `String source_label
          ; "match_count", `Int log_match_count
          ]
          @
          match log_top_score with
          | Some s -> [ "top_score", `Float s ]
          | None -> [])
     in
     Keeper_types_support.append_jsonl_line
       (Keeper_types_support.keeper_decision_log_path config meta.name)
       log_entry
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
  (keeper_memory_search_with_outcome ~config ~meta ~ctx_work ~args).raw_output
;;

let keeper_context_status_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
  =
  let checkpoint_bytes = Keeper_context_runtime.serialized_bytes ctx_work in
  let memory_facts_total, memory_facts_current =
    let now = Time_compat.now () in
    let facts = Keeper_memory_os_io.read_facts_all ~keeper_id:meta.name in
    ( List.length facts
    , List.length
        (List.filter (Keeper_memory_os_types.fact_is_current ~now) facts) )
  in
  (* Give the keeper sandbox-relative paths from the SSOT so it never needs
     to interpolate host storage paths such as ".masc/playground/<name>/". *)
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  let sandbox_live =
    Keeper_sandbox_control.live_status_json
      ~include_preflight:true
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
         ; "generation", `Int meta.runtime.nonce
         ; "checkpoint_bytes", `Int checkpoint_bytes
         ; "message_count", `Int (List.length (messages_of_context ctx_work))
         ; "last_model_used", `Null
         ]
         @ Keeper_sandbox.context_status_fields sandbox
         @ [ "sandbox_live", sandbox_live
           ; "memory_facts_total", `Int memory_facts_total
           ; "memory_facts_current", `Int memory_facts_current
           ]))
;;

(* --- Explicit memory write (RFC-0035 P4 surface) ----------------- *)

let keeper_memory_write_max_title_chars = 120

(* Upper bound on the composed [**title** content] body. A durable fact is a
   claim, not a document; the bound matches the cap the retired bank enforced
   so existing producers see the same boundary. *)
let keeper_memory_write_max_body_chars = 4096

(* An explicit lifetime is a claim about scope, so it has to be a real
   boundary: a claim that expires today or a decade out is a producer mistake,
   not a lifetime. Rejecting both ends keeps [valid_until] meaningful rather
   than becoming a second way to say "forever". Bound and day arithmetic are
   the shared producer SSOT in [Keeper_memory_os_types] (the librarian
   extraction path declares lifetimes through the same contract). *)
let keeper_memory_write_min_valid_days = 1
let keeper_memory_write_max_valid_days = Keeper_memory_os_types.max_valid_for_days

(* [Safe_ops.json_int] cannot tell "absent" from "0", and 0 days is exactly
   the mistake this field must reject, so the member is read raw. A wrong JSON
   type is its own producer error and keeps its own arm: collapsing it into a
   number would answer a type mistake with a range complaint the caller already
   satisfied. *)
type valid_for_days_arg =
  | Lifetime_absent
  | Lifetime_days of int
  | Lifetime_not_an_integer of string (* the JSON type actually supplied *)

let json_type_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "bool"
  | `Int _ -> "int"
  | `Intlit _ -> "intlit"
  | `Float _ -> "float"
  | `String _ -> "string"
  | `Assoc _ -> "object"
  | `List _ -> "array"
;;

let parse_valid_for_days (args : Yojson.Safe.t) : valid_for_days_arg =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "valid_for_days" fields with
     | None | Some `Null -> Lifetime_absent
     | Some (`Int n) -> Lifetime_days n
     | Some other -> Lifetime_not_an_integer (json_type_name other))
  | _ -> Lifetime_absent
;;

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Workspace.config]. *)
type memory_write_error_kind =
  | Kind_argument_removed
  | Title_too_long
  | Content_empty
  | Content_too_long
  | Invalid_valid_for_days
  | Persistence_failed
  | No_memory_write_error

let memory_write_error_kind_to_string = function
  | Kind_argument_removed -> "kind_argument_removed"
  | Title_too_long -> "title_too_long"
  | Content_empty -> "content_empty"
  | Content_too_long -> "content_too_long"
  | Invalid_valid_for_days -> "invalid_valid_for_days"
  | Persistence_failed -> "persistence_failed"
  | No_memory_write_error -> ""
;;

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; valid_for_days : int option
        (** Producer-declared lifetime (RFC-0351 S2). [None] means the claim
            carries no expiry, which is what every stored fact says today
            because nothing has ever been able to say otherwise. *)
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

(* Each way a lifetime can be wrong gets its own answer. A producer that sent
   the wrong JSON type has not violated the range, and telling it the range is
   1-365 sends it looking for a bug it does not have. *)
let check_lifetime lifetime : (int option, memory_write_validation) result =
  let out_of_range d =
    d < keeper_memory_write_min_valid_days || d > keeper_memory_write_max_valid_days
  in
  match lifetime with
  | Lifetime_absent -> Ok None
  | Lifetime_not_an_integer provided_type ->
    Error
      (Memory_write_invalid
         { error_kind = Invalid_valid_for_days
         ; extras =
             [ "reason", `String "not_an_integer"
             ; "provided_type", `String provided_type
             ]
         })
  | Lifetime_days d when out_of_range d ->
    Error
      (Memory_write_invalid
         { error_kind = Invalid_valid_for_days
         ; extras =
             [ "reason", `String "out_of_range"
             ; "provided_days", `Int d
             ; "min_days", `Int keeper_memory_write_min_valid_days
             ; "max_days", `Int keeper_memory_write_max_valid_days
             ]
         })
  | Lifetime_days d -> Ok (Some d)
;;

let validate_memory_write_args (args : Yojson.Safe.t) : memory_write_validation =
  let provided_kind =
    match args with
    | `Assoc fields ->
      (match List.assoc_opt "kind" fields with
       | None | Some `Null -> None
       | Some value -> Some value)
    | _ -> None
  in
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let content = Safe_ops.json_string ~default:"" "content" args |> String.trim in
  let lifetime = parse_valid_for_days args in
  match provided_kind with
  | Some value ->
    (* The kind/horizon vocabulary was retired with the memory bank
       (RFC keeper-memory-consolidation Stage 4): every write is a durable
       fact. A caller still sending [kind] gets a typed rejection, not a
       silently ignored argument. *)
    Memory_write_invalid
      { error_kind = Kind_argument_removed
      ; extras =
          [ ( "provided_kind"
            , match value with
              | `String s -> `String s
              | other -> `String (json_type_name other) )
          ]
      }
  | None ->
  if String.length title > keeper_memory_write_max_title_chars
  then
    Memory_write_invalid
      { error_kind = Title_too_long
      ; extras =
          [ "max_chars", `Int keeper_memory_write_max_title_chars
          ; "title_chars", `Int (String.length title)
          ]
      }
  else if content = ""
  then Memory_write_invalid { error_kind = Content_empty; extras = [] }
  else (
    match check_lifetime lifetime with
    | Error invalid -> invalid
    | Ok valid_for_days ->
      let body =
        if title = "" then content else Printf.sprintf "**%s** %s" title content
      in
      if String.length body > keeper_memory_write_max_body_chars
      then
        Memory_write_invalid
          { error_kind = Content_too_long
          ; extras =
              [ "max_chars", `Int keeper_memory_write_max_body_chars
              ; "body_chars", `Int (String.length body)
              ]
          }
      else Memory_write_ok { body; valid_for_days })
;;

(* An explicit write is a durable claim a later turn reads back; the Memory OS
   fact store is the only store it reaches (the turn-scoped bank and its
   kind/horizon vocabulary are gone — RFC keeper-memory-consolidation Stage 4).

   Provenance is this turn and [tool_call_id] is [None]: the claim is the
   model's own assertion, not an observation carried out of some other tool's
   result, and that field records where an observation came from.

   The fold is the librarian's (RFC-0285 §8), unchanged: a claim whose identity
   was just recall-injected is the model restating what it read, and must not
   advance the truth anchor recall's recency ranking reads. Writing through the
   same rule is the point — an explicit write is not a way around it. *)
let append_durable_fact
      ~(meta : keeper_meta)
      ~(body : string)
      ~(valid_for_days : int option)
  : Keeper_memory_os_io.fact_merge_stats
  =
  let keeper_id = meta.name in
  let now = Time_compat.now () in
  let fact : Keeper_memory_os_types.fact =
    { claim = body
    ; category = Keeper_memory_os_types.Fact
    ; claim_kind = Some Keeper_memory_os_types.Durable_knowledge
    ; source =
        { trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
        ; turn = meta.runtime.usage.total_turns
        ; tool_call_id = None
        }
    ; observed_by = []
    ; first_seen = now
    ; valid_until =
        (* RFC-0351 S2. Recall has always dropped expired facts
           ([Keeper_memory_os_types.fact_is_current]), but no producer could
           ever set the boundary, so every stored fact reads as permanent —
           747 of 747 across the live fleet. This is the first writer. The
           lifetime is the producer's own claim about scope, not a rule
           inferred from the text. *)
        Option.map (Keeper_memory_os_types.valid_until_of_days ~now) valid_for_days
    ; last_verified_at = None
    ; schema_version = Keeper_memory_os_types.schema_version
    ; claim_id = None
    ; reinforcement_count = 0
    }
  in
  let merge ~existing ~incoming =
    let provenance =
      let key = Keeper_memory_os_types.claim_identity incoming in
      if Keeper_recall_injection_window.recently_injected ~keeper_id ~key
      then (
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string MemoryOsReobserveEchoSuppressed)
          ~labels:[ "keeper", keeper_id ]
          ();
        Keeper_memory_os_policy.Recalled_echo)
      else Keeper_memory_os_policy.Independent_observation
    in
    Keeper_memory_os_policy.reobserve_fact ~now ~provenance ~existing ~incoming
  in
  let stats =
    File_lock_eio.with_lock (Keeper_memory_os_io.facts_path ~keeper_id) (fun () ->
      Keeper_memory_os_io.merge_facts ~keeper_id ~merge ~incoming:[ fact ])
  in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string MemoryOsExplicitFactWrite)
    ~labels:[ "keeper", keeper_id ]
    ();
  stats
;;

let keeper_memory_write_with_outcome
      ~config:(_ : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let respond ~ok ~error_kind extras =
    let error_kind = memory_write_error_kind_to_string error_kind in
    let payload =
      Yojson.Safe.to_string
        (`Assoc ([ "ok", `Bool ok; "error_kind", `String error_kind ] @ extras))
    in
    if ok
    then Keeper_tool_execution.success payload
    else Keeper_tool_execution.failure ~class_:Tool_result.Workflow_rejection payload
  in
  match validate_memory_write_args args with
  | Memory_write_invalid { error_kind; extras } ->
    respond ~ok:false ~error_kind extras
  | Memory_write_ok { body; valid_for_days } ->
    (match append_durable_fact ~meta ~body ~valid_for_days with
     | stats ->
       let merged = stats.Keeper_memory_os_io.merged in
       respond
         ~ok:true
         ~error_kind:No_memory_write_error
         [ "rows_written", `Int 1
         ; ( "outcome"
           , `String (if merged > 0 then "merged_into_existing_claim" else "persisted")
           )
         ; "store", `String "durable_fact_store"
         ]
     | exception (Eio.Cancel.Cancelled _ as e) -> raise e
     | exception exn ->
       (* The store is the only place a long-term claim survives, so a
          failed write is reported as failed. Presenting it as saved would
          lose the claim silently. *)
       let detail = Printexc.to_string exn in
       Log.Keeper.warn
         "explicit durable fact write failed keeper=%s: %s"
         meta.name
         detail;
       respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ])
;;

let keeper_memory_write_json ~config ~meta ~args =
  (keeper_memory_write_with_outcome ~config ~meta ~args).raw_output
;;
