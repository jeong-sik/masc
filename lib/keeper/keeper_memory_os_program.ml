open Keeper_memory_os_types
open Result.Syntax
module Source = Keeper_librarian_unread
module Core = Keeper_memory_os_disposition_core
module Payloads = Set_util.StringMap
module Identity_set = Set_util.StringSet

include Keeper_memory_os_program_types

type coordinate =
  | Atom_coordinate of string * int * int * int
  | Official_coordinate of string * int * int

module Coordinates = Set.Make (struct type t = coordinate let compare = compare end)

let coordinate = function
  | Source.Atom {trace_id;history_start_boundary_line;atom;message_in_atom;_} ->
    Atom_coordinate (trace_id,history_start_boundary_line,atom,message_in_atom)
  | Source.Official_turn {turn_ref;boundary_line;message_in_turn;_} ->
    Official_coordinate (Ids.Turn_ref.to_string turn_ref,boundary_line,message_in_turn)

let source_digest = function
  | Source.Atom {message_sha256;_} | Source.Official_turn {message_sha256;_} -> message_sha256

let facts = function None -> [] | Some facts -> facts
let payload fact = Yojson.Safe.to_string (fact_to_json fact)

let index_facts values =
  List.fold_left (fun result fact ->
    let* by_id = result in
    let* _ = fact_of_json (fact_to_json fact) |> Result.map_error wire_error_to_string in
    let identity = memory_id fact in
    if Payloads.mem identity by_id then Error ("duplicate program fact: " ^ identity)
    else Ok (Payloads.add identity fact by_id)) (Ok Payloads.empty) values

let equal_current expected observed =
  match expected, observed with
  | None, None -> Ok true
  | None, Some _ | Some _, None -> Ok false
  | Some expected, Some observed ->
    let* expected = index_facts expected in
    let+ observed = index_facts observed in
    Payloads.equal (fun left right -> String.equal (payload left) (payload right)) expected observed

let ids values = Identity_set.of_list (List.map memory_id values)

let validate_sources sources unread decisions =
  let* manifest = List.fold_left (fun result source ->
    let* seen = result in
    let* _ = Source.source_of_json (Source.source_to_json source) in
    let key = coordinate source in
    if Coordinates.mem key seen then Error "duplicate program source coordinate"
    else Ok (Coordinates.add key seen)) (Ok Coordinates.empty) sources in
  let* _ = Source.list_of_json (Source.list_to_json unread) in
  let* holes = List.fold_left (fun result (hole : Source.t) ->
    let* seen = result in
    let key = coordinate hole.source in
    if not (Coordinates.mem key manifest) then Error "unread source is outside the program manifest"
    else
      match List.find_opt (fun source -> coordinate source = key) sources with
      | Some source when source_digest source = source_digest hole.source ->
        Ok (Coordinates.add key seen)
      | None | Some _ -> Error "unread source hash differs from the program manifest")
    (Ok Coordinates.empty) unread in
  let expected_read = List.filter (fun source -> not (Coordinates.mem (coordinate source) holes)) sources in
  let actual_read = List.concat_map (fun (decision : decision) -> decision.sources) decisions in
  if actual_read = expected_read then Ok ()
  else Error "program steps do not account for the ordered manifest exactly once"

let validate_decision (decision : decision) =
  let* () =
    if String.trim decision.run_id <> "" && String.trim decision.working_state <> "" then Ok ()
    else Error "a program decision requires one run and working state" in
  let* held = index_facts (facts decision.input_current) in
  let* added = index_facts decision.new_claims in
  let unique values = List.length values = List.length (List.sort_uniq compare values) in
  let dropped_ids = Identity_set.of_list
    (List.map (fun (drop : dropped_statement) -> drop.memory_id) decision.dropped) in
  let absorbed_ids = Identity_set.of_list
    (List.map (fun (row : absorbed_statement) -> row.absorbed) decision.absorbed) in
  let* () =
    if unique (List.map (fun (drop : dropped_statement) -> drop.memory_id) decision.dropped)
       && unique (List.map (fun (row : absorbed_statement) -> row.absorbed) decision.absorbed)
       && unique decision.revisions then Ok ()
    else Error "duplicate program decision relationship" in
  let* () =
    if Payloads.exists (fun identity _ -> Payloads.mem identity held) added
    then Error "program new claim recreates a held identity"
    else Ok () in
  let survives identity =
    (Payloads.mem identity held || Payloads.mem identity added)
    && not (Identity_set.mem identity dropped_ids || Identity_set.mem identity absorbed_ids) in
  let* () = List.fold_left (fun result (drop : dropped_statement) ->
    let* () = result in
    if is_memory_id drop.memory_id && String.trim drop.reason <> ""
       && Payloads.mem drop.memory_id held then Ok ()
    else Error "program retirement does not name a held fact and reason") (Ok ()) decision.dropped in
  let* () = List.fold_left (fun result (absorption : absorbed_statement) ->
    let* () = result in
    if Payloads.mem absorption.absorbed held
       && not (Identity_set.mem absorption.absorbed dropped_ids)
       && absorption.absorbed <> absorption.into && survives absorption.into then Ok ()
    else Error "program absorption requires a held source and surviving target") (Ok ()) decision.absorbed in
  List.fold_left (fun result (revision : revision) ->
    let* () = result in
    if Payloads.mem revision.superseded held
       && Identity_set.mem revision.superseded dropped_ids
       && revision.superseded <> revision.superseded_by && survives revision.superseded_by then Ok ()
    else Error "program revision requires a retired held source and surviving target")
    (Ok ()) decision.revisions

let apply ~index ~current (decision : decision) =
  let planned = Core.plan ~current ~dropped:decision.dropped ~absorbed:decision.absorbed
    ~revisions:decision.revisions ~new_claims:decision.new_claims in
  let before_ids = ids current and after_ids = ids planned.facts in
  let absorbed_applied = List.filter (fun (absorption : absorbed_statement) ->
    Identity_set.mem absorption.absorbed before_ids
    && not (Identity_set.mem absorption.absorbed after_ids)
    && Identity_set.mem absorption.into after_ids
    && Set_util.StringMap.find_opt absorption.absorbed planned.absorbed_into = Some absorption.into)
    decision.absorbed in
  let revisions_applied = List.filter (fun (revision : revision) ->
    Identity_set.mem revision.superseded before_ids
    && not (Identity_set.mem revision.superseded after_ids)
    && Identity_set.mem revision.superseded_by after_ids) decision.revisions in
  let invalidated = List.map
    (fun (row : Keeper_memory_os_current_types.support_invalidation) ->
       {fact=row.fact; missing_premise_ids=row.missing_premise_ids}) planned.invalidated in
  {index; decision; before=current; after=planned.facts; invalidated;
   absorbed_applied; revisions_applied; claims_refused=planned.claims_refused}

let create ~transaction_id ~keeper_id ~turn_ref ~sources ~unread ~initial_current ~decisions =
  let* () = if String.trim transaction_id <> "" && sources <> [] then Ok ()
    else Error "a Memory program requires a transaction and nonempty original manifest" in
  let* () =
    if String.trim (Ids.Turn_ref.trace_id turn_ref) <> ""
       && Ids.Turn_ref.absolute_turn turn_ref > 0 then Ok ()
    else Error "invalid program batch turn" in
  let* _ = index_facts (facts initial_current) in
  let* () = validate_sources sources unread decisions in
  let rec build current seen index stages = function
    | [] -> Ok (List.rev stages, facts current)
    | decision :: rest ->
      let* () = validate_decision decision in
      let* () =
        if Keeper_identity.Keeper_id.equal keeper_id decision.keeper_id
           && Ids.Turn_ref.equal turn_ref decision.turn_ref then Ok ()
        else Error "program decision Keeper or batch differs" in
      let* () = if Identity_set.mem decision.run_id seen then Error "duplicate program decision run"
        else Ok () in
      let* equal = equal_current current decision.input_current in
      if not equal then Error "program decision did not judge the prior stage's full current payload"
      else
        let stage = apply ~index ~current:(facts current) decision in
        build (Some stage.after) (Identity_set.add decision.run_id seen) (index+1) (stage::stages) rest
  in
  let+ stages, final_facts = build initial_current Identity_set.empty 0 [] decisions in
  ({transaction_id; keeper_id; turn_ref; sources; unread; initial_current; stages; final_facts} : t)

let same_semantics left right =
  left.claim = right.claim && left.category = right.category && left.basis = right.basis
  && left.origin = right.origin && left.first_seen = right.first_seen
  && right.last_seen >= left.last_seen

let matches_expected ~extras expected actual =
  let* expected = index_facts expected in
  let* actual = index_facts actual in
  let all_expected = Payloads.for_all (fun identity fact ->
    match Payloads.find_opt identity actual with
    | Some held -> same_semantics fact held
    | None -> false) expected in
  let no_unexplained = Payloads.for_all (fun identity _ ->
    Payloads.mem identity expected || Identity_set.mem identity extras) actual in
  if all_expected && no_unexplained then Ok () else Error "locked Memory program replay diverged"

let validate_program (program : t) =
  let* canonical = create ~transaction_id:program.transaction_id
    ~keeper_id:program.keeper_id ~turn_ref:program.turn_ref ~sources:program.sources
    ~unread:program.unread ~initial_current:program.initial_current
    ~decisions:(List.map (fun (stage : stage) -> stage.decision) program.stages) in
  if canonical = program then Ok ()
  else Error "Memory program computed stages or final facts differ from the accepted decisions"

let replay (program : t) ~current =
  let* () = validate_program program in
  let extras = Identity_set.diff (ids current) (ids (facts program.initial_current)) in
  let* () = matches_expected ~extras (facts program.initial_current) current in
  let extra_facts = List.filter (fun fact -> Identity_set.mem (memory_id fact) extras) current in
  let proposed_ids = List.fold_left (fun seen (stage : stage) ->
    Identity_set.union seen (ids stage.decision.new_claims)) Identity_set.empty program.stages in
  let* () =
    if Identity_set.is_empty (Identity_set.inter extras proposed_ids) then Ok ()
    else Error "concurrent Memory addition collides with a program proposal" in
  let preserve_extras actual =
    let* actual = index_facts actual in
    if List.for_all (fun fact ->
      match Payloads.find_opt (memory_id fact) actual with
      | Some held -> payload held = payload fact
      | None -> false) extra_facts then Ok ()
    else Error "locked Memory program changed a concurrent addition" in
  let rec run current stages = function
    | [] -> Ok (List.rev stages, current)
    | (expected : stage) :: rest ->
      let* () = matches_expected ~extras expected.before current in
      let stage = apply ~index:expected.index ~current expected.decision in
      let* () = matches_expected ~extras expected.after stage.after in
      let* () = preserve_extras stage.after in
      if stage.absorbed_applied <> expected.absorbed_applied
         || stage.revisions_applied <> expected.revisions_applied
         || stage.claims_refused <> expected.claims_refused
      then Error "locked Memory program decision outcomes diverged"
      else run stage.after (stage::stages) rest
  in
  let+ stages, final_facts = run current [] program.stages in
  ({program; initial_facts=current; stages; final_facts} : execution)

let touched_ids (execution : execution) =
  List.fold_left (fun changed (stage : stage) ->
    let before = List.fold_left (fun map fact -> Payloads.add (memory_id fact) (payload fact) map)
      Payloads.empty stage.before in
    let after = List.fold_left (fun map fact -> Payloads.add (memory_id fact) (payload fact) map)
      Payloads.empty stage.after in
    let note side other changed = Payloads.fold (fun identity bytes changed ->
      if Payloads.find_opt identity other = Some bytes then changed
      else Identity_set.add identity changed) side changed in
    note before after changed |> note after before) Identity_set.empty execution.stages
  |> Identity_set.elements

let facts_to_json values = `List (List.map fact_to_json values)
let current_to_json = function None -> `Null | Some values -> facts_to_json values
let sources_to_json values = `List (List.map Source.source_to_json values)
let absorbed_to_json values = `List (List.map (fun (value : absorbed_statement) ->
  `Assoc ["absorbed",`String value.absorbed; "into",`String value.into]) values)
let revisions_to_json values = `List (List.map (fun (value : revision) ->
  `Assoc ["superseded",`String value.superseded; "superseded_by",`String value.superseded_by]) values)

let decision_to_json (decision : decision) =
  `Assoc ["run_id",`String decision.run_id;
    "keeper_id",`String (Keeper_identity.Keeper_id.to_string decision.keeper_id);
    "turn_ref",Ids.Turn_ref.to_yojson decision.turn_ref;
    "input_current",current_to_json decision.input_current;
    "sources",sources_to_json decision.sources;
    "input_evidence",decision.input_evidence; "gate_evidence",decision.gate_evidence;
    "working_state",`String decision.working_state;
    "new_claims",facts_to_json decision.new_claims;
    "dropped",`List (List.map dropped_statement_to_json decision.dropped);
    "absorbed",absorbed_to_json decision.absorbed; "revisions",revisions_to_json decision.revisions]

let stage_to_json (stage : stage) =
  `Assoc ["index",`Int stage.index; "decision",decision_to_json stage.decision;
    "before",facts_to_json stage.before; "after",facts_to_json stage.after;
    "invalidated",`List (List.map (fun (row : invalidation) ->
      `Assoc ["fact",fact_to_json row.fact;
        "missing_premise_ids",`List (List.map (fun id -> `String id) row.missing_premise_ids)]) stage.invalidated);
    "absorbed_applied",absorbed_to_json stage.absorbed_applied;
    "revisions_applied",revisions_to_json stage.revisions_applied;
    "claims_refused",facts_to_json stage.claims_refused]

let to_json (program : t) =
  `Assoc ["schema_version",`Int 1; "transaction_id",`String program.transaction_id;
    "keeper_id",`String (Keeper_identity.Keeper_id.to_string program.keeper_id);
    "turn_ref",Ids.Turn_ref.to_yojson program.turn_ref;
    "sources",sources_to_json program.sources; "unread",Source.list_to_json program.unread;
    "initial_current",current_to_json program.initial_current;
    "stages",`List (List.map stage_to_json program.stages);
    "final_facts",facts_to_json program.final_facts]

let execution_to_json (execution : execution) =
  `Assoc ["schema_version",`Int 1; "program",to_json execution.program;
    "initial_facts",facts_to_json execution.initial_facts;
    "stages",`List (List.map stage_to_json execution.stages);
    "final_facts",facts_to_json execution.final_facts]

let object_fields keys = function
  | `Assoc fields ->
    exact_field_names_result keys fields |> Result.map_error wire_error_to_string
    |> Result.map (fun () -> fields)
  | _ -> Error "Memory program field must be an object"

let string_field key fields = wire_string_field key fields |> Result.map_error wire_error_to_string

let list_of_json decode = function
  | `List values ->
    let rec loop decoded = function
      | [] -> Ok (List.rev decoded)
      | value :: rest -> let* value = decode value in loop (value::decoded) rest in
    loop [] values
  | _ -> Error "Memory program field must be an array"

let facts_of_json json = list_of_json
  (fun json -> fact_of_json json |> Result.map_error wire_error_to_string) json

let current_of_json = function
  | `Null -> Ok None
  | json -> facts_of_json json |> Result.map Option.some

let keeper_of_json = function
  | `String name ->
    (match Keeper_identity.Keeper_id.of_string name with
     | Some keeper when Keeper_identity.Keeper_id.to_string keeper = name -> Ok keeper
     | None | Some _ -> Error "program Keeper identity is not canonical")
  | _ -> Error "program Keeper identity is not a string"

let absorbed_of_json json =
  let* fields = object_fields ["absorbed";"into"] json in
  let* absorbed = string_field "absorbed" fields in
  let+ into = string_field "into" fields in
  ({absorbed;into} : absorbed_statement)

let revision_of_json json =
  let* fields = object_fields ["superseded";"superseded_by"] json in
  let* superseded = string_field "superseded" fields in
  let+ superseded_by = string_field "superseded_by" fields in
  ({superseded;superseded_by} : revision)

let decision_of_json json =
  let* fields = object_fields ["run_id";"keeper_id";"turn_ref";"input_current";"sources";
    "input_evidence";"gate_evidence";"working_state";"new_claims";"dropped";"absorbed";"revisions"] json in
  let* run_id = string_field "run_id" fields in
  let* keeper_id = keeper_of_json (List.assoc "keeper_id" fields) in
  let* turn_ref = Ids.Turn_ref.of_yojson (List.assoc "turn_ref" fields) in
  let* input_current = current_of_json (List.assoc "input_current" fields) in
  let* sources = list_of_json Source.source_of_json (List.assoc "sources" fields) in
  let* working_state = string_field "working_state" fields in
  let* new_claims = facts_of_json (List.assoc "new_claims" fields) in
  let* dropped = list_of_json (fun json ->
    dropped_statement_of_json json |> Result.map_error wire_error_to_string) (List.assoc "dropped" fields) in
  let* absorbed = list_of_json absorbed_of_json (List.assoc "absorbed" fields) in
  let+ revisions = list_of_json revision_of_json (List.assoc "revisions" fields) in
  ({run_id; keeper_id; turn_ref; input_current; sources;
    input_evidence=List.assoc "input_evidence" fields;
    gate_evidence=List.assoc "gate_evidence" fields;
    working_state; new_claims; dropped; absorbed; revisions} : decision)

let decision_of_stage_json json =
  let* fields = object_fields ["index";"decision";"before";"after";"invalidated";
    "absorbed_applied";"revisions_applied";"claims_refused"] json in
  decision_of_json (List.assoc "decision" fields)

let schema_is_one fields =
  match List.assoc "schema_version" fields with
  | `Int 1 -> Ok ()
  | _ -> Error "unknown Memory program schema"

let of_json json =
  let* fields = object_fields ["schema_version";"transaction_id";"keeper_id";"turn_ref";
    "sources";"unread";"initial_current";"stages";"final_facts"] json in
  let* () = schema_is_one fields in
  let* transaction_id = string_field "transaction_id" fields in
  let* keeper_id = keeper_of_json (List.assoc "keeper_id" fields) in
  let* turn_ref = Ids.Turn_ref.of_yojson (List.assoc "turn_ref" fields) in
  let* sources = list_of_json Source.source_of_json (List.assoc "sources" fields) in
  let* unread = Source.list_of_json (List.assoc "unread" fields) in
  let* initial_current = current_of_json (List.assoc "initial_current" fields) in
  let* decisions = list_of_json decision_of_stage_json (List.assoc "stages" fields) in
  let* program = create ~transaction_id ~keeper_id ~turn_ref ~sources ~unread ~initial_current ~decisions in
  if Yojson.Safe.sort (to_json program) = Yojson.Safe.sort json then Ok program
  else Error "Memory program computed stages or final facts are not canonical"

let execution_of_json json =
  let* fields = object_fields ["schema_version";"program";"initial_facts";"stages";"final_facts"] json in
  let* () = schema_is_one fields in
  let* program = of_json (List.assoc "program" fields) in
  let* current = facts_of_json (List.assoc "initial_facts" fields) in
  let* execution = replay program ~current in
  if Yojson.Safe.sort (execution_to_json execution) = Yojson.Safe.sort json then Ok execution
  else Error "locked Memory program execution is not canonical"
