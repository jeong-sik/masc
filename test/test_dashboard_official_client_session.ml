open Alcotest
open Masc
open Keeper_official_client_session_store
open Yojson.Safe.Util

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  Unix.realpath path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let ok = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let claim ~base_path ~keeper_name =
  Keeper_official_client_session_store.claim
    ~base_path
    ~keeper_name
    ~expected:None
    ~client_kind:Antigravity
    ~owner_epoch:(Keeper_official_client_session_store.process_epoch ())
    ~runtime_id:"antigravity.gemini"
    ~tool_surface_sha256:
      (Keeper_official_client_session_store.tool_surface_sha256 [])
    ~updated_at:1.0
  |> ok
;;

let settled_binding ~base_path ~keeper_name =
  let claimed = claim ~base_path ~keeper_name in
  let active =
    mark_active
      ~base_path
      ~keeper_name
      ~expected:claimed
      ~session_id:"conversation-1"
      ~updated_at:2.0
    |> ok
  in
  let inflight =
    mark_turn_starting
      ~base_path
      ~keeper_name
      ~expected:active
      ~session_id:"conversation-1"
      ~updated_at:3.0
    |> ok
  in
  let identified =
    mark_turn_started
      ~base_path
      ~keeper_name
      ~expected:inflight
      ~session_id:"conversation-1"
      ~turn_id:"conversation-1:ordinal:1"
      ~updated_at:4.0
    |> ok
  in
  settle
    ~base_path
    ~keeper_name
    ~expected:identified
    ~session_id:"conversation-1"
    ~turn_id:"conversation-1:ordinal:1"
    ~updated_at:5.0
  |> ok
;;

let recovery_binding ~base_path ~keeper_name =
  let claimed = claim ~base_path ~keeper_name in
  let active =
    mark_active
      ~base_path
      ~keeper_name
      ~expected:claimed
      ~session_id:"conversation-recovery"
      ~updated_at:2.0
    |> ok
  in
  let inflight =
    mark_turn_starting
      ~base_path
      ~keeper_name
      ~expected:active
      ~session_id:"conversation-recovery"
      ~updated_at:3.0
    |> ok
  in
  require_recovery
    ~base_path
    ~keeper_name
    ~expected:inflight
    ~failure:Transport_interrupted
    ~detail:"fixture transport interrupted after init"
    ~required_at:4.0
  |> ok
;;

let test_snapshot_projects_antigravity_evidence () =
  let base_path = temp_workspace "masc-dashboard-official-session-" in
  let keeper_name = "agydashboard" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       ignore (settled_binding ~base_path ~keeper_name);
       let json =
         match
           Server_dashboard_official_client_session.snapshot
             ~base_path
             ~keeper_name
         with
         | Ok json -> json
         | Error error -> fail error.message
       in
       check string
         "schema"
         "masc.dashboard.official-client-session.v1"
         (json |> member "schema" |> to_string);
       let session = json |> member "session" in
       check string "client" "antigravity" (session |> member "client_kind" |> to_string);
       check string
         "logical runtime"
         "antigravity.gemini"
         (session |> member "runtime_id" |> to_string);
       check int "turn count" 1 (session |> member "turn_count" |> to_int);
       let phase = session |> member "phase" in
       check string "phase" "settled" (phase |> member "kind" |> to_string);
       check string
         "conversation"
         "conversation-1"
         (phase |> member "session_id" |> to_string);
       check string
         "provider ordinal"
         "conversation-1:ordinal:1"
         (phase |> member "turn_id" |> to_string))
;;

let test_recovery_resolution_is_exact_and_audited () =
  let base_path = temp_workspace "masc-dashboard-official-recovery-" in
  let keeper_name = "agyrecovery" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       let recovery = recovery_binding ~base_path ~keeper_name in
       let recovery_id =
         match recovery.phase with
         | Recovery_required value -> value.recovery_id
         | _ -> fail "fixture did not enter recovery"
       in
       let body =
         `Assoc
           [ "keeper_name", `String keeper_name
           ; "recovery_id", `String recovery_id
           ; "resolution", `String "restart_fresh"
           ]
         |> Yojson.Safe.to_string
       in
       let json =
         match
           Server_dashboard_official_client_session.resolve_body
             ~base_path
             ~actor:"dashboard-admin"
             ~body
         with
         | Ok json -> json
         | Error error -> fail error.message
       in
       let session = json |> member "session" in
       check string
         "resolved phase"
         "ready"
         (session |> member "phase" |> member "kind" |> to_string);
       let resolution = session |> member "last_recovery_resolution" in
       check string
         "actor"
         "dashboard-admin"
         (resolution |> member "resolved_by" |> to_string);
       check string
         "decision"
         "restart_fresh"
         (resolution |> member "resolution" |> member "kind" |> to_string))
;;

let test_resolution_rejects_extra_fields () =
  match
    Server_dashboard_official_client_session.resolve_body
      ~base_path:"/tmp"
      ~actor:"dashboard-admin"
      ~body:
        {|{"keeper_name":"agydashboard","recovery_id":"recovery","resolution":"restart_fresh","session_id":"unverified"}|}
  with
  | Error { kind = Bad_request; code = "request_fields_invalid"; _ } -> ()
  | Error error -> failf "unexpected error %s" error.code
  | Ok _ -> fail "extra recovery fields were admitted"
;;

let () =
  run
    "Dashboard official-client session"
    [ ( "session evidence"
      , [ test_case
            "projects Antigravity evidence"
            `Quick
            test_snapshot_projects_antigravity_evidence
        ; test_case
            "resolves exact recovery"
            `Quick
            test_recovery_resolution_is_exact_and_audited
        ; test_case
            "rejects extra resolution fields"
            `Quick
            test_resolution_rejects_extra_fields
        ] )
    ]
;;
