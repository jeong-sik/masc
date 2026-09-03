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

type fact_store =
  | Ordinary_current
  | Source_bound_current

let fact_store_to_string = function
  | Ordinary_current -> "current_memory_snapshot"
  | Source_bound_current -> "source_bound_current_memory"
;;

type fact_identity =
  | Ordinary_memory_id of string
  | Source_sha256 of string

type fact_match =
  { identity : fact_identity
  ; claim : string
  ; category : string
  ; basis : Keeper_memory_os_types.basis
  ; store : fact_store
  }

(* The durable stores a search reads. Either failing is the store, not the
   query: the arguments were never judged, so the failure is typed as a
   dependency that did not answer rather than raised as an exception the
   dispatcher would print back to the model as [Failure(...)]. *)
type durable_search_error =
  | Snapshot_read_failed of string
  | Source_revalidate_failed of string

let durable_search_error_kind_to_string = function
  | Snapshot_read_failed _ -> "snapshot_read_failed"
  | Source_revalidate_failed _ -> "source_revalidate_failed"
;;

let durable_search_error_detail = function
  | Snapshot_read_failed detail | Source_revalidate_failed detail -> detail
;;

let read_current_facts ~keepers_dir ~keeper_id =
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None -> Ok []
  | Ok (Some snapshot) -> Ok snapshot.facts
  | Error detail -> Error (Snapshot_read_failed detail)
;;

(* Filter the keeper's current facts by an explicit query substring while
   preserving snapshot order. Search does not assign value scores or introduce
   a recency authority. *)
let search_durable_facts
      ~(config : Workspace.config)
      ~(keepers_dir : string)
      ~(meta : keeper_meta)
      ~(query : string)
      ~(limit : int)
  : (fact_match list * int, durable_search_error) result
  =
  match read_current_facts ~keepers_dir ~keeper_id:meta.name with
  | Error _ as error -> error
  | Ok facts ->
  match
    Keeper_memory_source_current.revalidate
      ~config
      ~meta
      ~keepers_dir
      ~now:(Time_compat.now ())
      ()
  with
  | Error detail -> Error (Source_revalidate_failed detail)
  | Ok source_projection ->
  let source_facts = source_projection.facts in
  let total_candidates = List.length facts + List.length source_facts in
  let matched =
    if String.equal query ""
    then facts
    else
      List.filter
        (fun (fact : Keeper_memory_os_types.fact) ->
          String_util.contains_substring_ci fact.claim query)
        facts
  in
  let source_matched =
    if String.equal query ""
    then source_facts
    else
      List.filter
        (fun (fact : Keeper_memory_source_current.fact) ->
           String_util.contains_substring_ci fact.claim query)
        source_facts
  in
  let ordinary_matches =
    matched
    |> List.map (fun (fact : Keeper_memory_os_types.fact) ->
      { claim = fact.claim
      ; identity = Ordinary_memory_id (Keeper_memory_os_types.memory_id fact)
      ; category = Keeper_memory_os_types.category_to_string fact.category
      ; basis = fact.basis
      ; store = Ordinary_current
      })
  in
  let source_matches =
    List.map
      (fun (fact : Keeper_memory_source_current.fact) ->
      { identity = Source_sha256 fact.source.sha256
      ; claim = fact.claim
      ; category = "fact"
      ; basis = Keeper_memory_os_types.Observed Keeper_memory_os_types.Transcript
      ; store = Source_bound_current
      })
      source_matched
  in
  Ok (take limit (ordinary_matches @ source_matches), total_candidates)
;;

let fact_match_to_json (m : fact_match) : Yojson.Safe.t =
  `Assoc
    ([ "text", `String m.claim
     ; "category", `String m.category
     ; "basis", Keeper_memory_os_types.basis_to_json m.basis
     ; "store", `String (fact_store_to_string m.store)
     ]
     @
     match m.identity with
     | Ordinary_memory_id memory_id -> [ "memory_id", `String memory_id ]
     | Source_sha256 sha256 -> [ "source_sha256", `String sha256 ])
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
  (* [Safe_ops.json_string] returns its default for an absent key and for a key
     whose value is not a string, so {"source": ["memory"]} used to reach Memory
     while the merely misspelled {"source": "memry"} was refused below. Read the
     member so a non-string lands on the same rejection a bad string does; the
     schema documents "memory" as the default for absence only. *)
  let source_member = Safe_ops.safe_member "source" args in
  let source_raw =
    match source_member with
    | `Null -> memory_search_source_to_string Memory
    | `String raw -> raw
    | other -> Yojson.Safe.to_string other
  in
  let parsed_source =
    match source_member with
    | `Null -> Some Memory
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
    let durable_json ~fact_jsons ~fact_total ~total_matches ~extra_matches =
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int fact_total
         ; "match_count", `Int total_matches
         ; "matches", `List (fact_jsons @ extra_matches)
         ]
         @ if total_matches = 0 then [ "no_match", `Bool true ] else [])
    in
    let result =
      match source with
      | History ->
        let matches = search_history ~config ~meta ~ctx_work ~query ~limit in
        let no_match = matches = [] in
        let match_jsons = List.map (fun msg -> `String msg) matches in
        Ok
          (`Assoc
              ([ "query", `String query
               ; "source", `String source_label
               ; "match_count", `Int (List.length matches)
               ; "matches", `List match_jsons
               ]
               @ if no_match then [ "no_match", `Bool true ] else []))
      | All ->
        (match search_durable_facts ~config ~keepers_dir ~meta ~query ~limit with
         | Error _ as error -> error
         | Ok (fact_matches, fact_total) ->
           let history_limit = max 0 (limit - List.length fact_matches) in
           let history_matches =
             if history_limit > 0
             then search_history ~config ~meta ~ctx_work ~query ~limit:history_limit
             else []
           in
           let total_matches =
             List.length fact_matches + List.length history_matches
           in
           let extra_matches =
             List.map
               (fun msg ->
                  `Assoc
                    [ "source", `String (memory_search_source_to_string History)
                    ; "text", `String msg
                    ])
               history_matches
           in
           Ok
             (durable_json
                ~fact_jsons:(List.map fact_match_to_json fact_matches)
                ~fact_total
                ~total_matches
                ~extra_matches))
      | Memory ->
        (match search_durable_facts ~config ~keepers_dir ~meta ~query ~limit with
         | Error _ as error -> error
         | Ok (matches, total_candidates) ->
           Ok
             (durable_json
                ~fact_jsons:(List.map fact_match_to_json matches)
                ~fact_total:total_candidates
                ~total_matches:(List.length matches)
                ~extra_matches:[]))
    in
    match result with
    | Error error ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Dependency_unavailable
        ~effect_disposition:Tool_result.Proven_pre_effect
        (error_json
           ~fields:
             [ "error_kind", `String (durable_search_error_kind_to_string error)
             ; "source", `String source_label
             ; "detail", `String (durable_search_error_detail error)
             ]
           "keeper_memory_search could not read the durable memory store")
    | Ok result ->
    (* Day-1 search logging: append search event to decisions log. *)
    let log_match_count =
      match result with
      | `Assoc fields ->
        (match List.assoc_opt "match_count" fields with
         | Some (`Int n) -> n
         | _ -> 0)
      | _ -> 0
    in
    (try
       let log_entry =
         `Assoc
           [ "ts_unix", `Float (Time_compat.now ())
           ; "event", `String "memory_search"
           ; "query", `String query
           ; "source", `String source_label
           ; "match_count", `Int log_match_count
           ]
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
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  let memory_facts_total =
    match read_current_facts ~keepers_dir ~keeper_id:meta.name with
    | Ok facts -> List.length facts
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
         ; "checkpoint_bytes", `Int checkpoint_bytes
         ; "message_count", `Int (List.length (messages_of_context ctx_work))
         ]
         @ Keeper_sandbox.context_status_fields sandbox
         @ [ "sandbox_live", sandbox_live
           ; "memory_facts_total", `Int memory_facts_total
           ; "source_memory_facts_total", `Int source_memory_facts_total
           ; ( "source_memory_invalidations_total"
             , `Int source_memory_invalidations_total )
           ]))
;;

(* --- Explicit memory write surface ------------------------------- *)

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Workspace.config]. *)
type memory_write_error_kind =
  | Content_empty
  | Source_path_invalid
  | Source_read_failed of Keeper_memory_source_current.source_read_failure
  | Derivation_incomplete
  | Derivation_invalid
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Unsupported_derivation
  | Persistence_failed
  | Commit_receipt_inconsistent
  | No_memory_write_error

let memory_write_error_kind_to_string = function
  | Content_empty -> "content_empty"
  | Source_path_invalid -> "source_path_invalid"
  | Source_read_failed _ -> "source_read_failed"
  | Derivation_incomplete -> "derivation_incomplete"
  | Derivation_invalid -> "derivation_invalid"
  | Derived_source_path_unsupported -> "derived_source_path_unsupported"
  | Board_ref_invalid -> "board_ref_invalid"
  | Board_comment_without_post -> "board_comment_without_post"
  | Board_ref_with_derivation_unsupported -> "board_ref_with_derivation_unsupported"
  | Board_ref_with_source_path_unsupported -> "board_ref_with_source_path_unsupported"
  | Unsupported_derivation -> "unsupported_derivation"
  | Persistence_failed -> "persistence_failed"
  | Commit_receipt_inconsistent -> "commit_receipt_inconsistent"
  | No_memory_write_error -> ""
;;

(* What the model does next depends on which side failed. Input the caller
   can correct is a policy rejection; a store or source file that could not
   be read or written is a dependency the arguments never reached; the
   "no error" kind never travels with ok=false, so reaching it here is a
   producer bug. *)
let class_of_memory_write_error_kind = function
  | Content_empty
  | Source_path_invalid
  | Derivation_incomplete
  | Derivation_invalid
  | Derived_source_path_unsupported
  | Board_ref_invalid
  | Board_comment_without_post
  | Board_ref_with_derivation_unsupported
  | Board_ref_with_source_path_unsupported
  | Unsupported_derivation
  | Source_read_failed
      ( Keeper_memory_source_current.Source_path_rejected _
      | Keeper_memory_source_current.Source_missing
      | Keeper_memory_source_current.Source_not_a_regular_file
      | Keeper_memory_source_current.Source_too_large _ ) ->
    Tool_result.Policy_rejection
  | Source_read_failed (Keeper_memory_source_current.Source_io_failed _)
  | Persistence_failed ->
    Tool_result.Dependency_unavailable
  (* The store committed and then did not show what it committed: a
     producer bug, not a dependency that can answer on a later turn. *)
  | Commit_receipt_inconsistent | No_memory_write_error -> Tool_result.Runtime_failure
;;

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; source_path : string option
      ; basis : Keeper_memory_os_types.basis
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

let validate_memory_write_args (args : Yojson.Safe.t) : memory_write_validation =
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let content = Safe_ops.json_string ~default:"" "content" args |> String.trim in
  let source_path =
    match Safe_ops.safe_member "source_path" args with
    | `Null -> Ok None
    | `String raw ->
      let path = String.trim raw in
      if
        String.equal path ""
        || String.contains path '\n'
        || String.contains path '\r'
      then Error Source_path_invalid
      else Ok (Some path)
    | _ -> Error Source_path_invalid
  in
  (* A Board reference is an observation source: the claim was read from a
     post, optionally from one of its comments. The ids are parsed by the
     Board's own grammar; whether the post still exists is not checked at
     write time and no reader checks it yet (RFC-0402 piece 2). *)
  let board_ref =
    let optional_string key =
      match Safe_ops.safe_member key args with
      | `Null -> Ok None
      | `String raw ->
        let value = String.trim raw in
        if String.equal value "" then Error Board_ref_invalid else Ok (Some value)
      | _ -> Error Board_ref_invalid
    in
    match optional_string "board_post_id", optional_string "board_comment_id" with
    | Error error, _ | _, Error error -> Error error
    | Ok None, Ok None -> Ok None
    | Ok None, Ok (Some _) -> Error Board_comment_without_post
    | Ok (Some post_id), Ok comment_id ->
      (match Keeper_memory_os_types.board_ref_of_ids ~post_id ~comment_id with
       | Ok board -> Ok (Some board)
       | Error _ -> Error Board_ref_invalid)
  in
  let derivation =
    match Safe_ops.safe_member "rule_id" args, Safe_ops.safe_member "premise_ids" args with
    | `Null, `Null ->
      (match board_ref with
       | Ok (Some board) ->
         Ok (Keeper_memory_os_types.Observed (Keeper_memory_os_types.Board board))
       | Ok None | Error _ ->
         Ok (Keeper_memory_os_types.Observed Keeper_memory_os_types.Transcript))
    | `String raw_rule_id, `List premise_values ->
      let rule_id = String.trim raw_rule_id in
      let rec premise_ids seen acc = function
        | [] ->
          if String.equal rule_id "" || acc = []
          then Error Derivation_invalid
          else
            Ok
              (Keeper_memory_os_types.Derived
                 [ { rule_id; premise_ids = List.rev acc } ])
        | `String raw :: rest ->
          let premise_id = raw in
          if
            not (Keeper_memory_os_types.is_memory_id premise_id)
            || StringSet.mem premise_id seen
          then Error Derivation_invalid
          else
            premise_ids
              (StringSet.add premise_id seen)
              (premise_id :: acc)
              rest
        | _ -> Error Derivation_invalid
      in
      premise_ids StringSet.empty [] premise_values
    | (`Null, _) | (_, `Null) -> Error Derivation_incomplete
    | _ -> Error Derivation_invalid
  in
  match source_path, derivation, board_ref with
  | Error error_kind, _, _ | _, Error error_kind, _ | _, _, Error error_kind ->
    Memory_write_invalid { error_kind; extras = [] }
  | Ok source_path, Ok basis, Ok board_ref ->
    if
      Option.is_some source_path
      && (match basis with
          | Keeper_memory_os_types.Observed _ -> false
          | Keeper_memory_os_types.Derived _ -> true)
    then
      Memory_write_invalid
        { error_kind = Derived_source_path_unsupported; extras = [] }
    else if
      Option.is_some board_ref
      && (match basis with
          | Keeper_memory_os_types.Observed _ -> false
          | Keeper_memory_os_types.Derived _ -> true)
    then
      Memory_write_invalid
        { error_kind = Board_ref_with_derivation_unsupported; extras = [] }
    else if Option.is_some board_ref && Option.is_some source_path
    then
      Memory_write_invalid
        { error_kind = Board_ref_with_source_path_unsupported; extras = [] }
    else if content = ""
    then Memory_write_invalid { error_kind = Content_empty; extras = [] }
    else
      let body =
        if title = "" then content else Printf.sprintf "**%s** %s" title content
      in
      Memory_write_ok { body; source_path; basis }
;;

(* The observed arms echo the stored wire shape; the derived arm reports a
   count instead of the derivations. *)
let memory_write_basis_receipt = function
  | Keeper_memory_os_types.Observed _ as basis ->
    Keeper_memory_os_types.basis_to_json basis
  | Keeper_memory_os_types.Derived derivations ->
    `Assoc
      [ "kind", `String "derived"
      ; "proof_count", `Int (List.length derivations)
      ]
;;

(* An explicit write is a claim a later turn reads back; the current Memory OS
   snapshot is the only store it reaches.

   No local importance, recency, or echo heuristic participates. The explicit
   write upserts one exact identity; the Librarian remains responsible for
   deciding the complete current selection on its next pass. *)
let upsert_explicit_fact
      ~(keepers_dir : string)
      ~(meta : keeper_meta)
      ~(body : string)
      ~(basis : Keeper_memory_os_types.basis)
  : (Keeper_memory_os_current.t, Keeper_memory_os_current.upsert_error) result
  =
  let keeper_id = meta.name in
  let now = Time_compat.now () in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let fact : Keeper_memory_os_types.fact =
    { claim = body
    ; category = Keeper_memory_os_types.Fact
    ; first_seen = now
    ; last_seen = now
    ; reinforcement = 0
    ; origin = { kind = Keeper_memory_os_types.Authored; trace_id }
    ; basis
    }
  in
  let result =
    Keeper_memory_os_current.upsert_fact
      ~keepers_dir
      ~keeper_id
      ~now
      ~source:
        { kind = Keeper_memory_os_current.Explicit_write
        ; trace_id
        }
      fact
  in
  (match result with
   | Ok _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string MemoryOsExplicitFactWrite)
       ~labels:[ "keeper", keeper_id ]
       ()
   | Error _ -> ());
  result
;;

let keeper_memory_write_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let respond
        ?memory_revision
        ?(effect_disposition = Tool_result.Effect_outcome_unknown)
        ~ok
        ~error_kind
        extras
    =
    let class_ = class_of_memory_write_error_kind error_kind in
    let error_kind = memory_write_error_kind_to_string error_kind in
    let payload =
      Yojson.Safe.to_string
        (`Assoc ([ "ok", `Bool ok; "error_kind", `String error_kind ] @ extras))
    in
    if ok
    then
      let completed = Keeper_tool_execution.success payload in
      Option.fold
        ~none:completed
        ~some:(fun revision ->
          Keeper_tool_execution.with_memory_write_receipt ~revision completed)
        memory_revision
    else
      Keeper_tool_execution.failure ~class_ ~effect_disposition payload
  in
  match validate_memory_write_args args with
  | Memory_write_invalid { error_kind; extras } ->
    respond
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~ok:false
      ~error_kind
      extras
  | Memory_write_ok { body; source_path; basis } ->
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    (match source_path with
     | Some source_path ->
       (match
          Keeper_memory_source_current.upsert_file_fact
            ~config
            ~meta
            ~keepers_dir
            ~now:(Time_compat.now ())
            ~claim:body
            ~source_path
            ()
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
               ~memory_revision:snapshot.revision
               ~ok:true
               ~error_kind:No_memory_write_error
               [ "rows_written", `Int 1
               ; "revision", `Int snapshot.revision
                 (* Same persisted-stamp echo as the current-snapshot branch. *)
               ; ( "recorded_at"
                 , `String
                     (Masc_domain.iso8601_of_unix_seconds snapshot.updated_at) )
               ; "outcome", `String "persisted_source_bound_current"
               ; "store", `String "source_bound_current_memory"
               ; "source_path", `String source_path
               ; "source_sha256", `String source_sha256
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
               [ "detail", `String detail ])
        | Error (Keeper_memory_source_current.Source_read_failed failure) ->
          respond
            ~effect_disposition:Tool_result.Proven_pre_effect
            ~ok:false
            ~error_kind:(Source_read_failed failure)
            [ "detail"
            , `String (Keeper_memory_source_current.source_read_failure_to_string failure)
            ]
        | Error (Keeper_memory_source_current.Store_write_failed detail) ->
          Log.Keeper.warn
            "explicit source-bound memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ]
        | exception (Eio.Cancel.Cancelled _ as error) -> raise error
        | exception exn ->
          let detail = Printexc.to_string exn in
          Log.Keeper.warn
            "explicit source-bound memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ])
     | None ->
    (match upsert_explicit_fact ~keepers_dir ~meta ~body ~basis with
     | Ok snapshot ->
       let written_fact =
         List.find_opt
           (fun fact -> String.equal fact.Keeper_memory_os_types.claim body)
           snapshot.facts
       in
       (match written_fact with
        | Some written_fact ->
          respond
            ~memory_revision:snapshot.revision
            ~ok:true
            ~error_kind:No_memory_write_error
            [ "rows_written", `Int 1
            ; "revision", `Int snapshot.revision
              (* [recorded_at] echoes the persisted snapshot stamp rather than
                 reading a second clock: the receipt and the stored fact cannot
                 disagree, and the authoring model gets an authoritative UTC
                 time at the exact moment it writes prose claims — hand-typed
                 timestamps in claims have drifted by whole hours (lane-smith,
                 2026-09-01: a 02:42Z event recorded as "03:42Z"). *)
            ; ( "recorded_at"
              , `String
                  (Masc_domain.iso8601_of_unix_seconds snapshot.updated_at) )
            ; "outcome", `String "persisted_current_snapshot"
            ; "store", `String "current_memory_snapshot"
            ; ( "memory_id"
              , `String (Keeper_memory_os_types.memory_id written_fact) )
            ; "basis", memory_write_basis_receipt written_fact.basis
            ]
        | None ->
          respond
            ~effect_disposition:Tool_result.Proven_post_effect
            ~ok:false
            ~error_kind:Commit_receipt_inconsistent
            [ "revision", `Int snapshot.revision
            ; ( "detail"
              , `String
                  "committed current Memory snapshot omitted the written fact" )
            ])
     | Error (Keeper_memory_os_current.Unsupported_derivation invalidation) ->
       respond
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~ok:false
         ~error_kind:Unsupported_derivation
         [ ( "missing_premise_ids"
           , `List
               (List.map
                  (fun premise_id -> `String premise_id)
                  invalidation.missing_premise_ids) )
         ]
     | Error (Keeper_memory_os_current.Upsert_persistence_failed detail) ->
       Log.Keeper.warn
         "explicit current Memory write failed keeper=%s: %s"
         meta.name
         detail;
       respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ]
     | exception (Eio.Cancel.Cancelled _ as e) -> raise e
     | exception exn ->
       (* The store is the only place a long-term claim survives, so a
          failed write is reported as failed. Presenting it as saved would
          lose the claim silently. *)
       let detail = Printexc.to_string exn in
       Log.Keeper.warn
         "explicit current Memory write failed keeper=%s: %s"
         meta.name
         detail;
       respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ]))
;;

(* --- Explicit memory retraction surface -------------------------- *)

type memory_retract_error_kind =
  | Memory_id_invalid
  | Reason_empty
  | Fact_not_found
  | Retract_persistence_failed
  | No_memory_retract_error

let memory_retract_error_kind_to_string = function
  | Memory_id_invalid -> "memory_id_invalid"
  | Reason_empty -> "reason_empty"
  | Fact_not_found -> "fact_not_found"
  | Retract_persistence_failed -> "persistence_failed"
  | No_memory_retract_error -> ""
;;

let class_of_memory_retract_error_kind = function
  | Memory_id_invalid | Reason_empty -> Tool_result.Policy_rejection
  | Fact_not_found -> Tool_result.Workflow_rejection
  | Retract_persistence_failed -> Tool_result.Dependency_unavailable
  | No_memory_retract_error -> Tool_result.Runtime_failure
;;

type memory_retract_validation =
  | Memory_retract_ok of
      { memory_id : string
      ; reason : string
      }
  | Memory_retract_invalid of memory_retract_error_kind

let validate_memory_retract_args (args : Yojson.Safe.t) =
  let memory_id = Safe_ops.json_string ~default:"" "memory_id" args in
  let reason = Safe_ops.json_string ~default:"" "reason" args |> String.trim in
  if not (Keeper_memory_os_types.is_memory_id memory_id)
  then Memory_retract_invalid Memory_id_invalid
  else if String.equal reason ""
  then Memory_retract_invalid Reason_empty
  else Memory_retract_ok { memory_id; reason }
;;

let support_invalidation_receipt
      (invalidation : Keeper_memory_os_current.support_invalidation)
  =
  `Assoc
    [ ( "memory_id"
      , `String (Keeper_memory_os_types.memory_id invalidation.fact) )
    ; ( "missing_premise_ids"
      , `List
          (List.map
             (fun premise_id -> `String premise_id)
             invalidation.missing_premise_ids) )
    ]
;;

let keeper_memory_retract_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let respond
        ?revision
        ?(effect_disposition = Tool_result.Effect_outcome_unknown)
        ~ok
        ~error_kind
        extras
    =
    let payload =
      Yojson.Safe.to_string
        (`Assoc
            ([ "ok", `Bool ok
             ; ( "error_kind"
               , `String (memory_retract_error_kind_to_string error_kind) )
             ]
             @ extras))
    in
    if ok
    then
      let completed = Keeper_tool_execution.success payload in
      Option.fold
        ~none:completed
        ~some:(fun revision ->
          Keeper_tool_execution.with_memory_retract_receipt ~revision completed)
        revision
    else
      Keeper_tool_execution.failure
        ~class_:(class_of_memory_retract_error_kind error_kind)
        ~effect_disposition
        payload
  in
  match validate_memory_retract_args args with
  | Memory_retract_invalid error_kind ->
    respond
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~ok:false
      ~error_kind
      []
  | Memory_retract_ok { memory_id; reason } ->
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    let now = Time_compat.now () in
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    (match
       Keeper_memory_os_current.retract_fact
         ~keepers_dir
         ~keeper_id:meta.name
         ~now
         ~source:
           { kind = Keeper_memory_os_current.Explicit_retract
           ; trace_id
           }
         ~memory_id
         ~reason
         ()
     with
     | Ok snapshot ->
       Log.Keeper.info
         "explicit current Memory retracted keeper=%s revision=%d memory_id=%s support_invalidations=%d"
         meta.name
         snapshot.revision
         memory_id
         (List.length snapshot.change.invalidated);
       respond
         ~revision:snapshot.revision
         ~ok:true
         ~error_kind:No_memory_retract_error
         [ "revision", `Int snapshot.revision
         ; ( "recorded_at"
           , `String (Masc_domain.iso8601_of_unix_seconds snapshot.updated_at) )
         ; "outcome", `String "retracted_current_fact"
         ; "store", `String "current_memory_snapshot"
         ; "memory_id", `String memory_id
         ; "reason", `String reason
         ; ( "removed_memory_ids"
           , `List
               (List.map
                  (fun fact ->
                     `String (Keeper_memory_os_types.memory_id fact))
                  snapshot.change.removed) )
         ; ( "support_invalidations"
           , `List
               (List.map
                  support_invalidation_receipt
                  snapshot.change.invalidated) )
         ]
     | Error Keeper_memory_os_current.Retract_memory_id_invalid ->
       respond
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~ok:false
         ~error_kind:Memory_id_invalid
         []
     | Error Keeper_memory_os_current.Retract_reason_empty ->
       respond
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~ok:false
         ~error_kind:Reason_empty
         []
     | Error (Keeper_memory_os_current.Retract_fact_not_found _) ->
       respond
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~ok:false
         ~error_kind:Fact_not_found
         [ "memory_id", `String memory_id ]
     | Error (Keeper_memory_os_current.Retract_persistence_failed detail) ->
       Log.Keeper.warn
         "explicit current Memory retraction failed keeper=%s memory_id=%s: %s"
         meta.name
         memory_id
         detail;
       respond
         ~ok:false
         ~error_kind:Retract_persistence_failed
         [ "detail", `String detail ]
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
