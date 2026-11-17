open Keeper_memory_os_program_types
open Result.Syntax
module Program = Keeper_memory_os_program
module Memory = Keeper_memory_os_types

let anchor_to_json anchor =
  `Assoc ["epoch",`String anchor.epoch;
    "snapshot",(match anchor.snapshot with None -> `Null | Some (revision,sha256) ->
      `Assoc ["revision",`Int revision;"sha256",`String sha256]);
    "journal_length",`Int anchor.journal_length;"journal_sha256",`String anchor.journal_sha256]

let atom_boundary_to_json (boundary : atom_boundary) =
    `Assoc ["kind",`String "atom";
      "receipt_scope",`String boundary.receipt_scope;"trace_id",`String boundary.trace_id;
      "history_start_boundary_line",`Int boundary.history_start_boundary_line;
      "start_atom",`Int boundary.start_atom;"end_atom",`Int boundary.end_atom;
      "last_atom_digest",`String boundary.last_atom_digest;
      "end_boundary_line",`Int boundary.end_boundary_line;
      "boundary_lines_seen",`Int boundary.boundary_lines_seen;
      "checkpoint_sha256",`String boundary.checkpoint_sha256]

let official_boundary_to_json (boundary : official_boundary) =
    `Assoc ["kind",`String "official";
      "receipt_scope",`String boundary.receipt_scope;
      "after_boundary_line",`Int boundary.after_boundary_line;
      "turns",`List (List.map (fun (line,turn_ref,digest) ->
        `Assoc ["boundary_line",`Int line;"turn_ref",Ids.Turn_ref.to_yojson turn_ref;
          "messages_sha256",`String digest]) boundary.turns)]

let boundary_to_json = function
  | Atom_boundary boundary -> atom_boundary_to_json boundary
  | Official_boundary boundary -> official_boundary_to_json boundary
  | Mixed_boundary {atom;official} ->
    `Assoc ["kind",`String "mixed";"atom",atom_boundary_to_json atom;
      "official",official_boundary_to_json official]

let to_json publication =
  let version=match publication.boundary with Atom_boundary _ | Official_boundary _ -> 1
    | Mixed_boundary _ -> 2 in
  `Assoc ["schema_version",`Int version;"execution",Program.execution_to_json publication.execution;
    "captured",anchor_to_json publication.captured;
    "locked_prior",anchor_to_json publication.locked_prior;
    "boundary",boundary_to_json publication.boundary]

let exact names = function
  | `Assoc fields ->
    let+ () = Memory.exact_field_names_result names fields |> Result.map_error Memory.wire_error_to_string in
    fields
  | _ -> Error "program publication field is not an object"
let string key fields = Memory.wire_string_field key fields |> Result.map_error Memory.wire_error_to_string
let integer key fields = Memory.wire_int_field key fields |> Result.map_error Memory.wire_error_to_string
let digest value = String_util.is_lowercase_sha256_hex value

let anchor_of_json json =
  let* fields = exact ["epoch";"snapshot";"journal_length";"journal_sha256"] json in
  let* epoch = string "epoch" fields in
  let* journal_length = integer "journal_length" fields in
  let* journal_sha256 = string "journal_sha256" fields in
  let* snapshot = match List.assoc "snapshot" fields with
    | `Null -> Ok None
    | json ->
      let* fields = exact ["revision";"sha256"] json in
      let* revision = integer "revision" fields in
      let* sha256 = string "sha256" fields in
      if revision > 0 && digest sha256 then Ok (Some (revision,sha256))
      else Error "invalid program anchor snapshot" in
  if String.trim epoch <> "" && epoch = String.trim epoch && journal_length >= 0 && digest journal_sha256
  then Ok {epoch;snapshot;journal_length;journal_sha256}
  else Error "invalid program store anchor"

let single_boundary_of_json json =
  let* fields = match json with `Assoc fields -> Ok fields | _ -> Error "source boundary is not an object" in
  let* kind = string "kind" fields in
  match kind with
  | "atom" ->
    let* fields = exact ["kind";"receipt_scope";"trace_id";"history_start_boundary_line";
      "start_atom";"end_atom";"last_atom_digest";"end_boundary_line";"boundary_lines_seen";
      "checkpoint_sha256"] json in
    let* receipt_scope = string "receipt_scope" fields in
    let* trace_id = string "trace_id" fields in
    let* history_start_boundary_line = integer "history_start_boundary_line" fields in
    let* start_atom = integer "start_atom" fields in
    let* end_atom = integer "end_atom" fields in
    let* last_atom_digest = string "last_atom_digest" fields in
    let* end_boundary_line = integer "end_boundary_line" fields in
    let* boundary_lines_seen = integer "boundary_lines_seen" fields in
    let* checkpoint_sha256 = string "checkpoint_sha256" fields in
    if String.trim receipt_scope <> "" && String.trim trace_id <> ""
       && history_start_boundary_line > 0 && start_atom >= 0 && end_atom > start_atom
       && end_boundary_line >= history_start_boundary_line && boundary_lines_seen >= end_boundary_line
       && digest checkpoint_sha256 && String.trim last_atom_digest <> ""
    then Ok (Atom_boundary {receipt_scope;trace_id;history_start_boundary_line;start_atom;end_atom;
      last_atom_digest;end_boundary_line;boundary_lines_seen;checkpoint_sha256})
    else Error "invalid original atom boundary"
  | "official" ->
    let* fields = exact ["kind";"receipt_scope";"after_boundary_line";"turns"] json in
    let* receipt_scope = string "receipt_scope" fields in
    let* after_boundary_line = integer "after_boundary_line" fields in
    let* turns = match List.assoc "turns" fields with
      | `List values ->
        let rec loop previous seen acc = function
          | [] -> Ok (List.rev acc)
          | value :: rest ->
            let* fields = exact ["boundary_line";"turn_ref";"messages_sha256"] value in
            let* line = integer "boundary_line" fields in
            let* turn_ref = Ids.Turn_ref.of_yojson (List.assoc "turn_ref" fields) in
            let* sha256 = string "messages_sha256" fields in
            if line > previous && not (List.exists (Ids.Turn_ref.equal turn_ref) seen) && digest sha256
            then loop line (turn_ref::seen) ((line,turn_ref,sha256)::acc) rest
            else Error "invalid or repeated original official turn"
        in loop after_boundary_line [] [] values
      | _ -> Error "official source turns are not an array" in
    if String.trim receipt_scope <> "" && after_boundary_line >= 0 && turns <> []
    then Ok (Official_boundary {receipt_scope;after_boundary_line;turns})
    else Error "invalid original official boundary"
  | _ -> Error "unknown program source boundary"

let boundary_of_json json =
  let* fields=match json with `Assoc fields -> Ok fields
    | _ -> Error "source boundary is not an object" in
  let* kind=string "kind" fields in
  if kind<>"mixed" then single_boundary_of_json json else
  let* fields=exact ["kind";"atom";"official"] json in
  let* atom=single_boundary_of_json (List.assoc "atom" fields) in
  let* official=single_boundary_of_json (List.assoc "official" fields) in
  match atom,official with
  | Atom_boundary atom,Official_boundary official ->
    if atom.receipt_scope=official.receipt_scope then Ok (Mixed_boundary {atom;official})
    else Error "Mixed program components belong to different source scopes"
  | (Official_boundary _ | Mixed_boundary _),(Atom_boundary _ | Official_boundary _ | Mixed_boundary _)
  | Atom_boundary _,(Atom_boundary _ | Mixed_boundary _) ->
    Error "Mixed program requires one atom and one official boundary"

let source_in_boundary boundary = function
  | Keeper_librarian_unread.Atom source ->
    (match boundary with
     | Atom_boundary boundary | Mixed_boundary {atom=boundary;official=_} -> source.trace_id = boundary.trace_id
       && source.history_start_boundary_line = boundary.history_start_boundary_line
       && source.atom >= boundary.start_atom && source.atom < boundary.end_atom
     | Official_boundary _ -> false)
  | Keeper_librarian_unread.Official_turn source ->
    (match boundary with
     | Atom_boundary _ -> false
     | Official_boundary boundary | Mixed_boundary {atom=_;official=boundary} -> List.exists (fun (line,turn_ref,_) ->
         line = source.boundary_line && Ids.Turn_ref.equal turn_ref source.turn_ref) boundary.turns)

let of_json json =
  let* fields = exact ["schema_version";"execution";"captured";"locked_prior";"boundary"] json in
  let* version = integer "schema_version" fields in
  let* () = if version=1 || version=2 then Ok () else Error "unknown program publication schema" in
  let* execution = Program.execution_of_json (List.assoc "execution" fields) in
  let* captured = anchor_of_json (List.assoc "captured" fields) in
  let* locked_prior = anchor_of_json (List.assoc "locked_prior" fields) in
  let* boundary = boundary_of_json (List.assoc "boundary" fields) in
  let* ()=if (match boundary with Atom_boundary _ | Official_boundary _ -> version=1
      | Mixed_boundary _ -> version=2) then Ok ()
    else Error "program publication schema differs from its source boundary" in
  let before_revision = function None -> 0 | Some (revision,_) -> revision in
  let captured_presence = match captured.snapshot, execution.program.initial_current with
    | None,None | Some _,Some _ -> true
    | None,Some _ | Some _,None -> false in
  if captured.epoch <> locked_prior.epoch
     || captured.journal_length > locked_prior.journal_length
     || (captured.journal_length=locked_prior.journal_length
         && captured.journal_sha256<>locked_prior.journal_sha256)
     || before_revision captured.snapshot > before_revision locked_prior.snapshot
     || (before_revision captured.snapshot=before_revision locked_prior.snapshot
         && captured.snapshot<>locked_prior.snapshot)
     || not captured_presence
     || (locked_prior.snapshot=None && execution.initial_facts<>[])
     || not (List.for_all (source_in_boundary boundary) execution.program.sources)
  then Error "program publication bindings conflict"
  else Ok {execution;captured;locked_prior;boundary}

let require_receipt_ranges publication ranges =
  let module R = Keeper_memory_os_current_types in
  let atom_unread,official_unread=List.partition (fun (hole : Keeper_librarian_unread.t) ->
    match hole.source with Atom _ -> true | Official_turn _ -> false)
    publication.execution.program.unread in
  let atom_matches (boundary : atom_boundary) (range : R.durable_range_id) =
    boundary.receipt_scope=range.receipt_scope && boundary.trace_id=range.trace_id
    && boundary.history_start_boundary_line=range.history_start_boundary_line
    && boundary.start_atom=range.start_atom && boundary.end_atom=range.end_atom
    && boundary.last_atom_digest=range.last_atom_digest
    && boundary.end_boundary_line=range.end_boundary_line
    && boundary.boundary_lines_seen=range.boundary_lines_seen
    && range.unread_messages=atom_unread in
  let official_matches (boundary : official_boundary) (range : R.official_range_id) =
    boundary.receipt_scope=range.receipt_scope && boundary.after_boundary_line=range.after_boundary_line
    && List.map (fun (line,turn_ref,_) -> line,turn_ref) boundary.turns=range.turns
    && range.unread_messages=official_unread in
  let matches = function
    | R.Atom_range range ->
      (match publication.boundary with
       | Atom_boundary boundary | Mixed_boundary {atom=boundary;official=_} -> atom_matches boundary range
       | Official_boundary _ -> false)
    | R.Official_range range ->
      (match publication.boundary with
       | Official_boundary boundary | Mixed_boundary {atom=_;official=boundary} -> official_matches boundary range
       | Atom_boundary _ -> false)
    | R.Explicit_candidate _ | Explicit_candidate_with_recall _ -> false in
  let exact_kinds=match publication.boundary,ranges with
    | Atom_boundary _,[R.Atom_range _]
    | Official_boundary _,[R.Official_range _]
    | Mixed_boundary _,[R.Atom_range _;R.Official_range _]
    | Mixed_boundary _,[R.Official_range _;R.Atom_range _] -> true
    | (Atom_boundary _ | Official_boundary _ | Mixed_boundary _),_ -> false in
  if exact_kinds && List.for_all matches ranges then Ok ()
  else Error "ordered publication and original-boundary receipt set conflict; stores preserved"

let touched_ids publication = Program.touched_ids publication.execution

let validate_transition publication ~source_trace_id ~revision ~added ~removed ~retained =
  let expected_revision = match publication.locked_prior.snapshot with None -> 1 | Some (revision,_) -> revision+1 in
  let* change = Keeper_memory_os_support_core.compute_change
    ~previous:publication.execution.initial_facts ~next:publication.execution.final_facts ~invalidated:[] in
  if revision=expected_revision
     && source_trace_id=Ids.Turn_ref.trace_id publication.execution.program.turn_ref
     && change.added=added && change.removed=removed && change.retained=retained
  then Ok () else Error "ordered proof differs from its actual outer snapshot transition"
