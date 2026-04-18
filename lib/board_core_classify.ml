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
    in [tool_board.ml:699], matching the same drift class as #8354
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
  | "human" -> Some Human_post
  | "automation" -> Some Automation_post
  | "system" -> Some System_post
  | _ -> None

let contains_substring = String_util.contains_substring

(** Take at most [n] elements from a list. *)
let take n lst =
  let rec go n acc = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> go (n - 1) (x :: acc) xs
  in
  go n [] lst

let legacy_author_looks_automation author =
  String.starts_with ~prefix:"auto-" author
  || String.starts_with ~prefix:"qa-" author
  || contains_substring author "researcher"
  || contains_substring author "harness"
  || contains_substring author "smoke"
  || contains_substring author "probe"

let legacy_system_board_author author =
  List.mem author
    [ "ecosystem"; "keeper"; "keeper-alert-bot"; "keeper-system"; "operator";
      "team-session" ]

let meta_source = function
  | Some (`Assoc fields) -> (
      match List.assoc_opt "source" fields with
      | Some (`String source) ->
          let source = String.lowercase_ascii (String.trim source) in
          if source = "" then None else Some source
      | _ -> None)
  | _ -> None

let meta_field meta_json key =
  match meta_json with
  | Some (`Assoc fields) -> List.assoc_opt key fields
  | _ -> None

let nonempty_json_string = function
  | `String value ->
      let value = String.trim value in
      if value = "" then None else Some value
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
  if legacy_system_board_author author then
    System_post
  else if meta_source meta_json = Some "keeper_board_post" then
    Automation_post
  else if visibility = Internal && expires_at > 0.0 && hearth <> ""
          && (String.starts_with ~prefix:"mdal" hearth
              || contains_substring hearth "harness")
  then
    Automation_post
  else if legacy_author_looks_automation author then begin
    Heuristic_metrics.record {
      module_name = "board_core_classify";
      site = "legacy_migrate_post_kind";
      raw_value = 1.0;
      threshold = 0.5;
      triggered = true;
      provenance = Board_classify ("author_heuristic:" ^ author);
      timestamp = Unix.gettimeofday ();
    };
    Automation_post
  end
  else
    Human_post

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
      | Automation_post, Some "keeper_board_post" ->
          Printf.sprintf
            "Automation classification based on source=keeper_board_post, author=%s, and the automation post_kind contract."
            author
      | Automation_post, Some "dashboard_board_post" ->
          "Dashboard board post classified as automation for a joined agent author."
      | Automation_post, Some source ->
          Printf.sprintf "Automation provenance source: %s." source
      | Automation_post, None when legacy_author_looks_automation author_lc ->
          "Legacy automation classification from author naming heuristic."
      | Automation_post, None ->
          "Automation post preserved by board post_kind contract."
      | System_post, _ ->
          "System post reserved for platform or operator authored messages."

let post_matches_filters ~exclude_system ~exclude_automation (p : post) =
  let kind = p.post_kind in
  (not exclude_system || kind <> System_post)
  && (not exclude_automation || kind <> Automation_post)

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

let reclassify_report_to_yojson (report : reclassify_report) =
  `Assoc
    [
      ("backend", `String report.backend);
      ("dry_run", `Bool report.dry_run);
      ("scanned", `Int report.scanned);
      ("changed", `Int report.changed);
      ("unchanged", `Int report.unchanged);
      ("skipped", `Int report.skipped);
      ("apply_failures", `Int report.apply_failures);
      ( "changed_post_ids",
        `List (List.map (fun id -> `String id) report.changed_post_ids) );
    ]
