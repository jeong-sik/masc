(** Tests for Goal_verification error paths preserving state. *)

open Alcotest
open Masc_mcp

let temp_dir () =
  let path = Filename.temp_file "goal_verification_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_room f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
       let config = Coord.default_config dir in
       ignore (Coord.init config ~agent_name:(Some "test"));
       f config)
;;

let operator ?display_name id : Goal_verification.goal_principal =
  { kind = Goal_verification.Operator; id; display_name }
;;

let keeper ?display_name id : Goal_verification.goal_principal =
  { kind = Goal_verification.Keeper; id; display_name }
;;

let request_snapshot ~requested_by =
  let reviewer = operator "reviewer-1" in
  let verifier = keeper "keeper-a" in
  let principals = [ requested_by; reviewer; verifier ] in
  { Goal_verification.principals
  ; eligible_principals = [ reviewer; verifier ]
  ; required_verdicts = 2
  }
;;

let test_cancel_missing_request_does_not_bump () =
  with_room
  @@ fun config ->
  let before = Goal_verification.read_state config in
  (match Goal_verification.cancel_request config ~request_id:"ghost" with
   | Error _ -> ()
   | Ok _ -> fail "expected missing request error");
  let after = Goal_verification.read_state config in
  check int "version unchanged" before.version after.version;
  check string "updated_at unchanged" before.updated_at after.updated_at
;;

let test_invalid_vote_does_not_bump () =
  with_room
  @@ fun config ->
  let requested_by = operator "planner" in
  let request =
    match
      Goal_verification.create_request
        config
        ~goal_id:"goal-1"
        ~requested_by
        ~policy_snapshot:(request_snapshot ~requested_by)
    with
    | Ok request -> request
    | Error msg -> fail msg
  in
  let before = Goal_verification.read_state config in
  (match
     Goal_verification.submit_vote
       config
       ~request_id:request.id
       ~principal:requested_by
       ~decision:Goal_verification.Approve
       ()
   with
   | Error _ -> ()
   | Ok _ -> fail "expected requester self-vote error");
  let after = Goal_verification.read_state config in
  check int "version unchanged on invalid vote" before.version after.version;
  check string "updated_at unchanged on invalid vote" before.updated_at after.updated_at;
  let saved =
    match Goal_verification.find_request config ~request_id:request.id with
    | Some request -> request
    | None -> fail "request missing after invalid vote"
  in
  check int "no votes written" 0 (List.length saved.votes)
;;

let () =
  run
    "Goal_verification"
    [ ( "state_integrity"
      , [ test_case
            "missing cancel: no bump"
            `Quick
            test_cancel_missing_request_does_not_bump
        ; test_case "invalid vote: no bump" `Quick test_invalid_vote_does_not_bump
        ] )
    ]
;;
