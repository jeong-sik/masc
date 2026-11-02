module Inspection = Board_initialization_inspect
module Source = Board_posts_source
module Guard = Board_posts_guard_json
module Sha256 = Agent_core_sha256

type completion = Completed | Not_completed
type action = Bootstrap | Adopt
type io = { read : Inspection.file_io; write : Inspection.file_io }
type file = Posts | Guard
type raised = Inspection.raised

type preparation =
  | Snapshot_confirmed of Fs_compat.private_jsonl_snapshot Fs_compat.private_jsonl_success_receipt
  | Snapshot_refused of Fs_compat.private_jsonl_transaction_error
  | Snapshot_raised of raised

type write_failure =
  | Transaction_error of Fs_compat.private_jsonl_transaction_error
  | Write_raised of raised

type write_effect =
  | Not_attempted
  | Rewrite_confirmed of Fs_compat.Private_jsonl_cursor.t Fs_compat.private_jsonl_success_receipt
  | Rewrite_refused of Fs_compat.private_jsonl_transaction_error
  | Rewrite_unknown of write_failure

type refusal =
  | Invalid_expected_intent
  | Inspection_raised of raised
  | Wrong_decision
  | Intent_changed
  | Boundary_failed of Inspection.root_failure
  | Preparation_failed of file
  | Prepared_content_changed of file
  | Rewrite_failed of file
  | Generation_raised of raised
  | Generation_rejected of Guard.rejection

type t = {
  action : action;
  inspection : Inspection.t option;
  guard_preparation : preparation option;
  posts_preparation : preparation option;
  posts : write_effect;
  guard : write_effect;
  generation : string option;
  refusal : refusal option;
  reserved : raised option;
}

let first first second = match first with Some _ -> first | None -> second

let retain outcome reserved = { outcome with reserved = first outcome.reserved reserved }
let refuse outcome refusal = { outcome with refusal = Some refusal }

let initial action = {
  action; inspection = None; guard_preparation = None; posts_preparation = None;
  posts = Not_attempted; guard = Not_attempted; generation = None;
  refusal = None; reserved = None;
}

let valid_intent value =
  String.length value = 64
  && match Sha256.consistent_of_hex_opt value with
     | Some digest -> String.equal value (Sha256.to_hex digest)
     | None -> false

let reserved_preparation = function
  | Snapshot_confirmed receipt -> Option.bind receipt.settlement_error Source.reserved_transaction
  | Snapshot_refused error -> Source.reserved_transaction error
  | Snapshot_raised raised -> Source.reserved_exception raised

let reserved_effect = function
  | Not_attempted -> None
  | Rewrite_confirmed receipt -> Option.bind receipt.settlement_error Source.reserved_transaction
  | Rewrite_refused error | Rewrite_unknown (Transaction_error error) -> Source.reserved_transaction error
  | Rewrite_unknown (Write_raised raised) -> Source.reserved_exception raised

let read_snapshot io path =
  match (match io with
    | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
    | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after:None)
  with
  | result ->
    (match Fs_compat.private_jsonl_snapshot_success_receipt result with
     | Ok receipt -> Snapshot_confirmed receipt
     | Error error -> Snapshot_refused error)
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Snapshot_raised (exception_, backtrace)

let rewrite io path expected bytes =
  match (match io with
    | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result path ~expected bytes
    | Some io ->
      Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
        ~before_sync_rewrite_parent:io.Fs_compat.before_sync_parent ~io path ~expected bytes)
  with
  | result ->
    (match Fs_compat.private_jsonl_cursor_success_receipt result with
     | Ok receipt -> Rewrite_confirmed receipt
     | Error error when Source.definitely_not_written error -> Rewrite_refused error
     | Error error -> Rewrite_unknown (Transaction_error error))
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    (* Entering the write_effect without a receipt cannot prove a nonwrite. *)
    Rewrite_unknown (Write_raised (exception_, backtrace))

let known_snapshot = function
  | Snapshot_confirmed receipt -> Some receipt.value
  | Snapshot_refused _ | Snapshot_raised _ -> None

let known_write = function
  | Rewrite_confirmed _ -> true
  | Not_attempted | Rewrite_refused _ | Rewrite_unknown _ -> false

let boundary outcome root continue =
  match Inspection.check_boundary root with
  | Ok () -> continue outcome
  | Error failure ->
    retain (refuse outcome (Boundary_failed failure)) (Inspection.root_failure_reserved failure)

let prepare_guard outcome io path =
  let preparation = read_snapshot io path in
  let outcome = retain { outcome with guard_preparation = Some preparation }
      (reserved_preparation preparation) in
  match known_snapshot preparation with
  | None -> Error (refuse outcome (Preparation_failed Guard))
  | Some snapshot when not (Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor) ->
    Error (refuse outcome (Prepared_content_changed Guard))
  | Some _ when Option.is_some outcome.reserved -> Error (refuse outcome (Preparation_failed Guard))
  | Some snapshot -> Ok (outcome, snapshot)

let prepare_posts outcome io path intended =
  let preparation = read_snapshot io path in
  let outcome = retain { outcome with posts_preparation = Some preparation }
      (reserved_preparation preparation) in
  match known_snapshot preparation with
  | None -> Error (refuse outcome (Preparation_failed Posts))
  | Some snapshot ->
    let matches = match intended with
      | Inspection.Missing_posts -> Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor
      | Present_posts { sha256 } ->
        not (Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor)
        && String.equal sha256 (Sha256.to_hex (Sha256.digest_string snapshot.bytes)) in
    if not matches then Error (refuse outcome (Prepared_content_changed Posts))
    else if Option.is_some outcome.reserved then Error (refuse outcome (Preparation_failed Posts))
    else Ok (outcome, snapshot)

let blocking f = match Fs_compat.execution_context () with
  | Non_eio -> f ()
  | Eio_fiber -> Eio_unix.run_in_systhread ~label:"board-offline-generation" f

let mint_guard outcome =
  match blocking (fun () ->
    let generation = Random_id.hex ~bytes:16 in
    match Guard.of_generation generation with
    | Ok guard -> Ok (generation, Guard.encode_jsonl guard)
    | Error error -> Error error) with
  | Ok (generation, bytes) -> Ok ({ outcome with generation = Some generation }, bytes)
  | Error error -> Error (refuse outcome (Generation_rejected error))
  | exception exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let raised = exception_, backtrace in
    Error (retain (refuse outcome (Generation_raised raised)) (Source.reserved_exception raised))

let publish_guard outcome root io path snapshot =
  boundary outcome root (fun outcome ->
    match mint_guard outcome with
    | Error outcome -> outcome
    | Ok (outcome, bytes) ->
      boundary outcome root (fun outcome ->
        let write_effect = rewrite io path snapshot bytes in
        let outcome = retain { outcome with guard = write_effect } (reserved_effect write_effect) in
        if known_write write_effect then outcome else refuse outcome (Rewrite_failed Guard)))

let publish_posts outcome root io posts_path posts_snapshot guard_path guard_snapshot =
  let write_effect = rewrite (Option.map (fun io -> io.write.Inspection.posts) io)
      posts_path posts_snapshot posts_snapshot.Fs_compat.bytes in
  let outcome = retain { outcome with posts = write_effect } (reserved_effect write_effect) in
  if not (known_write write_effect) then refuse outcome (Rewrite_failed Posts)
  else if Option.is_some outcome.reserved then outcome
  else publish_guard outcome root (Option.map (fun io -> io.write.Inspection.guard) io)
      guard_path guard_snapshot

let apply outcome root io intended =
  let workspace_masc_dir = Inspection.workspace_masc_dir root in
  let posts_path = Board_paths.posts_file ~workspace_masc_dir in
  let guard_path = Board_paths.posts_initialization_guard_file ~workspace_masc_dir in
  let guard_io = Option.map (fun io -> io.read.Inspection.guard) io in
  let posts_io = Option.map (fun io -> io.read.Inspection.posts) io in
  boundary outcome root (fun outcome ->
    match prepare_guard outcome guard_io guard_path with
    | Error outcome -> outcome
    | Ok (outcome, guard_snapshot) ->
      (match prepare_posts outcome posts_io posts_path intended with
       | Error outcome -> outcome
       | Ok (outcome, posts_snapshot) ->
         boundary outcome root (fun outcome ->
           let dependent_check = match outcome.action with
             | Adopt -> Ok ()
             | Bootstrap -> Inspection.check_bootstrap_dependents root in
           match dependent_check with
           | Error failure ->
             retain (refuse outcome (Boundary_failed failure)) (Inspection.root_failure_reserved failure)
           | Ok () -> publish_posts outcome root io posts_path posts_snapshot guard_path guard_snapshot)))

let run ?io ~action ~base_path ~expected_intent_sha256 () =
  let outcome = initial action in
  if not (valid_intent expected_intent_sha256) then refuse outcome Invalid_expected_intent
  else match Inspection.read ?io:(Option.map (fun io -> io.read) io) ~base_path () with
    | inspection ->
      let outcome = retain { outcome with inspection = Some inspection }
          (Inspection.retained_reserved inspection) in
      let expected_decision = match action with
        | Bootstrap -> Inspection.Bootstrap_required | Adopt -> Inspection.Adoption_required in
      if Inspection.decision inspection <> expected_decision || Option.is_some outcome.reserved
      then refuse outcome Wrong_decision
      else if Inspection.intent_sha256 inspection <> Some expected_intent_sha256
      then refuse outcome Intent_changed
      else (match Inspection.root inspection, Inspection.posts_intent inspection with
        | Some root, Some intended -> apply outcome root io intended
        | None, _ | Some _, None -> refuse outcome Wrong_decision)
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let raised = exception_, backtrace in
      retain (refuse outcome (Inspection_raised raised)) (Source.reserved_exception raised)

let completion outcome =
  if known_write outcome.posts && known_write outcome.guard
     && Option.is_none outcome.refusal && Option.is_none outcome.reserved
  then Completed else Not_completed

let finish outcome =
  match outcome.reserved with
  | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace
  | None -> completion outcome

let file_name = function Posts -> "posts" | Guard -> "guard"
let string value = `String value
let option f = function None -> `Null | Some value -> f value
let raised_json (exception_, backtrace) = `Assoc [
  "exception", string (Printexc.to_string exception_);
  "backtrace", string (Printexc.raw_backtrace_to_string backtrace);
]
let transaction_json error = `Assoc [
  "kind", string "fs_transaction";
  "detail", string (Fs_compat.private_jsonl_transaction_error_to_string error);
  "reserved_retained", `Bool (Option.is_some (Source.reserved_transaction error));
]
let cursor_json cursor = `Assoc [
  "fingerprint", string (Fs_compat.Private_jsonl_cursor.fingerprint cursor);
  "missing", `Bool (Fs_compat.Private_jsonl_cursor.is_missing cursor);
]
let diagnostics = function None -> `List [] | Some error -> `List [transaction_json error]

let preparation_json = function
  | Snapshot_confirmed receipt -> `Assoc [
      "state", string "snapshot_confirmed"; "cursor", cursor_json receipt.value.cursor;
      "bytes_length", `Int (String.length receipt.value.bytes);
      "diagnostics", diagnostics receipt.settlement_error;
    ]
  | Snapshot_refused error -> `Assoc [
      "state", string "snapshot_refused"; "diagnostics", `List [transaction_json error];
    ]
  | Snapshot_raised raised -> `Assoc ["state", string "snapshot_raised"; "failure", raised_json raised]

let effect_json = function
  | Not_attempted -> `Assoc ["effect", string "unchanged"; "diagnostics", `List []]
  | Rewrite_confirmed receipt -> `Assoc [
      "effect", string "confirmed_now"; "cursor", cursor_json receipt.value;
      "diagnostics", diagnostics receipt.settlement_error;
    ]
  | Rewrite_refused error -> `Assoc [
      "effect", string "unchanged"; "diagnostics", `List [transaction_json error];
    ]
  | Rewrite_unknown (Transaction_error error) -> `Assoc [
      "effect", string "effect_unknown"; "diagnostics", `List [transaction_json error];
    ]
  | Rewrite_unknown (Write_raised raised) -> `Assoc [
      "effect", string "effect_unknown"; "diagnostics", `List [raised_json raised];
    ]

let rejection_json = function
  | Guard.Invalid_json { line; detail } -> `Assoc ["kind", string "invalid_json"; "line", `Int line; "detail", string detail]
  | Field_set_rejected -> `Assoc ["kind", string "field_set_rejected"]
  | Schema_not_string -> `Assoc ["kind", string "schema_not_string"]
  | Unsupported_schema schema -> `Assoc ["kind", string "unsupported_schema"; "schema", string schema]
  | Invalid_generation -> `Assoc ["kind", string "invalid_generation"]

let refusal_json = function
  | Invalid_expected_intent -> `Assoc ["kind", string "invalid_expected_intent"]
  | Inspection_raised raised -> `Assoc ["kind", string "inspection_raised"; "failure", raised_json raised]
  | Wrong_decision -> `Assoc ["kind", string "wrong_decision"]
  | Intent_changed -> `Assoc ["kind", string "intent_changed"]
  | Boundary_failed failure -> `Assoc ["kind", string "boundary_failed"; "failure", Inspection.root_failure_to_yojson failure]
  | Preparation_failed file -> `Assoc ["kind", string "preparation_failed"; "file", string (file_name file)]
  | Prepared_content_changed file -> `Assoc ["kind", string "prepared_content_changed"; "file", string (file_name file)]
  | Rewrite_failed file -> `Assoc ["kind", string "rewrite_failed"; "file", string (file_name file)]
  | Generation_raised raised -> `Assoc ["kind", string "generation_raised"; "failure", raised_json raised]
  | Generation_rejected rejection -> `Assoc ["kind", string "generation_rejected"; "failure", rejection_json rejection]

let to_yojson outcome = `Assoc [
  "schema", string "masc.board_posts_offline_outcome.v1";
  "action", string (match outcome.action with Bootstrap -> "bootstrap" | Adopt -> "adopt");
  "completion", string (match completion outcome with Completed -> "completed" | Not_completed -> "not_completed");
  "inspection", option Inspection.to_yojson outcome.inspection;
  "preparation", `Assoc [
    "guard", option preparation_json outcome.guard_preparation;
    "posts", option preparation_json outcome.posts_preparation;
  ];
  "posts", effect_json outcome.posts; "guard", effect_json outcome.guard;
  "generation", option string outcome.generation;
  "refusal", option refusal_json outcome.refusal;
  "reserved_retained", `Bool (Option.is_some outcome.reserved);
  "live_posts_guard_enforced", `Bool Board_posts_source.live_guard_enforced;
]
