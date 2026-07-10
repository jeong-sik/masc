open Result.Syntax

type goal_principal = {
  id : string;
  display_name : string option;
}

let goal_principal_to_yojson (principal : goal_principal) =
  `Assoc
    [
      ("id", `String principal.id);
      ( "display_name", Json_util.string_opt_to_json principal.display_name );
    ]

let goal_principal_of_yojson = function
  | `Assoc fields as json -> (
      match Json_util.assoc_member_opt "id" json with
      | Some (`String id) when String.trim id <> "" ->
          Ok
            {
              id = String.trim id;
              display_name = Json_util.get_string json "display_name";
            }
      | Some (`String _) -> Error "goal_principal_of_yojson: id must be non-empty"
      | other ->
          Error
            ("goal_principal_of_yojson: invalid id " ^
             (match other with Some v -> Yojson.Safe.to_string v | None -> "null")))
  | json ->
      Error ("goal_principal_of_yojson: " ^ Yojson.Safe.to_string json)

type inherit_mode =
  | Extend
  | Replace

let inherit_mode_to_string = function
  | Extend -> "extend"
  | Replace -> "replace"

let inherit_mode_of_string = function
  | "extend" -> Some Extend
  | "replace" -> Some Replace
  | _ -> None

let inherit_mode_to_yojson mode =
  `String (inherit_mode_to_string mode)

let inherit_mode_of_yojson = function
  | `String raw -> (
      match String.trim raw |> String.lowercase_ascii |> inherit_mode_of_string with
      | Some mode -> Ok mode
      | None -> Error ("inherit_mode_of_yojson: " ^ raw))
  | json ->
      Error ("inherit_mode_of_yojson: " ^ Yojson.Safe.to_string json)

type goal_verifier_policy = {
  inherit_mode : inherit_mode;
  principals : goal_principal list;
  required_verdicts : int option;
}

let goal_verifier_policy_to_yojson (policy : goal_verifier_policy) =
  `Assoc
    [
      ("inherit_mode", inherit_mode_to_yojson policy.inherit_mode);
      ("principals", `List (List.map goal_principal_to_yojson policy.principals));
      ( "required_verdicts", Json_util.int_opt_to_json policy.required_verdicts );
    ]

let result_map_list f values =
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | raw :: rest ->
        let* item = f raw in
        collect (item :: acc) rest
  in
  collect [] values

(* DET-OK: missing JSON members are rendered as Null only for strict parser
   delegation/error text; this does not accept unknown input silently. *)
let json_member_or_null = function
  | Some json -> json
  | None -> `Null

let goal_verifier_policy_of_yojson = function
  | `Assoc _ as json -> (
      let* inherit_mode =
        inherit_mode_of_yojson
          (Json_util.assoc_member_opt "inherit_mode" json |> json_member_or_null)
      in
      let* principals =
        match Json_util.assoc_member_opt "principals" json with
        | Some (`List values) -> result_map_list goal_principal_of_yojson values
        | other ->
            Error
              ( "goal_verifier_policy_of_yojson: invalid principals "
              ^ Yojson.Safe.to_string (json_member_or_null other) )
      in
      let+ required_verdicts =
        match Json_util.assoc_member_opt "required_verdicts" json with
        | Some `Null -> Ok None
        | Some (`Int n) -> Ok (Some n)
        | other ->
            Error
              ( "goal_verifier_policy_of_yojson: invalid required_verdicts "
              ^ Yojson.Safe.to_string (json_member_or_null other) )
      in
      { inherit_mode; principals; required_verdicts })
  | json ->
      Error ("goal_verifier_policy_of_yojson: " ^ Yojson.Safe.to_string json)

type vote_decision =
  | Approve
  | Reject

let vote_decision_to_string = function
  | Approve -> "approve"
  | Reject -> "reject"

let vote_decision_of_string = function
  | "approve" -> Some Approve
  | "reject" -> Some Reject
  | _ -> None

let vote_decision_to_yojson decision =
  `String (vote_decision_to_string decision)

let vote_decision_of_yojson = function
  | `String raw -> (
      match String.trim raw |> String.lowercase_ascii |> vote_decision_of_string with
      | Some decision -> Ok decision
      | None -> Error ("vote_decision_of_yojson: " ^ raw))
  | json ->
      Error ("vote_decision_of_yojson: " ^ Yojson.Safe.to_string json)

type request_status =
  | Open
  | Approved
  | Rejected
  | Cancelled

let request_status_to_string = function
  | Open -> "open"
  | Approved -> "approved"
  | Rejected -> "rejected"
  | Cancelled -> "cancelled"

let request_status_to_yojson status =
  `String (request_status_to_string status)

let request_status_of_yojson = function
  | `String raw -> (
      match String.trim raw |> String.lowercase_ascii with
      | "open" -> Ok Open
      | "approved" -> Ok Approved
      | "rejected" -> Ok Rejected
      | "cancelled" -> Ok Cancelled
      | _ -> Error ("request_status_of_yojson: " ^ raw))
  | json ->
      Error ("request_status_of_yojson: " ^ Yojson.Safe.to_string json)

type policy_snapshot = {
  principals : goal_principal list;
  eligible_principals : goal_principal list;
  required_verdicts : int;
}

let policy_snapshot_to_yojson (snapshot : policy_snapshot) =
  `Assoc
    [
      ("principals", `List (List.map goal_principal_to_yojson snapshot.principals));
      ( "eligible_principals",
        `List (List.map goal_principal_to_yojson snapshot.eligible_principals) );
      ("required_verdicts", `Int snapshot.required_verdicts);
    ]

let policy_snapshot_of_yojson = function
  | `Assoc _ as json -> (
      let parse_principal_list field =
        match Json_util.assoc_member_opt field json with
        | Some (`List values) -> result_map_list goal_principal_of_yojson values
        | other ->
            Error
              (Printf.sprintf "policy_snapshot_of_yojson: invalid %s %s" field
                 (Yojson.Safe.to_string (json_member_or_null other)))
      in
      let* principals = parse_principal_list "principals" in
      let* eligible_principals = parse_principal_list "eligible_principals" in
      let+ required_verdicts =
        match Json_util.assoc_member_opt "required_verdicts" json with
        | Some (`Int required_verdicts) -> Ok required_verdicts
        | other ->
            Error
              ( "policy_snapshot_of_yojson: invalid required_verdicts "
              ^ Yojson.Safe.to_string (json_member_or_null other) )
      in
      { principals; eligible_principals; required_verdicts })
  | json ->
      Error ("policy_snapshot_of_yojson: " ^ Yojson.Safe.to_string json)

type goal_verification_vote = {
  principal : goal_principal;
  decision : vote_decision;
  note : string option;
  evidence_refs : string list;
  submitted_at : string;
}

let goal_verification_vote_to_yojson (vote : goal_verification_vote) =
  `Assoc
    [
      ("principal", goal_principal_to_yojson vote.principal);
      ("decision", vote_decision_to_yojson vote.decision);
      ("note", Json_util.string_opt_to_json vote.note);
      ("evidence_refs", `List (List.map (fun value -> `String value) vote.evidence_refs));
      ("submitted_at", `String vote.submitted_at);
    ]

let goal_verification_vote_of_yojson = function
  | `Assoc _ as json -> (
      let* principal =
        goal_principal_of_yojson
          (Json_util.assoc_member_opt "principal" json |> json_member_or_null)
      in
      let* decision =
        vote_decision_of_yojson
          (Json_util.assoc_member_opt "decision" json |> json_member_or_null)
      in
      let* submitted_at =
        match Json_util.assoc_member_opt "submitted_at" json with
        | Some (`String submitted_at) -> Ok submitted_at
        | other ->
            Error
              ( "goal_verification_vote_of_yojson: invalid submitted_at "
              ^ Yojson.Safe.to_string (json_member_or_null other) )
      in
      let* evidence_refs =
        match Json_util.assoc_member_opt "evidence_refs" json with
        | Some `Null -> Ok []
        | Some (`List values) ->
            result_map_list
              (function
                | `String value -> Ok value
                | json ->
                    Error
                      ( "goal_verification_vote_of_yojson: invalid evidence_refs item "
                      ^ Yojson.Safe.to_string json ))
              values
        | other ->
            Error
              ( "goal_verification_vote_of_yojson: invalid evidence_refs "
              ^ Yojson.Safe.to_string (json_member_or_null other) )
      in
      Ok
        {
          principal;
          decision;
          note =
            (match Json_util.assoc_member_opt "note" json with
             | Some (`String s) -> Some s
             | _ -> None);
          evidence_refs;
          submitted_at;
        })
  | json ->
      Error ("goal_verification_vote_of_yojson: " ^ Yojson.Safe.to_string json)

type goal_verification_request = {
  id : string;
  goal_id : string;
  target_phase : Goal_phase.t;
  requested_by : goal_principal;
  policy_snapshot : policy_snapshot;
  votes : goal_verification_vote list;
  status : request_status;
  created_at : string;
  resolved_at : string option;
}

type cancel_request_result =
  | Cancelled_request of goal_verification_request
  | Already_resolved_request of goal_verification_request

let goal_verification_request_to_yojson (request : goal_verification_request) =
  `Assoc
    [
      ("id", `String request.id);
      ("goal_id", `String request.goal_id);
      ("target_phase", Goal_phase.to_yojson request.target_phase);
      ("requested_by", goal_principal_to_yojson request.requested_by);
      ("policy_snapshot", policy_snapshot_to_yojson request.policy_snapshot);
      ("votes", `List (List.map goal_verification_vote_to_yojson request.votes));
      ("status", request_status_to_yojson request.status);
      ("created_at", `String request.created_at);
      ("resolved_at", Json_util.string_opt_to_json request.resolved_at);
    ]

let goal_verification_request_of_yojson = function
  | `Assoc _ as json -> (
      let* target_phase =
        Goal_phase.of_yojson
          (Json_util.assoc_member_opt "target_phase" json |> json_member_or_null)
      in
      let* requested_by =
        goal_principal_of_yojson
          (Json_util.assoc_member_opt "requested_by" json |> json_member_or_null)
      in
      let* policy_snapshot =
        policy_snapshot_of_yojson
          (Json_util.assoc_member_opt "policy_snapshot" json |> json_member_or_null)
      in
      let* status =
        request_status_of_yojson
          (Json_util.assoc_member_opt "status" json |> json_member_or_null)
      in
      let* id, goal_id, created_at =
        match
          ( Json_util.assoc_member_opt "id" json,
            Json_util.assoc_member_opt "goal_id" json,
            Json_util.assoc_member_opt "created_at" json )
        with
        | Some (`String id), Some (`String goal_id), Some (`String created_at) ->
            Ok (id, goal_id, created_at)
        | _ ->
            Error "goal_verification_request_of_yojson: invalid id/goal_id/created_at"
      in
      let* votes =
        match Json_util.assoc_member_opt "votes" json with
        | Some `Null -> Ok []
        | Some (`List rows) -> result_map_list goal_verification_vote_of_yojson rows
        | other ->
            Error
              ( "goal_verification_request_of_yojson: invalid votes "
              ^ Yojson.Safe.to_string (json_member_or_null other) )
      in
      Ok
        {
          id;
          goal_id;
          target_phase;
          requested_by;
          policy_snapshot;
          votes;
          status;
          created_at;
          resolved_at =
            (match Json_util.assoc_member_opt "resolved_at" json with
             | Some (`String s) -> Some s
             | _ -> None);
        })
  | json ->
      Error ("goal_verification_request_of_yojson: " ^ Yojson.Safe.to_string json)

type state = {
  version : int;
  updated_at : string;
  requests : goal_verification_request list;
}

type read_error =
  | Corrupt_state of {
      primary_err : string;
      recovery_err : string option;
    }

let read_error_to_string = function
  | Corrupt_state { primary_err; recovery_err = None } ->
      Printf.sprintf
        "goal verification ledger is present but unparseable (primary: %s); no .last-good recovery file exists"
        primary_err
  | Corrupt_state { primary_err; recovery_err = Some recovery_err } ->
      Printf.sprintf
        "goal verification ledger is present but unparseable (primary: %s; .last-good recovery: %s)"
        primary_err
        recovery_err

exception Corrupt_state_exn of read_error

type goal_policy_node = {
  goal_id : string;
  parent_goal_id : string option;
  verifier_policy : goal_verifier_policy option;
}

let state_to_yojson (state : state) =
  `Assoc
    [
      ("version", `Int state.version);
      ("updated_at", `String state.updated_at);
      ("requests", `List (List.map goal_verification_request_to_yojson state.requests));
    ]

let state_of_yojson = function
  | `Assoc _ as json -> (
      let* version, updated_at, requests_json =
        match
          ( Json_util.assoc_member_opt "version" json,
            Json_util.assoc_member_opt "updated_at" json,
            Json_util.assoc_member_opt "requests" json )
        with
        | Some (`Int version), Some (`String updated_at), Some (`List requests_json) ->
            Ok (version, updated_at, requests_json)
        | _ -> Error "goal_verification_state_of_yojson: invalid state"
      in
      let* requests =
        result_map_list goal_verification_request_of_yojson requests_json
      in
      Ok { version; updated_at; requests })
  | json ->
      Error ("goal_verification_state_of_yojson: " ^ Yojson.Safe.to_string json)

type quorum_result =
  | Pending
  | Passed
  | Failed

let requests_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goal_verifications.json"

let requests_recovery_path config =
  requests_path config ^ ".last-good"

let events_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl"

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); requests = [] }

let read_state_result config =
  let path = requests_path config in
  let read_file file_path =
    match Workspace_utils.read_json_result config file_path with
    | Error msg -> Error msg
    | Ok json -> state_of_yojson json
  in
  if not (Workspace_utils.path_exists config path)
  then Ok (default_state ())
  else
    match read_file path with
    | Ok state -> Ok state
    | Error primary_err ->
        let recovery = requests_recovery_path config in
        if not (Workspace_utils.path_exists config recovery)
        then (
          Log.Misc.error
            "goal_verification: goal_verifications.json corrupt (%s), no .last-good available"
            primary_err;
          Error (Corrupt_state { primary_err; recovery_err = None }))
        else
          match read_file recovery with
          | Ok state ->
              Log.Misc.warn
                "goal_verification: primary goal_verifications.json corrupt (%s), recovered from %s"
                primary_err
                recovery;
              Ok state
          | Error recovery_err ->
              Log.Misc.error
                "goal_verification: both primary and recovery corrupt (primary: %s, recovery: %s)"
                primary_err
                recovery_err;
              Error (Corrupt_state { primary_err; recovery_err = Some recovery_err })
;;

let read_state config =
  match read_state_result config with
  | Ok state -> state
  | Error error -> raise (Corrupt_state_exn error)

let write_state_result config (state : state) =
  let json = state_to_yojson state in
  let* () = Workspace_utils.write_json_result config (requests_path config) json in
  (match Workspace_utils.write_json_result config (requests_recovery_path config) json with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "goal_verification: primary requests committed; recovery mirror write failed for %s: %s"
       (requests_recovery_path config)
       msg);
  Ok ()

let principal_key (principal : goal_principal) =
  principal.id

let principal_equal (left : goal_principal) (right : goal_principal) =
  String.equal left.id right.id

let dedupe_principals principals =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun principal ->
      let key = principal_key principal in
      if Hashtbl.mem seen key then
        false
      else begin
        Hashtbl.add seen key ();
        true
      end)
    principals

let effective_policy_for_nodes ~(goals : goal_policy_node list)
    ~(goal_id : string) =
  let by_id = Hashtbl.create (max 16 (List.length goals)) in
  List.iter (fun (g : goal_policy_node) -> Hashtbl.replace by_id g.goal_id g) goals;
  let rec lineage acc current =
    match current.parent_goal_id with
    | None -> current :: acc
    | Some parent_id -> (
        match Hashtbl.find_opt by_id parent_id with
        | Some parent -> lineage (current :: acc) parent
        | None -> current :: acc)
  in
  match Hashtbl.find_opt by_id goal_id with
  | None -> Error "goal not found while resolving verifier policy"
  | Some goal ->
      let nodes = lineage [] goal in
      let principals = ref [] in
      let required_verdicts = ref None in
      List.iter
        (fun (g : goal_policy_node) ->
          match g.verifier_policy with
          | None -> ()
          | Some policy ->
              let next_principals =
                match policy.inherit_mode with
                | Extend -> !principals @ policy.principals
                | Replace -> policy.principals
              in
              principals := dedupe_principals next_principals;
              (match policy.required_verdicts with
              | Some value -> required_verdicts := Some value
              | None -> ()))
        nodes;
      if !principals = [] then
        Ok None
      else
        match !required_verdicts with
        | None -> Error "effective goal verifier policy is missing required_verdicts"
        | Some required_verdicts when required_verdicts < 1 ->
            Error "required_verdicts must be at least 1"
        | Some required_verdicts when required_verdicts > List.length !principals ->
            Error "required_verdicts cannot exceed effective verifier count"
        | Some required_verdicts ->
            Ok
              (Some
                 {
                   principals = !principals;
                   eligible_principals = !principals;
                   required_verdicts;
                 })

let exclude_requester ~(policy_snapshot : policy_snapshot)
    ~(requested_by : goal_principal) =
  let eligible_principals =
    List.filter
      (fun principal -> not (principal_equal principal requested_by))
      policy_snapshot.eligible_principals
  in
  if policy_snapshot.required_verdicts > List.length eligible_principals then
    Error "requester exclusion makes goal verification quorum impossible"
  else
    Ok { policy_snapshot with eligible_principals }

let emit_event config ~(goal_id : string) ~(event_type : string)
    ~(payload : Yojson.Safe.t) =
  let path = events_path config in
  let event =
    `Assoc
      [
        ("ts", `String (Masc_domain.now_iso ()));
        ("goal_id", `String goal_id);
        ("event_type", `String event_type);
        ("payload", payload);
      ]
  in
  Fs_compat.append_jsonl path event

let update_state config f =
  let lock_path = requests_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let* state =
        read_state_result config
        |> Result.map_error read_error_to_string
      in
      let next_state = f state in
      let* () = write_state_result config next_state in
      Ok next_state)

let gen_request_id () =
  Printf.sprintf "gvr-%d-%04x"
    (int_of_float (Time_compat.now () *. 1000.0))
    (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF)

let create_request config ~(goal_id : string) ~(requested_by : goal_principal)
    ~(policy_snapshot : policy_snapshot) =
  let created_at = Masc_domain.now_iso () in
  let request =
    {
      id = gen_request_id ();
      goal_id;
      target_phase = Goal_phase.Completed;
      requested_by;
      policy_snapshot;
      votes = [];
      status = Open;
      created_at;
      resolved_at = None;
    }
  in
  let state_result =
    update_state config (fun state ->
        {
          version = state.version + 1;
          updated_at = created_at;
          requests = state.requests @ [ request ];
        })
  in
  let* state = state_result in
  let saved = List.find_opt (fun row -> String.equal row.id request.id) state.requests in
  match saved with
  | Some saved -> Ok saved
  | None -> Error "failed to persist goal verification request"

let list_requests_for_goal config ~(goal_id : string) =
  read_state config
  |> fun (state : state) ->
  List.filter
    (fun (request : goal_verification_request) ->
      String.equal request.goal_id goal_id)
    state.requests

let find_request config ~(request_id : string) =
  read_state config |> fun (state : state) ->
  List.find_opt
    (fun (request : goal_verification_request) ->
      String.equal request.id request_id)
    state.requests

let count_votes ~(decision : vote_decision) request =
  List.length
    (List.filter (fun vote -> vote.decision = decision) request.votes)

let remaining_possible_votes request =
  List.length request.policy_snapshot.eligible_principals - List.length request.votes

let evaluate_quorum request =
  let approve_count = count_votes ~decision:Approve request in
  let remaining = remaining_possible_votes request in
  if approve_count >= request.policy_snapshot.required_verdicts then
    Passed
  else if approve_count + remaining < request.policy_snapshot.required_verdicts then
    Failed
  else
    Pending

let cancel_request_if_open config ~(request_id : string) =
  let lock_path = requests_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let* state =
        read_state_result config
        |> Result.map_error read_error_to_string
      in
      match List.find_opt (fun request -> String.equal request.id request_id) state.requests with
      | None -> Error "goal verification request not found"
      | Some request when request.status <> Open -> Ok (Already_resolved_request request)
      | Some request ->
          let resolved_at = Masc_domain.now_iso () in
          let updated_request =
            {
              request with
              status = Cancelled;
              resolved_at = Some resolved_at;
            }
          in
          let requests =
            List.map
              (fun row ->
                if String.equal row.id request_id then updated_request else row)
              state.requests
          in
          let* () =
            write_state_result config
              { version = state.version + 1; updated_at = resolved_at; requests }
          in
          Ok (Cancelled_request updated_request))

let cancel_request config ~(request_id : string) =
  match cancel_request_if_open config ~request_id with
  | Ok (Cancelled_request request | Already_resolved_request request) -> Ok request
  | Error msg -> Error msg

let submit_vote config ~(goal_id : string) ~(request_id : string) ~(principal : goal_principal)
    ~(decision : vote_decision) ?note ?(evidence_refs = []) () =
  let lock_path = requests_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let* state =
        read_state_result config
        |> Result.map_error read_error_to_string
      in
      match List.find_opt (fun request -> String.equal request.id request_id) state.requests with
      | None -> Error "goal verification request not found"
      | Some request when not (String.equal request.goal_id goal_id) ->
          Error "goal verification request does not belong to this goal"
      | Some request when request.status <> Open ->
          Error "goal verification request is not open"
      | Some request when principal_equal principal request.requested_by ->
          Error "requester cannot vote on their own goal verification request"
      | Some request
        when not
               (List.exists
                  (fun eligible -> principal_equal eligible principal)
                  request.policy_snapshot.eligible_principals) ->
          Error "principal is not eligible for this goal verification request"
      | Some request
        when List.exists
               (fun vote -> principal_equal vote.principal principal)
               request.votes ->
          Error "principal has already voted on this request"
      | Some request ->
          let submitted_at = Masc_domain.now_iso () in
          let votes =
            request.votes
            @ [ { principal; decision; note; evidence_refs; submitted_at } ]
          in
          let next_request = { request with votes } in
          let next_request, outcome =
            match evaluate_quorum next_request with
            | Pending -> (next_request, Pending)
            | Passed ->
                ( {
                    next_request with
                    status = Approved;
                    resolved_at = Some submitted_at;
                  },
                  Passed )
            | Failed ->
                ( {
                    next_request with
                    status = Rejected;
                    resolved_at = Some submitted_at;
                  },
                  Failed )
          in
          let requests =
            List.map
              (fun row ->
                if String.equal row.id request_id then next_request else row)
              state.requests
          in
          let* () =
            write_state_result config
              { version = state.version + 1; updated_at = submitted_at; requests }
          in
          Ok (next_request, outcome))
