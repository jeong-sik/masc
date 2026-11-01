module Board = Masc_board_handlers.Board_initialization
module Lease = Server_startup_takeover

type raised = { exception_ : exn; backtrace : Printexc.raw_backtrace }
type problem =
  | Empty_base_path
  | Invalid_intent
  | Not_directory of string
  | Root_changed of string
  | Parent_refused of Fs_compat.owned_directory_chain_rejection
  | Workspace_in_use of { owner : Lease.base_path_owner; lock_path : string }
  | Lease_rejected of Lease.base_path_lock_rejection
  | Raised of { stage : string; evidence : raised }

type body = Inspection of Board.inspection | Outcome of Board.outcome | Refused of problem
type operation = Inspect | Bootstrap | Adopt
type response = {
  operation : operation;
  body : body;
  release_attempted : bool;
  release_failure : raised option;
}

type root = {
  requested : string;
  canonical : string;
  device : int;
  inode : int;
  parent : Fs_compat.owned_directory_chain_observation;
}

let caught exception_ = { exception_; backtrace = Printexc.get_raw_backtrace () }
let response operation body =
  { operation; body; release_attempted = false; release_failure = None }

let blocking operation =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> operation ()
  | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread ~label:"board-posts-offline" operation

let anchor path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

let parent canonical =
  Fs_compat.inspect_owned_directory_chain ~ownership_root:canonical
    (Filename.concat canonical Common.masc_dirname)
  |> Result.map_error (fun error -> Parent_refused error)

let capture requested =
  let open Result.Syntax in
  let canonical = Unix.realpath requested in
  let stat = Unix.lstat canonical in
  if stat.Unix.st_kind <> Unix.S_DIR then Error (Not_directory canonical)
  else
    let* parent = parent canonical in
    Ok { requested; canonical; device = stat.Unix.st_dev; inode = stat.Unix.st_ino; parent }

let validate root =
  let open Result.Syntax in
  let current = Unix.realpath root.requested in
  let same path =
    let stat = Unix.lstat path in
    stat.Unix.st_kind = Unix.S_DIR && stat.Unix.st_dev = root.device
    && stat.Unix.st_ino = root.inode in
  if not (same current && same root.canonical) then Error (Root_changed root.requested)
  else
    let* observed = parent root.canonical in
    match root.parent, observed with
    | Fs_compat.Owned_directory_missing, _ -> Ok ()
    | Owned_directory before, Owned_directory after
      when before.Unix.st_dev = after.Unix.st_dev && before.Unix.st_ino = after.Unix.st_ino -> Ok ()
    | Owned_directory _, (Owned_directory_missing | Owned_directory _) ->
      Error (Root_changed (Filename.concat root.canonical Common.masc_dirname))

let valid_intent text =
  match Agent_core_sha256.consistent_of_hex_opt text with
  | Some digest -> String.equal text (Agent_core_sha256.to_hex digest)
  | None -> false

let inspect ~base_path =
  if String.equal base_path "" then response Inspect (Refused Empty_base_path)
  else
    try
      let requested = anchor base_path in
      response Inspect (Inspection (Board.inspect ~base_path:requested))
    with exception_ -> response Inspect (Refused (Raised { stage = "inspect"; evidence = caught exception_ }))

let apply operation ~base_path ~expected_intent_sha256 =
  if String.equal base_path "" then response operation (Refused Empty_base_path)
  else if not (valid_intent expected_intent_sha256) then response operation (Refused Invalid_intent)
  else
    try
      let requested = anchor base_path in
      blocking (fun () ->
        try
          match capture requested with
          | Error error -> response operation (Refused error)
          | Ok root ->
            let run_dir = (Host_config.host ()).base_path_lease_dir in
            (match Lease.acquire_base_path_lock ~run_dir root.canonical with
             | Lease.Base_path_already_owned { owner; lock_path } ->
               response operation (Refused (Workspace_in_use { owner; lock_path }))
             | Base_path_rejected error -> response operation (Refused (Lease_rejected error))
             | Base_path_acquired lease ->
               let release_failure = ref None in
               let body = Fun.protect
                   ~finally:(fun () ->
                     try Lease.release_base_path_lease lease
                     with exception_ -> release_failure := Some (caught exception_))
                   (fun () ->
                     try
                       match validate root with
                       | Error error -> Refused error
                       | Ok () ->
                         let outcome = match operation with
                           | Bootstrap -> Board.bootstrap_offline ~base_path:root.requested ~expected_intent_sha256
                           | Adopt -> Board.adopt_offline ~base_path:root.requested ~expected_intent_sha256
                           | Inspect -> invalid_arg "offline mutation requires bootstrap or adopt" in
                         Outcome outcome
                     with exception_ -> Refused (Raised { stage = "protocol"; evidence = caught exception_ })) in
               { operation; body; release_attempted = true; release_failure = !release_failure })
        with exception_ -> response operation (Refused (Raised { stage = "acquire"; evidence = caught exception_ })))
    with exception_ -> response operation (Refused (Raised { stage = "anchor"; evidence = caught exception_ }))

let bootstrap ~base_path ~expected_intent_sha256 = apply Bootstrap ~base_path ~expected_intent_sha256
let adopt ~base_path ~expected_intent_sha256 = apply Adopt ~base_path ~expected_intent_sha256

let rec reserved = function
  | Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory | Stack_overflow | Sys.Break -> true
  | Eio.Exn.Multiple failures -> List.exists (fun (exception_, _) -> reserved exception_) failures
  | _ -> false

let propagate evidence =
  if reserved evidence.exception_ then
    Printexc.raise_with_backtrace evidence.exception_ evidence.backtrace

let finish result =
  (match result.body with
   | Inspection inspection -> Board.finish_inspection inspection
   | Outcome outcome -> ignore (Board.finish_outcome outcome)
   | Refused (Raised { evidence; _ }) -> propagate evidence
   | Refused _ -> ());
  Option.iter propagate result.release_failure

let exit_code result =
  match result.release_failure, result.body with
  | Some _, _ | None, Refused _ -> 1
  | None, Inspection inspection ->
    (match Board.decision inspection with Board.Refused -> 1 | _ -> 0)
  | None, Outcome outcome ->
    (match Board.completion outcome with Board.Completed -> 0 | Not_completed -> 1)

let problem_json = function
  | Empty_base_path -> `Assoc ["kind", `String "empty_base_path"]
  | Invalid_intent -> `Assoc ["kind", `String "invalid_intent"]
  | Not_directory path -> `Assoc ["kind", `String "base_path_not_directory"; "path", `String path]
  | Root_changed path -> `Assoc ["kind", `String "root_changed"; "path", `String path]
  | Parent_refused error -> `Assoc ["kind", `String "parent_refused";
      "detail", `String (Fs_compat.owned_directory_chain_rejection_to_string error)]
  | Workspace_in_use { owner; lock_path } ->
    let owner_kind = match owner with
      | Lease.Owner_this_process _ -> "this_process"
      | Owner_recorded _ -> "recorded"
      | Owner_unnamed -> "unnamed" in
    `Assoc ["kind", `String "workspace_in_use"; "owner_kind", `String owner_kind;
      "lock_path", `String lock_path]
  | Lease_rejected error -> `Assoc ["kind", `String "lease_rejected";
      "detail", `String (Lease.base_path_lock_rejection_to_string error)]
  | Raised { stage; evidence } -> `Assoc ["kind", `String "raised";
      "stage", `String stage; "detail", `String (Printexc.to_string evidence.exception_)]

let response_to_yojson result =
  let operation = match result.operation with Inspect -> "inspect" | Bootstrap -> "bootstrap" | Adopt -> "adopt" in
  let body, refusal = match result.body with
    | Inspection inspection -> Board.inspection_to_yojson inspection, `Null
    | Outcome outcome -> Board.outcome_to_yojson outcome, `Null
    | Refused error -> `Null, problem_json error in
  `Assoc ["schema", `String "masc.board_posts_offline.v1";
    "operation", `String operation; "read_only", `Bool (result.operation = Inspect);
    "live_posts_guard_enforced", `Bool false; "result", body; "refusal", refusal;
    "lease_release", `String (if result.release_attempted then "attempted" else "not_acquired");
    "lease_release_failure", (match result.release_failure with None -> `Null
      | Some failure -> `String (Printexc.to_string failure.exception_))]
