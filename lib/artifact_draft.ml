module Engine = Artifact_document_engine
type target = { artifact_id : string; generation : string }
type selection = { target : target; position : Engine.selection }
type t =
  { target : target; base_revision : int; base_sha256 : string; state : string
  ; sequence : int; updated_by : string; updated_at : string; discussion : Artifact_discussion.event list }
type command =
  | Open of { artifact_id : string; revision : int }
  | Merge of { target : target; updates : string list }
  | Select of { target : target; anchor : int; head : int }
  | Resolve of selection
  | Edit of { selection : selection; expected : string; replacement : string }
  | Discuss of { target : target; request : Artifact_discussion.request }
open Result.Syntax
let safe_integer value = value >= 0 && Int64.of_int value <= 9_007_199_254_740_991L
let text value = String.trim value <> "" && String.is_valid_utf_8 value
let fields allowed = function
  | `Assoc fields ->
    let names = List.map fst fields in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || List.exists (fun name -> not (List.mem name allowed)) names
    then Error "duplicate or unknown draft field" else Ok fields
  | _ -> Error "expected draft object"
let field name fields = Option.value ~default:`Null (List.assoc_opt name fields)
let string name fields = match field name fields with
  | `String value when String.is_valid_utf_8 value -> Ok value
  | _ -> Error ("invalid " ^ name)
let integer ~minimum name fields = match field name fields with
  | `Int value when value >= minimum && safe_integer value -> Ok value
  | _ -> Error ("invalid " ^ name)
let valid_target target =
  if not (Published_artifact.valid_id target.artifact_id) then Error "invalid artifact id"
  else let* canonical = Random_id.parse_uuid_v7 target.generation in
    if String.equal canonical target.generation then Ok () else Error "noncanonical draft generation"
let target_to_json target = `Assoc ["artifact_id", `String target.artifact_id; "generation", `String target.generation]
let target_of_json json =
  let* fields = fields ["artifact_id"; "generation"] json in
  let* artifact_id = string "artifact_id" fields in let* generation = string "generation" fields in
  let target = { artifact_id; generation } in let* () = valid_target target in Ok target
let selection_to_json (selection : selection) =
  `Assoc ["target", target_to_json selection.target; "position", Engine.selection_to_json selection.position]
let selection_of_json json =
  let* fields = fields ["target"; "position"] json in
  let* target = target_of_json (field "target" fields) in
  let* position = Engine.selection_of_json (field "position" fields) in Ok { target; position }
let validate draft =
  let* () = valid_target draft.target in
  let* _ = Artifact_discussion.threads draft.discussion in
  let* () = Tool_blob_store.validate_sha256 draft.base_sha256 |> Result.map_error (fun _ -> "invalid base digest") in
  if draft.base_revision <= 0 || not (safe_integer draft.base_revision) || not (safe_integer draft.sequence)
  then Error "invalid draft revision or sequence"
  else if not (Engine.valid_state draft.state && text draft.updated_by && text draft.updated_at)
  then Error "invalid draft state, actor or timestamp" else Ok draft
let create ~target ~base_revision ~base_sha256 ~state ~actor ~at =
  validate { target; base_revision; base_sha256; state; sequence = 0; updated_by = actor; updated_at = at; discussion = [] }
let advance ?discussion draft ~state ~actor ~at =
  let discussion = Option.value ~default:draft.discussion discussion in
  if not (safe_integer (draft.sequence + 1)) then Error "draft sequence exhausted"
  else validate { draft with state; discussion; sequence = draft.sequence + 1; updated_by = actor; updated_at = at }
let checkpoint draft ~base_revision ~base_sha256 ~actor ~at =
  if base_revision <= draft.base_revision then Error "draft publication base must advance"
  else if not (safe_integer (draft.sequence + 1)) then Error "draft sequence exhausted"
  else validate { draft with base_revision; base_sha256; sequence = draft.sequence + 1;
    updated_by = actor; updated_at = at }
let public_fields draft =
  ["schema", `String "masc.artifact_draft.v2"; "target", target_to_json draft.target;
   "base_revision", `Int draft.base_revision; "base_sha256", `String draft.base_sha256;
   "state", `String draft.state; "sequence", `Int draft.sequence;
   "updated_by", `String draft.updated_by; "updated_at", `String draft.updated_at]
let public_to_json draft = `Assoc (public_fields draft)
let to_json draft = `Assoc (public_fields draft @ ["discussion", Artifact_discussion.events_to_json draft.discussion])
let document_to_json ~draft ~content ~selection =
  (* Private construction and strict reads validate the event history. *)
  let threads = Artifact_discussion.threads draft.discussion |> Result.get_ok in
  `Assoc ["draft", public_to_json draft; "content", `String content;
    "threads", `List (List.map Artifact_discussion.thread_to_json threads);
    "discussion_receipts", Artifact_discussion.events_to_json draft.discussion;
    "selection", (match selection with None -> `Null | Some (selection, anchor, head) ->
      `Assoc ["selection", selection_to_json selection; "anchor", `Int anchor; "head", `Int head])]
let of_json json =
  let* fields = fields ["schema"; "target"; "base_revision"; "base_sha256"; "state"; "sequence"; "updated_by"; "updated_at"; "discussion"] json in
  let* () = if field "schema" fields = `String "masc.artifact_draft.v2" then Ok () else Error "invalid draft schema" in
  let* target = target_of_json (field "target" fields) in
  let* base_revision = integer ~minimum:1 "base_revision" fields in
  let* base_sha256 = string "base_sha256" fields in let* state = string "state" fields in
  let* sequence = integer ~minimum:0 "sequence" fields in
  let* updated_by = string "updated_by" fields in let* updated_at = string "updated_at" fields in
  let* discussion = Artifact_discussion.events_of_json (field "discussion" fields) in
  validate { target; base_revision; base_sha256; state; sequence; updated_by; updated_at; discussion }
let command_of_json json =
  let* all = fields ["action"; "artifact_id"; "revision"; "target"; "updates"; "anchor"; "head"; "selection"; "expected"; "replacement"; "request"] json in
  let* action = string "action" all in
  match action with
  | "open" ->
    let* fields = fields ["action"; "artifact_id"; "revision"] json in
    let* artifact_id = string "artifact_id" fields in let* revision = integer ~minimum:1 "revision" fields in
    if Published_artifact.valid_id artifact_id then Ok (Open { artifact_id; revision }) else Error "invalid artifact id"
  | "merge" ->
    let* fields = fields ["action"; "target"; "updates"] json in
    let* target = target_of_json (field "target" fields) in
    let* updates = match field "updates" fields with
      | `List values -> List.fold_right (fun json rest ->
          let* rest = rest in match json with
          | `String value when Engine.valid_state value -> Ok (value :: rest)
          | _ -> Error "invalid draft update") values (Ok [])
      | _ -> Error "expected draft updates" in Ok (Merge { target; updates })
  | "select" ->
    let* fields = fields ["action"; "target"; "anchor"; "head"] json in
    let* target = target_of_json (field "target" fields) in
    let* anchor = integer ~minimum:0 "anchor" fields in let* head = integer ~minimum:0 "head" fields in
    Ok (Select { target; anchor; head })
  | "edit" ->
    let* fields = fields ["action"; "selection"; "expected"; "replacement"] json in
    let* selection = selection_of_json (field "selection" fields) in
    let* expected = string "expected" fields in let* replacement = string "replacement" fields in
    Ok (Edit { selection; expected; replacement })
  | "resolve" ->
    let* fields = fields ["action"; "selection"] json in
    let* selection = selection_of_json (field "selection" fields) in Ok (Resolve selection)
  | "discuss" ->
    let* fields = fields ["action"; "target"; "request"] json in
    let* target = target_of_json (field "target" fields) in
    let* request = Artifact_discussion.request_of_json (field "request" fields) in Ok (Discuss { target; request })
  | _ -> Error "unknown draft action"
