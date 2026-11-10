module Http = Http_server_eio
module Work = Keeper_librarian_history_resolution_work
module Intent = Keeper_librarian_history_resolution_intent
module State = Keeper_librarian_history_resolution_state
module Resolution = Keeper_librarian_history_resolution
module Original = Keeper_librarian_durable_request
module Json = Candle_json

open Result.Syntax

let permission = Masc_domain.CanAdmin
let request_schema = "keeper.memory.history_original_resolution.request.v1"
let response_schema = "keeper.memory.history_original_resolution.v1"

type target = { keeper_name : string; request_id : string }

let route path =
  match String.split_on_char '/' path with
  | [ ""; "api"; "v1"; "keepers"; keeper; "memory-history-originals";
      original; "resolution" ] when keeper <> "" && original <> "" ->
    Some { keeper_name = Uri.pct_decode keeper; request_id = Uri.pct_decode original }
  | _ -> None

let validate_target target =
  let* () =
    match Keeper_identity.Keeper_id.of_string target.keeper_name with
    | Some keeper when Keeper_identity.Keeper_id.to_string keeper = target.keeper_name
        && Keeper_config.validate_name target.keeper_name -> Ok ()
    | None | Some _ -> Error "invalid canonical Keeper name"
  in
  Original.scope_of_request_id target.request_id |> Result.map (fun _ -> ())

type submission_request = { expected : State.guard; reason : string }
type parse_error = Invalid_body of string | Workspace_precondition of Workspace.expected_workspace_error

let parse ~config body =
  let* fields = Server_json_object_body.fields body |> Result.map_error (fun detail -> Invalid_body detail) in
  let* () =
    if List.mem_assoc "expected_workspace" fields then Ok ()
    else Error (Invalid_body "expected_workspace is required")
  in
  let* json = Workspace.validate_expected_workspace ~config (`Assoc fields)
    |> Result.map_error (fun error -> Workspace_precondition error) in
  let decoded =
    let context = "history original resolution request" in
    let* fields = Json.object_fields ~context json in
    let* schema, fields = Json.field ~context "schema" Json.as_string fields in
    let* () = if schema = request_schema then Ok () else Error "unsupported request schema" in
    let* expected, fields = Json.field ~context "expected" State.guard_of_json fields in
    let* reason, fields = Json.field ~context "reason" Json.as_non_blank fields in
    let+ () = Json.finish ~context fields in
    { expected; reason }
  in
  Result.map_error (fun detail -> Invalid_body detail) decoded

let respond request reqd ?(status = `OK) json =
  Http.Response.json_value ~status ~request
    ~extra_headers:[ "cache-control", "no-store" ] json reqd

let invalid_request request reqd detail =
  respond request reqd ~status:`Bad_request
    (Server_refusal.json ~code:"invalid_request" detail)

let private_failure ~keeper_name ~code detail =
  let incident_id = Random_id.uuid_v7 () in
  Log.Keeper.warn ~keeper_name
    "history original resolution incident_id=%s code=%s detail=%s" incident_id code detail;
  [ "code", `String code; "incident_id", `String incident_id ]

let respond_work_error request reqd target error =
  let status, code, message, fields = match error with
    | Intent.Invalid detail ->
      `Bad_request, "invalid_resolution_request", "Invalid history resolution request",
      private_failure ~keeper_name:target.keeper_name ~code:"invalid_resolution_request" detail
    | Conflict detail ->
      `Conflict, "resolution_conflict", "History resolution observation conflicts",
      private_failure ~keeper_name:target.keeper_name ~code:"resolution_conflict" detail
    | Unavailable detail ->
      `Service_unavailable, "resolution_unavailable", "History resolution is unavailable",
      private_failure ~keeper_name:target.keeper_name ~code:"resolution_unavailable" detail
    | Publication_uncertain detail ->
      `Service_unavailable, "resolution_publication_unconfirmed",
      "History resolution acceptance is unconfirmed; observe this exact original",
      ("durable_acceptance", `String "unconfirmed") ::
      private_failure ~keeper_name:target.keeper_name
        ~code:"resolution_publication_unconfirmed" detail
  in
  (* The code is selected from the closed error above, never from diagnostic text. *)
  let fields = List.remove_assoc "code" fields in
  respond request reqd ~status (Server_refusal.json ~code ~fields message)

let fence_json (fence : State.t) =
  `Assoc [ "request_id", `String fence.request_id;
    "request_digest", `String fence.request_digest;
    "source_sha256", `String fence.source_sha256;
    "expected", State.guard_to_json fence.expected;
    "actor", `String fence.actor; "reason", `String fence.reason;
    "fenced_at", `Float fence.fenced_at ]

let completion_json ~keeper_name = function
  | Work.Not_observed -> `Assoc [ "kind", `String "not_observed" ]
  | Memory_committed { request_id } ->
    `Assoc [ "kind", `String "memory_committed"; "request_id", `String request_id ]
  | Completion_unavailable detail ->
    `Assoc (("kind", `String "unavailable") ::
      private_failure ~keeper_name ~code:"memory_completion_unavailable" detail)

let original_range_json ~keeper_name = function
  | Error detail ->
    `Assoc (("kind", `String "unavailable") ::
      private_failure ~keeper_name ~code:"original_range_unavailable" detail)
  | Ok (range : Work.original_range) ->
    let atom = match range.atom with
      | None -> `Null
      | Some atom -> `Assoc [ "trace_id", `String atom.trace_id;
          "history_start_boundary_line", `Int atom.history_start_boundary_line;
          "start_atom", `Int atom.start_atom; "end_atom", `Int atom.end_atom ] in
    let official = match range.official with
      | None -> `Null
      | Some official -> `Assoc [ "after_boundary_line", `Int official.after_boundary_line;
          "selected_through", `Int official.selected_through;
          "selected_count", `Int official.selected_count ] in
    `Assoc [ "kind", `String "observed"; "atom", atom; "official", official ]

let refused_preview ~keeper_name error =
  let kind, eligible, fields = match error with
    | Resolution.Original_absent -> "original_absent", `Bool false, []
    | Ineligible detail -> "ineligible", `Bool false,
      private_failure ~keeper_name ~code:"history_original_ineligible" detail
    | Observation_changed -> "observation_changed", `Bool false, []
    | Range_already_recorded -> "range_already_recorded", `Bool false, []
    | Already_fenced _ -> "already_fenced", `Bool false, []
    | Unavailable detail -> "unavailable", `Null,
      private_failure ~keeper_name ~code:"resolution_preview_unavailable" detail
    | Publication_uncertain detail -> "publication_unconfirmed", `Null,
      private_failure ~keeper_name ~code:"resolution_publication_unconfirmed" detail
  in
  `Assoc ([ "kind", `String kind; "eligible", eligible ] @ fields)

let handle_get state request reqd target =
  match validate_target target with
  | Error detail -> invalid_request request reqd detail
  | Ok () ->
    let config = Mcp_server.workspace_config state in
    let result = Pool_work.submit (Pool_work.io ~name:__FUNCTION__ (fun () ->
      let+ observation = Work.read ~config ~keeper_name:target.keeper_name
        ~request_id:target.request_id in
      let preview = match observation.fence with
        | Some fence -> Error (Resolution.Already_fenced fence)
        | None -> Resolution.preview ~config ~keeper_name:target.keeper_name
            ~request_id:target.request_id in
      observation, preview)) in
    match result with
    | Error error -> respond_work_error request reqd target error
    | Ok (observation, preview) ->
      let fence, preview = match preview with
        | Ok preview -> observation.fence,
          `Assoc [ "kind", `String "eligible"; "eligible", `Bool true;
            "expected", State.guard_to_json preview.expected;
            "request_digest", `String preview.request_digest ]
        | Error (Resolution.Already_fenced fence as error) ->
          Some fence, refused_preview ~keeper_name:target.keeper_name error
        | Error ((Original_absent | Ineligible _ | Observation_changed
                 | Range_already_recorded | Unavailable _ | Publication_uncertain _) as error) ->
          observation.fence, refused_preview ~keeper_name:target.keeper_name error
      in
      respond request reqd (`Assoc [ "schema", `String response_schema;
        "keeper", `String target.keeper_name; "request_id", `String target.request_id;
        "preview", preview;
        "intents", `List (List.map Intent.to_public_json observation.intents);
        "fence", (match fence with None -> `Null | Some value -> fence_json value);
        "original_range", original_range_json ~keeper_name:target.keeper_name observation.original_range;
        "completion", completion_json ~keeper_name:target.keeper_name observation.completion ])

type scheduling =
  | Librarian_disabled
  | Librarian_invalid
  | Executor_uninitialized
  | Lane_outcome of Keeper_memory_lane.outcome
  | Scheduling_failed of string

let schedule ~config ~keeper_name =
  try
    match Env_config.KeeperMemoryOs.librarian_config_state () with
    | Disabled -> Librarian_disabled
    | Invalid -> Librarian_invalid
    | Enabled -> Eio_context.run_on_owner_domain (fun () ->
        if Keeper_memory_lane.initialized () then
          Lane_outcome (Keeper_librarian_queue_refresh.submit_durable
            ~base_path:config.Workspace.base_path ~keeper_name)
        else Executor_uninitialized)
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | error -> Scheduling_failed (Printexc.to_string error)

let scheduling_response ~keeper_name = function
  | Lane_outcome Keeper_memory_lane.Submitted ->
    `Accepted, true, [ "kind", `String "submitted" ], []
  | Lane_outcome Coalesced -> `Accepted, true, [ "kind", `String "coalesced" ], []
  | Librarian_disabled -> `Conflict, false, [ "kind", `String "librarian_disabled" ],
    [ "code", `String "librarian_disabled"; "error", `String "Librarian is disabled; intent remains recorded" ]
  | Librarian_invalid -> `Conflict, false, [ "kind", `String "librarian_invalid" ],
    [ "code", `String "librarian_invalid"; "error", `String "Librarian configuration is invalid; intent remains recorded" ]
  | Executor_uninitialized -> `Service_unavailable, false,
    [ "kind", `String "executor_uninitialized" ],
    [ "code", `String "executor_uninitialized"; "error", `String "Detached executor is unavailable; intent remains recorded" ]
  | Lane_outcome Ran_inline -> `Service_unavailable, false, [ "kind", `String "ran_inline" ],
    [ "code", `String "detached_completion_unconfirmed";
      "error", `String "Memory work ran inline; completion is unconfirmed and intent remains recorded" ]
  | Lane_outcome Dropped -> `Service_unavailable, false, [ "kind", `String "dropped" ],
    [ "code", `String "wake_dropped"; "error", `String "Memory wake was dropped; intent remains recorded" ]
  | Scheduling_failed detail -> `Service_unavailable, false,
    ("kind", `String "unavailable") ::
      private_failure ~keeper_name ~code:"resolution_scheduling_unavailable" detail,
    [ "code", `String "resolution_scheduling_unavailable";
      "error", `String "Memory scheduling is unavailable; intent remains recorded" ]

let handle_post state ~actor request reqd target body =
  let config = Mcp_server.workspace_config state in
  let parsed =
    let* () = validate_target target |> Result.map_error (fun detail -> Invalid_body detail) in
    parse ~config body in
  match parsed with
  | Error (Invalid_body detail) -> invalid_request request reqd detail
  | Error (Workspace_precondition error) ->
    let status, json = Server_refusal.expected_workspace_error error in
    respond request reqd ~status json
  | Ok parsed ->
    let result = Pool_work.submit (Pool_work.io ~name:__FUNCTION__ (fun () ->
      Work.submit ~config ~keeper_name:target.keeper_name ~request_id:target.request_id
        ~expected:parsed.expected ~actor ~reason:parsed.reason ~now:(Time_compat.now ()))) in
    match result with
    | Error error -> respond_work_error request reqd target error
    | Ok submission ->
      let status, scheduled, scheduling, failure =
        scheduling_response ~keeper_name:target.keeper_name (schedule ~config ~keeper_name:target.keeper_name) in
      respond request reqd ~status (`Assoc ([ "schema", `String response_schema;
        "ok", `Bool scheduled; "keeper", `String target.keeper_name;
        "request_id", `String target.request_id; "durable_acceptance", `String "recorded";
        "reobserved", `Bool submission.reobserved;
        "intent", Intent.to_public_json submission.intent;
        "scheduling", `Assoc scheduling;
        "completion", completion_json ~keeper_name:target.keeper_name Work.Not_observed ] @ failure))
