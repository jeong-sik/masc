open Server_auth

module Http = Http_server_eio
module Stream = Server_routes_http_keeper_stream

(* POST /api/v1/keepers/ask-answer

   The operator answers a Keeper's question from whichever surface they happen
   to be at. Two surfaces can submit for the same ask at once and nothing here
   locks the log: the fold settles on first write, so this responds with what
   actually landed rather than echoing what this caller sent. A second
   submission gets the answer that won, not a bare rejection -- the surface
   showing it has to be able to say what was chosen. *)
let ask_answer_failure_status = function
  | Keeper_ask_store.Ask_not_found _ -> `Not_found
  | Keeper_ask_store.Already_answered _ | Keeper_ask_store.Already_withdrawn _ -> `Conflict
  | Keeper_ask_store.Rejected _ -> `Bad_request
  | Keeper_ask_store.Store_failed _ | Keeper_ask_store.Answer_recorded_unconfirmed _ -> `Internal_server_error

let ask_already_answered_response ~ask_id ~answers ~answered_at ~delivered =
  (`Conflict,
   `Assoc
     [ "error", `String (if delivered then "ask already answered" else
         "ask already answered; delivery is pending automatic recovery")
     ; "state", `String "answered"
     ; "ask_id", `String ask_id
     ; "recorded", `Bool true
     ; "delivered", `Bool delivered
     ; "answered_at", `Float answered_at
     ; "answered_question_ids", `List (List.map
         (fun (answer : Keeper_ask.answer) -> `String answer.question_id) answers) ])

let ask_answer_failure_json ~ask_id failure =
  let detail = Keeper_ask_store.answer_failure_to_string failure in
  match failure with
  | Keeper_ask_store.Already_answered { answers; answered_at; _ } ->
      snd (ask_already_answered_response ~ask_id ~answers ~answered_at ~delivered:false)
  | Keeper_ask_store.Answer_recorded_unconfirmed _ ->
      `Assoc [ "error", `String (detail ^ "; delivery awaits automatic recovery")
             ; "state", `String "recording_unconfirmed"
             ; "ask_id", `String ask_id
             ; "recorded", `Bool true
             ; "delivered", `Bool false ]
  | Keeper_ask_store.Ask_not_found _
  | Keeper_ask_store.Already_withdrawn _
  | Keeper_ask_store.Rejected _
  | Keeper_ask_store.Store_failed _ ->
      `Assoc [ ("error", `String detail) ]

(* The wake that closes the loop between a human answering and the Keeper that
   asked. The stimulus carries the ask_id only; the answer stays in
   [Keeper_ask_store] and the turn reads it there. The continuation the Keeper
   recorded when it asked rides along so a woken Keeper replies where the
   question came from rather than wherever its own state last left it. *)
(* What the route says once an answer is recorded. Recording it and telling the
   Keeper are one act: a 2xx when only the first half happened leaves the
   operator believing a decision landed while the Keeper waits on it forever.
   Split out so the choice can be read and tested on its own. *)
let ask_answer_response ~ask_id ~actor ~answer_count ~open_remaining ~delivered =
  let body =
    [
      ("recorded", `Bool true);
      ("ask_id", `String ask_id);
      ("actor", `String actor);
      ("answer_count", `Int answer_count);
      ("delivered", `Bool delivered);
      ("open_remaining", `Int open_remaining);
    ]
  in
  if delivered then (`OK, `Assoc body)
  else
    ( `Internal_server_error,
      `Assoc
        (( "error",
           `String
             "answer recorded; delivery to the keeper is pending automatic recovery" )
        :: body) )

let wake_keeper_for_answered_ask ~base_path ~keeper_name ~ask_id =
  match Keeper_ask_answer_wake.deliver ~base_path ~keeper_name ~ask_id with
  | Ok (Keeper_ask_answer_wake.Enqueued | Already_pending | Already_delivered) -> true
  | Error error ->
      Log.Server.error "ask answer delivery retained (keeper=%s ask_id=%s): %s"
        keeper_name ask_id (Keeper_ask_answer_wake.error_to_string error);
      false

let handle_keeper_ask_answer ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
      let base_path = (Mcp_server.workspace_config state).base_path in
      let parsed =
        Result.bind (Server_json_object_body.fields body_str) (fun fields ->
              let string_field name =
                match List.assoc_opt name fields with
                | Some (`String value) -> Ok (String.trim value)
                | Some _ | None -> Error (Printf.sprintf "%s (string) is required" name)
              in
              let open Result.Syntax in
              let* keeper_name = string_field "name" in
              let* ask_id = string_field "ask_id" in
              let* submissions =
                match List.assoc_opt "answers" fields with
                | Some answers -> Keeper_ask.submissions_of_json answers
                | None -> Error "answers (array) is required"
              in
              let session_id =
                match List.assoc_opt "session_id" fields with
                | Some (`String value) -> Some (String.trim value)
                | Some _ | None -> None
              in
              Ok (keeper_name, ask_id, submissions, session_id))
      in
      match parsed with
      | Error message ->
          respond_json_value_with_cors ~status:`Bad_request request reqd
            (Stream.keeper_chat_stream_error_json message)
      | Ok (keeper_name, ask_id, submissions, session_id) ->
            let responder =
              {
                Keeper_ask.surface = Surface_ref.Dashboard { session_id };
                actor_id = Some actor;
                display_name = None;
              }
            in
            let now = Time_compat.now () in
            match
              Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id ~submissions ~responder
                ~now
            with
            | Error failure ->
                Log.Keeper.info "keeper_ask_answer: keeper=%s ask_id=%s actor=%s refused=%s"
                  keeper_name ask_id actor
                  (Keeper_ask_store.answer_failure_to_string failure);
                let status, body = match failure with
                  | Keeper_ask_store.Already_answered { answers; answered_at; _ } ->
                      let delivered = wake_keeper_for_answered_ask ~base_path ~keeper_name ~ask_id in
                      ask_already_answered_response ~ask_id ~answers ~answered_at ~delivered
                  | Keeper_ask_store.Ask_not_found _
                  | Keeper_ask_store.Already_withdrawn _
                  | Keeper_ask_store.Rejected _
                  | Keeper_ask_store.Store_failed _
                  | Keeper_ask_store.Answer_recorded_unconfirmed _ ->
                      ask_answer_failure_status failure, ask_answer_failure_json ~ask_id failure in
                respond_json_value_with_cors ~status request reqd body
            | Ok answers ->
                Log.Keeper.info "keeper_ask_answer: keeper=%s ask_id=%s actor=%s answers=%d"
                  keeper_name ask_id actor (List.length answers);
                (* The answer is durable now; the Keeper that asked still has
                   no idea. Without this wake it is written down where only a
                   screen reads it and the asker has to remember to go and
                   look, which is why no Keeper had ever asked. *)
                let delivered =
                  wake_keeper_for_answered_ask ~base_path ~keeper_name ~ask_id
                in
                Log.Keeper.info
                  "keeper_ask_answer: keeper=%s ask_id=%s actor=%s answers=%d delivered=%b"
                  keeper_name ask_id actor (List.length answers) delivered;
                let status, body =
                  ask_answer_response ~ask_id ~actor ~answer_count:(List.length answers)
                    ~open_remaining:
                      (Keeper_ask_store.open_ask_count ~base_path ~keeper_name)
                    ~delivered
                in
                respond_json_value_with_cors ~status request reqd body)

(* GET /api/v1/keepers/asks?name=<keeper>&include_resolved=<bool>

   What one Keeper is waiting on a human for. A surface renders these rows and
   answers through POST /api/v1/keepers/ask-answer; the choice ids it sends
   back come from the rows it was given, so no surface ever matches on label
   text and rewording a choice cannot orphan an answer. *)
type ask_followup_frame =
  | Followup_started of Keeper_ask_answer_wake.followup_identity
  | Followup_source of Keeper_ask_answer_wake.followup_identity * Keeper_ask_answer_wake.followup_source
  | Followup_completed of Keeper_ask_answer_wake.followup_identity
let ask_followup_frame_json ~workspace ~state_ready ~keeper_name ~ask_id frame =
  let phase,(identity : Keeper_ask_answer_wake.followup_identity),fields=match frame with
    | Followup_started identity -> "started",identity,[]
    | Followup_completed identity -> "complete",identity,[]
    | Followup_source (identity,source) ->
      let name,value=Keeper_ask_answer_wake.followup_source_to_json source in
      "source",identity,["source",`String name;"value",value] in
  `Assoc ["workspace",workspace;"state_ready",`Bool state_ready;
    "keeper",`String keeper_name;"answer_progress_for",`String ask_id;
    "answer_progress",`Assoc (["state",`String phase;"answered_at",`Float identity.answered_at;
      "stimulus_id",`String identity.stimulus_id] @ fields)]

exception Ask_followup_stream_closed

let stream_keeper_ask_followup ~clock ~base_path ~workspace ~state_ready ~keeper_name
    ~(ask : Keeper_ask.ask) ~resolution request reqd =
  let response = ref None in
  let send frame =
    let output = match !response with
      | Some output -> output
      | None ->
        let output = Server_sse_response.respond ~clock
            ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s reqd
            (Httpun.Response.create
               ~headers:(Stream.keeper_chat_stream_headers (get_origin request)) `OK) in
        response := Some output;
        output in
    let json=ask_followup_frame_json ~workspace ~state_ready ~keeper_name ~ask_id:ask.ask_id frame in
    match Server_sse_response.send output
        (Sse_wire.format_event_yojson ~event_type:"ask_followup" json) with
    | Server_sse_response.Written -> ()
    | Closed | Stalled -> raise Ask_followup_stream_closed in
  (* A close says the response is complete, so only a stream that ran to its
     end is closed. A [send] that did not go out has closed the response
     itself. Any other exception leaves the response as it is and goes to
     the request's error handling (Server_http_ingress): a 500 when nothing
     was sent yet, a cut response after the first frame. *)
  let close () = Option.iter Server_sse_response.close !response in
  match
    if not state_ready then
      respond_json_value_with_cors ~status:`Service_unavailable request reqd
        (Stream.keeper_chat_stream_error_json "workspace state is not ready")
    else match Keeper_ask_answer_wake.observe_followup
        ~on_started:(fun identity -> send (Followup_started identity))
        ~on_source:(fun identity source -> send (Followup_source (identity,source)))
        ~base_path ~keeper_name ~ask ~resolution () with
    | Error detail ->
      respond_json_value_with_cors ~status:`Service_unavailable request reqd
        (Stream.keeper_chat_stream_error_json detail)
    | Ok followup -> send (Followup_completed
        {answered_at=followup.answered_at;stimulus_id=followup.stimulus_id})
  with
  | () -> close ()
  | exception Ask_followup_stream_closed -> ()

let handle_keeper_asks_list ~clock state request reqd =
  let config = Mcp_server.workspace_config state in
  let expected = Uri.query (Uri.of_string request.Httpun.Request.target)
    |> List.filter (fun (name,_) -> name="expected_base_path" || name="expected_masc_root") in
  let precondition = match expected with
    | [] -> Workspace.validate_expected_workspace ~config (`Assoc [])
    | _ ->
      (match List.assoc_opt "expected_base_path" expected, List.assoc_opt "expected_masc_root" expected with
       | Some [base], Some [root] when List.length expected=2 ->
         Workspace.validate_expected_workspace ~config (`Assoc ["expected_workspace",
           `Assoc ["base_path",`String base;"masc_root",`String root]])
       | _ -> Error Workspace.Invalid_workspace_precondition) in
  match precondition with
  | Error Workspace.Invalid_workspace_precondition ->
    respond_json_value_with_cors ~status:`Bad_request request reqd
      (Stream.keeper_chat_stream_error_json "expected_base_path and expected_masc_root must each occur once")
  | Error Workspace.Workspace_precondition_failed ->
    respond_json_value_with_cors ~status:`Conflict request reqd
      (Stream.keeper_chat_stream_error_json "workspace precondition failed")
  | Ok _ ->
  let query = Uri.query (Uri.of_string request.Httpun.Request.target) in
  let progress_query = List.filter (fun (key,_) -> key="answer_progress_for") query in
  let progress_request = match progress_query with
    | [] -> Ok None
    | [_, [ask_id]] when ask_id<>"" ->
        (match List.filter (fun (key,_) -> key="name") query with
         | [_, [name]] when name<>"" -> Ok (Some ask_id)
         | _ -> Error "answer_progress_for requires one named Keeper")
    | _ -> Error "answer_progress_for must occur once with a nonempty Ask id" in
  match progress_request with
  | Error detail -> respond_json_value_with_cors ~status:`Bad_request request reqd
      (Stream.keeper_chat_stream_error_json detail)
  | Ok answer_progress_for ->
  let stream_request = match List.filter (fun (key,_) -> key="answer_progress_stream") query with
    | [] -> Ok false
    | [_, ["true"]] when Option.is_some answer_progress_for -> Ok true
    | _ -> Error "answer_progress_stream requires one true value and an exact answer_progress_for" in
  match stream_request with
  | Error detail -> respond_json_value_with_cors ~status:`Bad_request request reqd
      (Stream.keeper_chat_stream_error_json detail)
  | Ok stream_progress ->
  let paths =
    try
      let base_path = Unix.realpath config.base_path in
      Ok (base_path, `Assoc ["base_path",`String base_path;
        "masc_root",`String (Unix.realpath (Workspace.masc_dir config))]) with
    | Unix.Unix_error _ -> Error "workspace paths are unavailable" in
  match paths with
  | Error detail -> respond_json_value_with_cors ~status:`Service_unavailable request reqd
      (Stream.keeper_chat_stream_error_json detail)
  | Ok (base_path, workspace) ->
  let state_ready = (Server_startup_state.snapshot ()).state_ready in
  let include_resolved =
    Server_utils.bool_query_param request "include_resolved" ~default:false
  in
  let unavailable error =
    respond_json_value_with_cors ~status:`Service_unavailable request reqd
      (`Assoc
        [
          ( "error",
            `Assoc
              [
                ("message", `String (Keeper_ask_store.read_error_to_string error));
                ("path", `String (Keeper_ask_store.read_error_path error));
              ] );
        ])
  in
  let project keeper_name rows =
    let open_count =
      List.fold_left (fun count (_, (_, resolution)) ->
        if Keeper_ask_operator_projection.ask_row_is_open resolution then count + 1 else count)
        0 rows
    in
    let rows =
      rows
      |> List.filter (fun (_, (_, resolution)) ->
           include_resolved || Keeper_ask_operator_projection.ask_row_is_open resolution)
      |> List.map (Keeper_ask_operator_projection.ask_row_json ~keeper_name)
    in
    open_count, rows
  in
  match Server_utils.query_param request "name" with
  | Some keeper_name ->
      (match Keeper_ask_store.rows_result ~base_path ~keeper_name with
       | Error error -> unavailable error
       | Ok Keeper_ask_store.Missing_log when not (Keeper_registry.is_registered ~base_path keeper_name) ->
         respond_json_value_with_cors ~status:`Not_found request reqd
           (Stream.keeper_chat_stream_error_json "keeper has no recorded questions")
       | Ok ((Keeper_ask_store.Missing_log | Stored_rows _) as snapshot) ->
        let rows = match snapshot with
          | Keeper_ask_store.Missing_log -> []
          | Stored_rows rows -> rows
        in
        if stream_progress then
          (match answer_progress_for with
           | None -> respond_json_value_with_cors ~status:`Bad_request request reqd
               (Stream.keeper_chat_stream_error_json "stream requires an exact original Ask")
           | Some ask_id ->
             match List.assoc_opt ask_id rows with
             | None -> respond_json_value_with_cors ~status:`Not_found request reqd
                 (Stream.keeper_chat_stream_error_json "canonical question is unavailable")
             | Some (ask,resolution) -> stream_keeper_ask_followup ~clock
                 ~base_path ~workspace ~state_ready ~keeper_name ~ask ~resolution request reqd)
        else
        let progress_fields = match answer_progress_for with
          | None -> []
          | Some ask_id ->
              let progress = match List.assoc_opt ask_id rows with
                | None -> Error "canonical question is unavailable"
                | Some (ask, resolution) ->
                    Keeper_ask_answer_wake.observe_followup ~base_path ~keeper_name ~ask ~resolution () in
              let body = match progress with
                | Ok followup -> Keeper_ask_answer_wake.followup_to_json followup
                | Error detail -> `Assoc ["state", `String "unavailable"; "detail", `String detail] in
              ["answer_progress_for", `String ask_id; "answer_progress", body] in
        let open_count, rows = project keeper_name rows in
        respond_json_value_with_cors ~status:`OK request reqd
          (`Assoc
            ([
              ("scope", `String "keeper");
              ("workspace", workspace);
              ("state_ready", `Bool state_ready);
              ("keeper", `String keeper_name);
              ("open_count", `Int open_count);
              ("returned", `Int (List.length rows));
              ("asks", `List rows);
            ] @ progress_fields)))
  | None ->
      (* A durable question survives its process registration. Discover its
         canonical owner from the owned Asked records, not the live registry
         or a filename. An incomplete inventory cannot authorize an empty list. *)
      (match Keeper_ask_store.discover_rows_result ~base_path with
       | Error error -> unavailable error
       | Ok logs ->
           let discovered = List.fold_left (fun result log ->
             let open Result.Syntax in
             let* owners = result in
             match log with
             | Keeper_ask_store.Unreadable_log error -> Error error
             | Canonical_rows { keeper_name; rows } -> Ok ((keeper_name, rows) :: owners))
             (Ok []) logs
           in
           match discovered with
           | Error error -> unavailable error
           | Ok owners ->
               let owners =
                 List.sort (fun (ka, _) (kb, _) -> String.compare ka kb) owners
               in
               let open_total, rows =
                 List.fold_left (fun (total, all) (keeper_name, rows) ->
                   let count, projected = project keeper_name rows in
                   count + total, all @ projected)
                   (0, []) owners
               in
               respond_json_value_with_cors ~status:`OK request reqd
                 (`Assoc
                   [
                     ("scope", `String "fleet");
                     ("workspace", workspace);
                     ("state_ready", `Bool state_ready);
                     ("keeper", `Null);
                     ("keeper_count", `Int (List.length owners));
                     ("open_count", `Int open_total);
                     ("returned", `Int (List.length rows));
                     ("asks", `List rows);
                   ]))
