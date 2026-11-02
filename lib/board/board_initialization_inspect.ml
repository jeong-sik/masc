module Guard_rows = Board_posts_guard_rows

type raised = exn * Printexc.raw_backtrace

type file_io = {
  posts : Fs_compat.private_jsonl_transaction_io_for_testing;
  guard : Fs_compat.private_jsonl_transaction_io_for_testing;
}

type decision = Bootstrap_required | Adoption_required | Ready_observed | Refused

type root = {
  requested_path : string;
  canonical_path : string;
  device : int;
  inode : int;
  workspace_masc_dir : string;
}

type root_failure =
  | Empty_base_path
  | Base_path_not_directory of string
  | Root_binding_changed of string
  | Workspace_boundary_refused of Fs_compat.owned_directory_chain_rejection
  | Dependent_entry_present of { path : string; kind : Unix.file_kind }
  | Root_operation_failed of raised

type posts_intent = Missing_posts | Present_posts of { sha256 : string }

type posts_observation =
  | Posts_missing
  | Posts_present of {
      physical_rows : int;
      accepted_rows : int;
      errors : Board_types.posts_row_error list;
      framing : Guard_rows.framing;
      sha256 : string option;
    }

type guard_observation =
  | Guard_missing
  | Guard_present of {
      physical_rows : int;
      framing : Guard_rows.framing;
      sha256 : string option;
      validation : Guard_rows.validation;
    }

type 'a file_observation =
  | File_not_examined
  | File_observed of {
      primary : ('a, Fs_compat.Private_jsonl_unique_fold.error) result;
      cleanup : Fs_compat.private_jsonl_operation_failure option;
    }
  | File_raised of raised
  | File_projection_failed of {
      cause : raised;
      cleanup : Fs_compat.private_jsonl_operation_failure option;
    }

type dependent_entry = {
  file : Board_paths.persisted_file;
  path : string;
  kind : Unix.file_kind option;
}

type inventory = { entries : dependent_entry list; refusal : root_failure option }
type dependents = Dependents_not_examined | Dependents_examined of inventory

type t = {
  captured_root : (root, root_failure) result;
  posts : posts_observation file_observation;
  guard : guard_observation file_observation;
  diagnostics_failure : raised option;
  dependents : dependents;
  boundary : (unit, root_failure) result option;
}

let workspace_masc_dir root = root.workspace_masc_dir

let root_failure_reserved = function
  | Root_operation_failed raised -> Board_posts_source.reserved_exception raised
  | Empty_base_path | Base_path_not_directory _ | Root_binding_changed _
  | Workspace_boundary_refused _ | Dependent_entry_present _ -> None

(* Capture in the worker too, so a syscall's original backtrace is retained
   rather than reconstructed from the caller's scheduling frame. *)
let root_call work =
  let capture () = match work () with
    | result -> result
    | exception exception_ ->
      Error (Root_operation_failed (exception_, Printexc.get_raw_backtrace ()))
  in
  match (match Fs_compat.execution_context () with
    | Non_eio -> capture ()
    | Eio_fiber -> Eio_unix.run_in_systhread ~label:"board-initialization-boundary" capture)
  with
  | result -> result
  | exception exception_ ->
    Error (Root_operation_failed (exception_, Printexc.get_raw_backtrace ()))

let same_root root stat =
  stat.Unix.st_kind = Unix.S_DIR
  && stat.Unix.st_dev = root.device && stat.Unix.st_ino = root.inode

let check_boundary_unix root =
  if not (same_root root (Unix.stat root.requested_path))
  then Error (Root_binding_changed root.requested_path)
  else if not (same_root root (Unix.stat root.canonical_path))
  then Error (Root_binding_changed root.canonical_path)
  else
    match Fs_compat.inspect_owned_directory_chain
      ~ownership_root:root.canonical_path root.workspace_masc_dir with
    | Ok (Owned_directory_missing | Owned_directory _) -> Ok ()
    | Error refusal -> Error (Workspace_boundary_refused refusal)

let check_boundary root = root_call (fun () -> check_boundary_unix root)

let capture_root base_path =
  if String.equal base_path "" then Error Empty_base_path
  else
    (* Relative spelling is anchored before the first worker submission. *)
    match (if Filename.is_relative base_path
      then Filename.concat (Sys.getcwd ()) base_path else base_path) with
    | requested_path -> root_call (fun () ->
        let canonical_path = Unix.realpath requested_path in
        let stat = Unix.stat canonical_path in
        if stat.Unix.st_kind <> Unix.S_DIR
        then Error (Base_path_not_directory canonical_path)
        else
          let root = {
            requested_path; canonical_path;
            device = stat.Unix.st_dev; inode = stat.Unix.st_ino;
            workspace_masc_dir = Common.masc_dir_from_base_path ~base_path:canonical_path;
          } in
          Result.map (fun () -> root) (check_boundary_unix root))
    | exception exception_ ->
      Error (Root_operation_failed (exception_, Printexc.get_raw_backtrace ()))

let dependent_files = [
  Board_paths.Comments; Reactions; Sub_boards; Votes;
]

(* No-follow leaf observations; stop once there is no bootstrap to authorize.
   A partial inventory is explicitly distinguished in its projection. *)
let inventory root =
  let rec scan entries = function
    | [] -> Ok { entries = List.rev entries; refusal = None }
    | file :: rest ->
      let path = Board_paths.file_path ~workspace_masc_dir:root.workspace_masc_dir file in
      (match Unix.lstat path with
       | stat ->
         let entry = { file; path; kind = Some stat.Unix.st_kind } in
         Ok {
           entries = List.rev (entry :: entries);
           refusal = Some (Dependent_entry_present { path; kind = stat.Unix.st_kind });
         }
       | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
         scan ({ file; path; kind = None } :: entries) rest
       | exception exception_ ->
         Ok {
           entries = List.rev entries;
           refusal = Some (Root_operation_failed
             (exception_, Printexc.get_raw_backtrace ()));
         })
  in
  match root_call (fun () -> scan [] dependent_files) with
  | Ok observed -> observed
  | Error failure -> { entries = []; refusal = Some failure }

let check_bootstrap_dependents root =
  match (inventory root).refusal with None -> Ok () | Some error -> Error error

let reserved_operation (failure : Fs_compat.private_jsonl_operation_failure) =
  Board_posts_source.reserved_exception (failure.exception_, failure.backtrace)

let reserved_fold_error = function
  | Fs_compat.Private_jsonl_unique_fold.Non_regular_file _ | Snapshot_changed -> None
  | Binding_refused error -> Board_posts_source.reserved_transaction error
  | Operation_failed failure -> reserved_operation failure

let first left right = match left with Some _ -> left | None -> right ()

let file_reserved = function
  | File_not_examined -> None
  | File_raised raised -> Board_posts_source.reserved_exception raised
  | File_projection_failed { cause; cleanup } ->
    (* The read and its settlement preceded projection of the observed rows. *)
    first (Option.bind cleanup reserved_operation)
      (fun () -> Board_posts_source.reserved_exception cause)
  | File_observed { primary; cleanup } ->
    let primary = match primary with Ok _ -> None | Error error -> reserved_fold_error error in
    first primary (fun () -> Option.bind cleanup reserved_operation)

let fold_file ~io path ~init ~f ~observe =
  let fold = match io with
    | None -> Fs_compat.fold_private_jsonl_unique_regular_locked_result
    | Some io -> Fs_compat.fold_private_jsonl_unique_regular_locked_with_io_for_testing ~io
  in
  let project ~cleanup value = match observe value with
    | observation -> File_observed { primary = Ok observation; cleanup }
    | exception exception_ -> File_projection_failed {
        cause = exception_, Printexc.get_raw_backtrace (); cleanup;
      } in
  match fold path ~init ~f with
  | Fs_compat.Private_file_succeeded value ->
    project ~cleanup:None value
  | Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
    project ~cleanup:(Some cleanup_failure) value
  | Private_file_failed error -> File_observed { primary = Error error; cleanup = None }
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    File_observed { primary = Error error; cleanup = Some cleanup_failure }
  | exception exception_ -> File_raised (exception_, Printexc.get_raw_backtrace ())

type posts_rows = {
  digest : Agent_core_sha256.ctx;
  physical_rows : int;
  accepted_rows : int;
  errors_rev : Board_types.posts_row_error list;
  diagnostics_rev : Board_content_json.diagnostic list;
}

let feed_row digest text =
  Agent_core_sha256.feed_string digest text
  |> fun digest -> Agent_core_sha256.feed_string digest "\n"

let decode_posts_row rows text =
  let line = rows.physical_rows + 1 in
  let rows = { rows with digest = feed_row rows.digest text; physical_rows = line } in
  match Board_posts_rows.decode ~line text with
  | Blank -> rows
  | Accepted { post = _; diagnostics } -> {
      rows with accepted_rows = rows.accepted_rows + 1;
      diagnostics_rev = List.rev_append diagnostics rows.diagnostics_rev;
    }
  | Rejected { error; diagnostics } -> {
      rows with errors_rev = error :: rows.errors_rev;
      diagnostics_rev = List.rev_append diagnostics rows.diagnostics_rev;
    }

let complete_sha256 framing digest = match framing with
  | Guard_rows.Complete -> Some (Agent_core_sha256.to_hex (Agent_core_sha256.get digest))
  | Guard_rows.Torn _ -> None

let read_posts ~io root =
  let init = {
    digest = Agent_core_sha256.init (); physical_rows = 0; accepted_rows = 0;
    errors_rev = []; diagnostics_rev = [];
  } in
  let observe = function
    | Fs_compat.Private_jsonl_fold.Missing -> Posts_missing, []
    | Present { value; rows_end; end_offset } ->
      let framing = Guard_rows.framing ~rows_end ~end_offset in
      let diagnostics = match framing with
        | Guard_rows.Complete -> List.rev value.diagnostics_rev
        | Guard_rows.Torn _ -> [] in
      Posts_present {
        physical_rows = value.physical_rows; accepted_rows = value.accepted_rows;
        errors = List.rev value.errors_rev; framing;
        sha256 = complete_sha256 framing value.digest;
      }, diagnostics
  in
  let result = fold_file ~io (Board_paths.posts_file ~workspace_masc_dir:root.workspace_masc_dir)
    ~init ~f:decode_posts_row ~observe in
  match result with
  | File_not_examined -> File_not_examined, None
  | File_raised raised -> File_raised raised, None
  | File_projection_failed { cause; cleanup } ->
    File_projection_failed { cause; cleanup }, None
  | File_observed { primary = Error error; cleanup } ->
    File_observed { primary = Error error; cleanup }, None
  | File_observed { primary = Ok (observation, diagnostics); cleanup } ->
    let diagnostics_failure = match Board_content_diagnostics.emit diagnostics with
      | () -> None
      | exception exception_ -> Some (exception_, Printexc.get_raw_backtrace ()) in
    File_observed { primary = Ok observation; cleanup }, diagnostics_failure

type guard_rows = {
  digest : Agent_core_sha256.ctx;
  rows : Guard_rows.rows;
}

let decode_guard_row rows text = {
  digest = feed_row rows.digest text;
  rows = Guard_rows.add_row rows.rows text;
}

let read_guard ~io root =
  let init = { digest = Agent_core_sha256.init (); rows = Guard_rows.empty } in
  let observe = function
    | Fs_compat.Private_jsonl_fold.Missing -> Guard_missing
    | Present { value; rows_end; end_offset } ->
      let framing = Guard_rows.framing ~rows_end ~end_offset in
      let validation = Guard_rows.validate ~framing value.rows in
      Guard_present {
        physical_rows = Guard_rows.physical_rows value.rows; framing;
        sha256 = complete_sha256 framing value.digest; validation;
      }
  in
  fold_file ~io (Board_paths.posts_initialization_guard_file
    ~workspace_masc_dir:root.workspace_masc_dir) ~init ~f:decode_guard_row ~observe

let retained_reserved inspection =
  let root = match inspection.captured_root with
    | Ok _ -> None | Error failure -> root_failure_reserved failure in
  first root (fun () ->
    first (file_reserved inspection.posts) (fun () ->
      first (Option.bind inspection.diagnostics_failure Board_posts_source.reserved_exception)
        (fun () -> first (file_reserved inspection.guard) (fun () ->
          let dependents = match inspection.dependents with
            | Dependents_not_examined -> None
            | Dependents_examined inventory -> Option.bind inventory.refusal root_failure_reserved in
          first dependents (fun () -> match inspection.boundary with
            | None | Some (Ok ()) -> None
            | Some (Error failure) -> root_failure_reserved failure)))))

let posts_intent inspection = match inspection.posts with
  | File_observed { primary = Ok Posts_missing; _ } -> Some Missing_posts
  | File_observed { primary = Ok (Posts_present {
      framing = Guard_rows.Complete; errors = []; sha256 = Some sha256; _ }); _ } ->
    Some (Present_posts { sha256 })
  | File_not_examined | File_raised _ | File_projection_failed _
  | File_observed { primary = Error _; _ }
  | File_observed { primary = Ok (Posts_present _); _ } -> None

let guard_state inspection = match inspection.guard with
  | File_observed { primary = Ok Guard_missing; _ } -> `Missing
  | File_observed { primary = Ok (Guard_present { validation = Guard_rows.Valid_guard _; _ }); _ } -> `Valid
  | File_not_examined | File_raised _ | File_projection_failed _
  | File_observed { primary = Error _; _ }
  | File_observed { primary = Ok (Guard_present _); _ } -> `Refused

let decision inspection =
  match inspection.captured_root, inspection.boundary,
    inspection.diagnostics_failure, retained_reserved inspection with
  | Ok _, Some (Ok ()), None, None ->
    (match posts_intent inspection, guard_state inspection, inspection.dependents with
     | Some Missing_posts, `Missing, Dependents_examined { refusal = None; _ } -> Bootstrap_required
     | Some (Present_posts _), `Missing, Dependents_not_examined -> Adoption_required
     | Some (Present_posts _), `Valid, Dependents_not_examined -> Ready_observed
     | (None | Some _), (`Missing | `Valid | `Refused),
       (Dependents_not_examined | Dependents_examined _) -> Refused)
  | (Error _ | Ok _), (None | Some (Error _) | Some (Ok ())),
    (None | Some _), (None | Some _) -> Refused

let root inspection = match inspection.captured_root with Ok root -> Some root | Error _ -> None

let posts_source_sha256 inspection = match inspection.posts with
  | File_observed { primary = Ok (Posts_present { sha256; _ }); _ } -> sha256
  | File_not_examined | File_raised _ | File_projection_failed _
  | File_observed { primary = Error _; _ }
  | File_observed { primary = Ok Posts_missing; _ } -> None

let intent_sha256 inspection =
  match decision inspection, root inspection, posts_intent inspection with
  | Bootstrap_required, Some root, Some Missing_posts ->
    let json = `List [
      `String "masc.board_posts_initialization_intent.v1"; `String "bootstrap";
      `List [ `String (string_of_int root.device); `String (string_of_int root.inode) ];
      `List [ `String "posts"; `String "missing" ];
      `List [ `String "guard"; `String "missing" ];
      `List (List.map (fun file ->
        `List [ `String (Filename.basename (Board_paths.file_path
          ~workspace_masc_dir:root.workspace_masc_dir file)); `String "missing" ]) dependent_files);
    ] in
    Some (Agent_core_sha256.to_hex (Agent_core_sha256.digest_string (Yojson.Safe.to_string json)))
  | Adoption_required, Some root, Some (Present_posts { sha256 }) ->
    let json = `List [
      `String "masc.board_posts_initialization_intent.v1"; `String "adopt";
      `List [ `String (string_of_int root.device); `String (string_of_int root.inode) ];
      `List [ `String "posts"; `String "present_regular"; `String sha256 ];
      `List [ `String "guard"; `String "missing" ];
    ] in
    Some (Agent_core_sha256.to_hex (Agent_core_sha256.digest_string (Yojson.Safe.to_string json)))
  | (Bootstrap_required | Adoption_required | Ready_observed | Refused),
    (None | Some _), (None | Some _) -> None

let read ?io ~base_path () =
  let captured_root = capture_root base_path in
  match captured_root with
  | Error _ -> {
      captured_root; posts = File_not_examined; guard = File_not_examined;
      diagnostics_failure = None; dependents = Dependents_not_examined; boundary = None;
    }
  | Ok root ->
    let posts, diagnostics_failure =
      read_posts ~io:(Option.map (fun (io : file_io) -> io.posts) io) root in
    let first_reserved = first (file_reserved posts)
      (fun () -> Option.bind diagnostics_failure Board_posts_source.reserved_exception) in
    let guard = match first_reserved with
      | Some _ -> File_not_examined
      | None -> read_guard ~io:(Option.map (fun (io : file_io) -> io.guard) io) root in
    let reserved = first first_reserved (fun () -> file_reserved guard) in
    let dependents = match posts, guard, diagnostics_failure, reserved with
      | File_observed { primary = Ok Posts_missing; _ },
        File_observed { primary = Ok Guard_missing; _ }, None, None ->
        Dependents_examined (inventory root)
      | (File_not_examined | File_raised _ | File_projection_failed _ | File_observed _),
        (File_not_examined | File_raised _ | File_projection_failed _ | File_observed _),
        (None | Some _), (None | Some _) ->
        Dependents_not_examined in
    let reserved = first reserved (fun () -> match dependents with
      | Dependents_not_examined -> None
      | Dependents_examined inventory -> Option.bind inventory.refusal root_failure_reserved) in
    let boundary = match reserved with Some _ -> None | None -> Some (check_boundary root) in
    { captured_root; posts; guard; diagnostics_failure; dependents; boundary }

let raised_to_yojson ((exception_, _) as raised) = `Assoc [
  "exception", `String (Printexc.to_string exception_);
  "reserved", `Bool (Option.is_some (Board_posts_source.reserved_exception raised));
]

let root_failure_to_yojson = function
  | Empty_base_path -> `Assoc [ "kind", `String "empty_base_path" ]
  | Base_path_not_directory path -> `Assoc [
      "kind", `String "base_path_not_directory"; "path", `String path ]
  | Root_binding_changed path -> `Assoc [
      "kind", `String "root_binding_changed"; "path", `String path ]
  | Workspace_boundary_refused refusal ->
    let fields = match refusal with
      | Fs_compat.Owned_path_outside_root { ownership_root; path } -> [
          "reason", `String "outside_root"; "ownership_root", `String ownership_root;
          "path", `String path ]
      | Owned_path_non_directory { path; kind } -> [
          "reason", `String "non_directory"; "path", `String path;
          "file_kind", `String (Fs_compat.file_kind_to_string kind) ] in
    `Assoc (("kind", `String "workspace_boundary_refused") :: fields)
  | Dependent_entry_present { path; kind } -> `Assoc [
      "kind", `String "dependent_entry_present"; "path", `String path;
      "file_kind", `String (Fs_compat.file_kind_to_string kind) ]
  | Root_operation_failed raised -> `Assoc [
      "kind", `String "root_operation_failed"; "cause", raised_to_yojson raised ]

let option_json encode = function None -> `Null | Some value -> encode value

let operation_to_yojson (failure : Fs_compat.private_jsonl_operation_failure) = `Assoc [
  "detail", `String (Fs_compat.private_jsonl_operation_failure_to_string failure);
  "cause", raised_to_yojson (failure.exception_, failure.backtrace);
]

let fold_error_to_yojson = function
  | Fs_compat.Private_jsonl_unique_fold.Non_regular_file kind -> `Assoc [
      "kind", `String "non_regular_file"; "file_kind", `String (Fs_compat.file_kind_to_string kind) ]
  | Snapshot_changed -> `Assoc [ "kind", `String "snapshot_changed" ]
  | Binding_refused error -> `Assoc [
      "kind", `String "binding_refused";
      "detail", `String (Fs_compat.private_jsonl_transaction_error_to_string error) ]
  | Operation_failed failure -> `Assoc [
      "kind", `String "operation_failed"; "failure", operation_to_yojson failure ]

let row_error_to_yojson = function
  | Board_types.Invalid_posts_json { line; detail } -> `Assoc [
      "kind", `String "invalid_json"; "line", `Int line; "detail", `String detail ]
  | Invalid_posts_row { line } -> `Assoc [ "kind", `String "invalid_row"; "line", `Int line ]

let posts_to_yojson = function
  | Posts_missing -> `Assoc [ "state", `String "missing" ]
  | Posts_present { physical_rows; accepted_rows; errors; framing; sha256 } -> `Assoc [
      "state", `String "present"; "physical_rows", `Int physical_rows;
      "accepted_rows", `Int accepted_rows; "errors", `List (List.map row_error_to_yojson errors);
      "framing", Guard_rows.framing_to_yojson framing; "sha256", option_json (fun sha -> `String sha) sha256 ]

let guard_to_yojson = function
  | Guard_missing -> `Assoc [ "state", `String "missing" ]
  | Guard_present { physical_rows; framing; sha256; validation } -> `Assoc [
      "state", `String "present"; "physical_rows", `Int physical_rows;
      "framing", Guard_rows.framing_to_yojson framing; "sha256", option_json (fun sha -> `String sha) sha256;
      "validation", Guard_rows.validation_to_yojson validation ]

let file_to_yojson encode = function
  | File_not_examined -> `Assoc [ "state", `String "not_examined" ]
  | File_raised raised -> `Assoc [ "state", `String "raised"; "cause", raised_to_yojson raised ]
  | File_projection_failed { cause; cleanup } -> `Assoc [
      "state", `String "projection_failed"; "read_primary_succeeded", `Bool true;
      "cause", raised_to_yojson cause;
      "settlement_diagnostic", option_json operation_to_yojson cleanup ]
  | File_observed { primary; cleanup } ->
    let primary = match primary with
      | Ok observation -> encode observation
      | Error error -> `Assoc [ "state", `String "refused"; "error", fold_error_to_yojson error ] in
    `Assoc [ "observation", primary; "settlement_diagnostic", option_json operation_to_yojson cleanup ]

let file_name = function
  | Board_paths.Posts -> "posts" | Comments -> "comments" | Reactions -> "reactions"
  | Sub_boards -> "sub_boards" | Votes -> "votes"

let dependents_to_yojson = function
  | Dependents_not_examined -> `Assoc [ "state", `String "not_examined" ]
  | Dependents_examined { entries; refusal } -> `Assoc [
      "state", `String "examined"; "complete", `Bool (Option.is_none refusal);
      "entries", `List (List.map (fun entry -> `Assoc [
        "family", `String (file_name entry.file); "path", `String entry.path;
        "kind", (match entry.kind with None -> `String "missing"
          | Some kind -> `String (Fs_compat.file_kind_to_string kind)) ]) entries);
      "refusal", option_json root_failure_to_yojson refusal ]

let to_yojson inspection =
  let decision = match decision inspection with
    | Bootstrap_required -> "bootstrap_required" | Adoption_required -> "adoption_required"
    | Ready_observed -> "ready_observed" | Refused -> "refused" in
  let root = match inspection.captured_root with
    | Error failure -> `Assoc [ "state", `String "refused"; "error", root_failure_to_yojson failure ]
    | Ok root -> `Assoc [
        "state", `String "observed"; "requested_path", `String root.requested_path;
        "canonical_path", `String root.canonical_path;
        "device", `String (string_of_int root.device); "inode", `String (string_of_int root.inode) ] in
  `Assoc [
    "decision", `String decision; "root", root;
    "posts", file_to_yojson posts_to_yojson inspection.posts;
    "guard", file_to_yojson guard_to_yojson inspection.guard;
    "dependents", dependents_to_yojson inspection.dependents;
    "diagnostics_failure", option_json raised_to_yojson inspection.diagnostics_failure;
    "boundary", (match inspection.boundary with
      | None -> `Assoc [ "state", `String "not_examined" ]
      | Some (Ok ()) -> `Assoc [ "state", `String "observed" ]
      | Some (Error failure) -> `Assoc [
          "state", `String "refused"; "error", root_failure_to_yojson failure ]);
    "intent_sha256", option_json (fun sha -> `String sha) (intent_sha256 inspection);
    "posts_source_sha256", option_json (fun sha -> `String sha) (posts_source_sha256 inspection);
    "live_posts_guard_enforced", `Bool false;
  ]

let finish inspection = match retained_reserved inspection with
  | None -> ()
  | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace
