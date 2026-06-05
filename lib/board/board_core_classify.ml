module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_core_classify — Post visibility/kind converters and classification.

    Contains all conversion helpers, legacy migration heuristics, and
    the reclassify_report type used by both filesystem and PG backends.

    @since God file decomposition — extracted from board_core.ml *)

include Board_types

let visibility_to_string = function
  | Public -> "public"
  | Unlisted -> "unlisted"
  | Internal -> "internal"
  | Direct -> "direct"

let visibility_of_string = function
  | "public" -> Some Public
  | "unlisted" -> Some Unlisted
  | "internal" -> Some Internal
  | "direct" -> Some Direct
  | _ -> None

(** Issue #8392: schema enums for [visibility] used to be hand-rolled
    in [board_tool.ml:699], matching the same drift class as #8354
    (task_status), #8372 (agent_status), #8386 (agent_role). All
    constructors are nullary so the simple [List.map] trick works.
    Adding a 5th constructor will fail compilation in
    [visibility_to_string] and in the test asserts. *)
let all_visibilities = [ Public; Unlisted; Internal; Direct ]
let valid_visibility_strings =
  List.map visibility_to_string all_visibilities

let post_kind_to_string = function
  | Human_post -> "direct"
  | Automation_post -> "automation"
  | System_post -> "system"

let post_kind_of_string = function
  | "direct" -> Some Human_post
  | "automation" -> Some Automation_post
  | "system" -> Some System_post
  | _ -> None


(** Take at most [n] elements from a list. *)
let take = List.take

(** RFC-0089 §4-3 G2 — typed [author_kind] variant replaces the
    legacy [String.starts_with ~prefix:"auto-" / "qa-"] +
    substring(researcher/harness/smoke/probe) +
    legacy system-author string classifiers.

    Author strings still cross the *write boundary* as raw [string]
    (the persisted [post.author] field), so classification happens
    once at the read boundary via [classify_author].  Internal callers
    pattern-match on [author_kind] — adding a new automation label or
    system actor fails compilation at every match site. *)

(* [automation_label] relocated to Board_types; supplied here via
   [include Board_types] above so constructors (Auto_prefixed, ...)
   resolve unchanged. *)

type system_actor =
  | Ecosystem
  | Operator

type author_kind =
  | Human_author
  | Automation_author of automation_label
  | System_author of system_actor

let system_actor_of_string = function
  | "ecosystem" -> Some Ecosystem
  | "operator" -> Some Operator
  | _ -> None

let automation_label_of_string author =
  (* Priority order matches the pre-typed boolean OR chain: prefix
     matches first, then substring scan in declaration order.  First
     match wins so callers reproduce the legacy semantics exactly. *)
  if String.starts_with ~prefix:"auto-" author then Some Auto_prefixed
  else if String.starts_with ~prefix:"qa-" author then Some Qa_prefixed
  else if String_util.contains_substring author "researcher" then Some Researcher_named
  else if String_util.contains_substring author "harness" then Some Harness_named
  else if String_util.contains_substring author "smoke" then Some Smoke_named
  else if String_util.contains_substring author "probe" then Some Probe_named
  else None

(** [classify_author author] — single boundary parser.  Caller MUST
    pass a lowercased author string (callers were already doing
    [String.lowercase_ascii author] before the legacy bool helpers). *)
let classify_author (author : string) : author_kind =
  match system_actor_of_string author with
  | Some actor -> System_author actor
  | None ->
      (match automation_label_of_string author with
       | Some label -> Automation_author label
       | None -> Human_author)

(* The automation-label -> metric-string rendering moved to the
   Otel_metric_store adapter (board_metric_hooks_adapter.ml,
   [automation_label_to_label]). The hook now carries the typed
   [Board_types.automation_label] so the compiler checks every label
   value and the string lives only at the emission boundary. *)

let meta_source = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "source" fields with
      | Some (`String source) ->
          let source = String.lowercase_ascii (String.trim source) in
          if String.equal source "" then None else Some source
      | _ -> None)
  | _ -> None

let meta_field meta_json key =
  match meta_json with
  | Some (`Assoc fields) -> List.assoc_opt key fields
  | _ -> None

let nonempty_json_string = function
  | `String value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | _ -> None

let judgment_reason = function
  | `String _ as value -> nonempty_json_string value
  | `Assoc fields ->
      let find keys =
        List.find_map
          (fun key ->
             match List.assoc_opt key fields with
             | Some value -> nonempty_json_string value
             | None -> None)
          keys
      in
      find [ "summary"; "reason"; "classification_reason" ]
  | _ -> None

let meta_explicit_classification_reason meta_json =
  match
    (match meta_field meta_json "classification_reason" with
     | Some value -> nonempty_json_string value
     | None -> None)
  with
  | Some _ as reason -> reason
  | None ->
      [ "judgment"; "judgement" ]
      |> List.find_map (fun key ->
             match meta_field meta_json key with
             | Some value -> judgment_reason value
             | None -> None)

let legacy_migrate_post_kind ~meta_json ~author ~visibility ~expires_at ~hearth =
  let author = String.lowercase_ascii author in
  let hearth =
    match hearth with
    | Some value -> String.lowercase_ascii (String.trim value)
    | None -> ""
  in
  let meta_is_agent_board_post =
    match meta_source meta_json with
    | Some "agent_board_post" -> true
    | Some _ | None -> false
  in
  let hearth_promotes_to_automation =
    (* Hearth domain (RFC-0089 G3/G4 scope-out): hearth prefix +
       substring classification stays as raw [String.starts_with] /
       [contains_substring] until that domain's PR.  Localised here
       so the author-kind site is purely typed. *)
    (=) visibility Internal
    && Stdlib.Float.compare expires_at 0.0 > 0
    && not (String.equal hearth "")
    && (String.starts_with ~prefix:"mdal" hearth
        || String_util.contains_substring hearth "harness")
  in
  match classify_author author with
  | System_author _ -> System_post
  | Automation_author _ when meta_is_agent_board_post -> Automation_post
  | Human_author when meta_is_agent_board_post -> Automation_post
  | Automation_author _ when hearth_promotes_to_automation -> Automation_post
  | Human_author when hearth_promotes_to_automation -> Automation_post
  | Automation_author label ->
      (* #9919 audit follow-up: emit a labelled metric hook so operators can
         see which legacy authors still drive the migration path.
         The typed [automation_label] flows through unchanged (the
         metric-string rendering lives in the Otel_metric_store adapter) to keep
         label cardinality bounded (6 values) alongside the per-author
         label.  Both labels emitted so existing dashboards (keyed on raw
         [author]) keep working while operators gain a bounded breakdown.
         [author] stays a raw string: it is an unbounded external-identity
         label, out of scope for this closed-sum pass. *)
      Board_metrics_hooks.inc_legacy_migrate_post_kind
        ~author
        ~automation_label:label;
      Automation_post
  | Human_author -> Human_post

let classify_post_kind (p : post) = p.post_kind

let post_classification_reason (p : post) =
  match meta_explicit_classification_reason p.meta_json with
  | Some reason -> reason
  | None ->
      let author = Agent_id.to_string p.author in
      let author_lc = String.lowercase_ascii author in
      match p.post_kind, meta_source p.meta_json with
      | Human_post, Some "dashboard_board_post" ->
          "Direct board post created from the dashboard without automation override."
      | Human_post, Some source ->
          Printf.sprintf
            "Direct board post without automation override (source=%s)." source
      | Human_post, None ->
          "Direct board post without automation provenance."
      | Automation_post, Some "agent_board_post" ->
          Printf.sprintf
            "Automation classification based on board automation provenance, author=%s, and the automation post_kind contract."
            author
      | Automation_post, Some "dashboard_board_post" ->
          "Dashboard board post classified as automation for a bound agent author."
      | Automation_post, Some source ->
          Printf.sprintf "Automation provenance source: %s." source
      | Automation_post, None ->
          (match classify_author author_lc with
           | Automation_author _ ->
               "Legacy automation classification from author naming heuristic."
           | Human_author | System_author _ ->
               "Automation post preserved by board post_kind contract.")
      | System_post, _ ->
          "System post reserved for platform or operator authored messages."

let post_matches_filters ~exclude_system ~exclude_automation (p : post) =
  let kind = p.post_kind in
  (not exclude_system || not ((=) kind System_post))
  && (not exclude_automation || not ((=) kind Automation_post))

type reclassify_report = {
  backend : string;
  dry_run : bool;
  scanned : int;
  changed : int;
  unchanged : int;
  skipped : int;
  apply_failures : int;
  changed_post_ids : string list;
}
