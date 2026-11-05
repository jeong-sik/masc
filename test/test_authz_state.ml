(* The state that the records of the authorization log add up to. The mode
   events are checked pair by pair, every kind that no layer reads yet is
   refused before and after the bootstrap, and the log that the real
   Fresh_bootstrap writes folds to the workspace it set up. *)

module K = Authz_record.Kind
module L = Authz_log
module M = Authz_mode_event
module Mode = Authz_mode_state
module R = Authz_record
module S = Authz_state

let id_of_string of_string text =
  match of_string text with
  | Ok id -> id
  | Error _ -> Alcotest.failf "fixture id %s rejected by Authz_id" text
;;

let workspace = id_of_string Authz_types.Workspace_id.of_string "workspace-1"
let other_workspace = id_of_string Authz_types.Workspace_id.of_string "workspace-2"
let user = id_of_string Authz_types.User_id.of_string "user-1"
let at_ms = 1_700_000_000_000

let authors =
  [ Authz_records.Author.Authenticated (Authz_types.Principal.Human user)
  ; Authz_records.Author.Local_operator
  ; Authz_records.Author.System_cron
  ; Authz_records.Author.System_maintenance
  ; Authz_records.Author.System_migration
  ]
;;

(* A record of [kind] by the first author that may write it. The chain is not
   checked by [step], so every record starts at the genesis. *)
let record kind body =
  match List.find_opt (fun author -> R.admits kind author) authors with
  | None -> Alcotest.failf "no author may write %s" (K.to_string kind)
  | Some author ->
    (match R.make ~head:R.genesis ~at_ms ~author ~kind ~body with
     | Ok record -> record
     | Error _ -> Alcotest.failf "fixture %s record refused" (K.to_string kind))
;;

let body_of_json json =
  match Authz_body.of_yojson json with
  | Ok body -> body
  | Error error -> Alcotest.failf "fixture body refused: %s" (Authz_body.error_to_string error)
;;

let mode_record event workspace_id =
  match M.to_body { M.event; workspace_id } with
  | Ok body -> record K.Mode_event body
  | Error error -> Alcotest.failf "fixture mode event refused: %s" (Authz_body.error_to_string error)
;;

(* The kinds that no layer reads yet. *)
let other_kinds =
  List.filter (fun kind -> kind <> K.Mode_event && kind <> K.Invite && kind <> K.Admission) K.all

let mode = Alcotest.testable (fun fmt m -> Format.pp_print_string fmt (Mode.to_string m)) Mode.equal

let step_label = function
  | Ok (state : S.t) -> "ok: " ^ Mode.to_string state.S.mode
  | Error refusal -> "refused: " ^ S.refusal_to_string refusal
;;

let step_ok state record =
  match S.step state record with
  | Ok state -> state
  | Error refusal -> Alcotest.failf "the fixture record was refused: %s" (S.refusal_to_string refusal)
;;

let bootstrapped () = step_ok S.empty (mode_record M.Fresh_bootstrap workspace)
let switched_off () = step_ok (bootstrapped ()) (mode_record M.Off workspace)

(* ---- the mode events ---- *)

type expected =
  | Becomes of Mode.t
  | Out_of_order

let states = [ Mode.Not_bootstrapped; Mode.Multi_account workspace; Mode.Off workspace ]

(* Every pair of a state and an event, written out. *)
let pairs =
  [ Mode.Not_bootstrapped, M.Fresh_bootstrap, Becomes (Mode.Multi_account workspace)
  ; Mode.Not_bootstrapped, M.Off, Out_of_order
  ; Mode.Not_bootstrapped, M.Reactivate, Out_of_order
  ; Mode.Multi_account workspace, M.Fresh_bootstrap, Out_of_order
  ; Mode.Multi_account workspace, M.Off, Becomes (Mode.Off workspace)
  ; Mode.Multi_account workspace, M.Reactivate, Out_of_order
  ; Mode.Off workspace, M.Fresh_bootstrap, Out_of_order
  ; Mode.Off workspace, M.Off, Out_of_order
  ; Mode.Off workspace, M.Reactivate, Becomes (Mode.Multi_account workspace)
  ]
;;

let pair_name state event = Printf.sprintf "%s after %s" (M.event_label event) (Mode.to_string state)

let test_every_pair () =
  let sorted names = List.sort String.compare names in
  Alcotest.(check (list string))
    "each state with each event, once"
    (sorted (List.concat_map (fun state -> List.map (pair_name state) M.events) states))
    (sorted (List.map (fun (state, event, _) -> pair_name state event) pairs));
  List.iter
    (fun (state, event, expected) ->
      let name = pair_name state event in
      match Mode.apply state { M.event; workspace_id = workspace }, expected with
      | Ok next, Becomes expected -> Alcotest.check mode name expected next
      | Error (Mode.Out_of_order { state = refused_state; event = refused_event }), Out_of_order ->
        Alcotest.check mode (name ^ ": the state") state refused_state;
        Alcotest.(check string) (name ^ ": the event") (M.event_label event) (M.event_label refused_event)
      | Ok next, Out_of_order -> Alcotest.failf "%s: became %s" name (Mode.to_string next)
      | Error refusal, Becomes _ | Error (Mode.Workspace_differs _ as refusal), Out_of_order ->
        Alcotest.failf "%s: %s" name (Mode.refusal_to_string refusal))
    pairs
;;

let test_workspace_differs () =
  let check name state event =
    match Mode.apply state { M.event; workspace_id = other_workspace } with
    | Error (Mode.Workspace_differs { bootstrapped; named }) ->
      Alcotest.(check string) (name ^ ": bootstrapped") "workspace-1" (Authz_types.Workspace_id.to_string bootstrapped);
      Alcotest.(check string) (name ^ ": named") "workspace-2" (Authz_types.Workspace_id.to_string named)
    | Ok next -> Alcotest.failf "%s: became %s" name (Mode.to_string next)
    | Error refusal -> Alcotest.failf "%s: %s" name (Mode.refusal_to_string refusal)
  in
  check "off" (Mode.Multi_account workspace) M.Off;
  check "reactivate" (Mode.Off workspace) M.Reactivate;
  (* The order is judged before the workspace. *)
  match Mode.apply (Mode.Multi_account workspace) { M.event = M.Reactivate; workspace_id = other_workspace } with
  | Error (Mode.Out_of_order _) -> ()
  | Ok next -> Alcotest.failf "a reactivation while on: became %s" (Mode.to_string next)
  | Error refusal -> Alcotest.failf "a reactivation while on: %s" (Mode.refusal_to_string refusal)
;;

(* A log of mode events adds up event by event: on, off, on and off again. *)
let test_mode_events_in_turn () =
  let events = [ M.Fresh_bootstrap; M.Off; M.Reactivate; M.Off ] in
  let expected =
    [ Mode.Multi_account workspace; Mode.Off workspace; Mode.Multi_account workspace; Mode.Off workspace ]
  in
  ignore
    (List.fold_left2
       (fun state event expected ->
         let next = step_ok state (mode_record event workspace) in
         Alcotest.check mode (M.event_label event) expected next.S.mode;
         next)
       S.empty
       events
       expected
     : S.t)
;;

(* A mode event is an intent of the external store with the same event and
   workspace (design 8.2). *)
let test_mode_events_are_intents () =
  let change =
    Alcotest.testable
      (fun fmt c -> Format.pp_print_string fmt (Authz_external_store.Change.to_string c))
      Authz_external_store.Change.equal
  in
  ignore
    (List.fold_left
       (fun state event ->
         match S.apply state (mode_record event workspace) with
         | Error refusal -> Alcotest.failf "%s refused: %s" (M.event_label event) (S.refusal_to_string refusal)
         | Ok { S.state = next; high_water } ->
           Alcotest.check (Alcotest.option change)
             (M.event_label event)
             (Some (Authz_external_store.Change.Mode { event; workspace_id = workspace }))
             high_water;
           next)
       S.empty
       [ M.Fresh_bootstrap; M.Off; M.Reactivate ]
     : S.t)
;;

(* ---- records ---- *)

let test_bootstrap_record () =
  Alcotest.check mode "the workspace of the bootstrap" (Mode.Multi_account workspace) (bootstrapped ()).S.mode;
  Alcotest.check mode "empty" Mode.Not_bootstrapped S.empty.S.mode
;;

let test_mode_event_out_of_order () =
  match S.step S.empty (mode_record M.Off workspace) with
  | Error (S.Mode (Mode.Out_of_order _)) -> ()
  | other -> Alcotest.failf "expected an out-of-order refusal, got %s" (step_label other)
;;

let test_mode_event_unreadable () =
  let body = body_of_json (`Assoc [ "event", `String "fresh_bootstrap" ]) in
  match S.step S.empty (record K.Mode_event body) with
  | Error (S.Mode_event_unreadable _) -> ()
  | other -> Alcotest.failf "expected an unreadable mode event, got %s" (step_label other)
;;

let test_kinds_not_read () =
  Alcotest.(check bool) "there are other kinds" true (other_kinds <> []);
  let body = body_of_json (`Assoc [ "note", `String "x" ]) in
  let after = [ "on", bootstrapped (); "off", switched_off () ] in
  List.iter
    (fun kind ->
      let name = K.to_string kind in
      (match S.step S.empty (record kind body) with
       | Error (S.Before_bootstrap refused) when refused = kind -> ()
       | other -> Alcotest.failf "%s before the bootstrap: %s" name (step_label other));
      List.iter
        (fun (mode_name, state) ->
          match S.step state (record kind body) with
          | Error (S.Kind_not_read refused) when refused = kind -> ()
          | other -> Alcotest.failf "%s while %s: %s" name mode_name (step_label other))
        after)
    other_kinds
;;

(* ---- invitations ---- *)

module I = Authz_invite_event
module Invites = Authz_invite_state

let invite_id = id_of_string Authz_types.Invite_id.of_string "invite-1"

let invite_record ?(author = Authz_records.Author.Local_operator) ?(role = I.Admin) () =
  let event =
    I.Issued
      { invite_id
      ; token_digest = I.Token_digest.of_token "token-1"
      ; expires_at_ms = at_ms + 1
      ; role
      }
  in
  match I.to_body event with
  | Error error -> Alcotest.failf "fixture invite refused: %s" (Authz_body.error_to_string error)
  | Ok body ->
    (match R.make ~head:R.genesis ~at_ms ~author ~kind:K.Invite ~body with
     | Ok record -> record
     | Error _ -> Alcotest.fail "fixture invite record refused")
;;

let test_an_invitation_after_the_bootstrap () =
  match S.apply (bootstrapped ()) (invite_record ()) with
  | Error refusal -> Alcotest.failf "the invitation was refused: %s" (S.refusal_to_string refusal)
  | Ok { S.state; high_water } ->
    Alcotest.(check bool) "no intent for the store" true (Option.is_none high_water);
    Alcotest.check mode "the mode stays" (Mode.Multi_account workspace) state.S.mode;
    (match Invites.find state.S.invites invite_id with
     | Some { Invites.status = Invites.Open; role = I.Admin; _ } -> ()
     | Some _ | None -> Alcotest.fail "the invitation is not open with the role Admin")
;;

let test_a_revocation_is_an_intent () =
  let revoked =
    match I.to_body (I.Revoked { invite_id }) with
    | Error error -> Alcotest.failf "fixture revocation refused: %s" (Authz_body.error_to_string error)
    | Ok body ->
      (match
         R.make ~head:R.genesis ~at_ms ~author:Authz_records.Author.Local_operator ~kind:K.Invite ~body
       with
       | Ok record -> record
       | Error _ -> Alcotest.fail "fixture revocation record refused")
  in
  match S.apply (step_ok (bootstrapped ()) (invite_record ())) revoked with
  | Error refusal -> Alcotest.failf "the revocation was refused: %s" (S.refusal_to_string refusal)
  | Ok { S.state; high_water } ->
    Alcotest.(check (option string))
      "a revocation of the invitation for the store"
      (Some "revoke of invite:invite-1")
      (Option.map Authz_external_store.Change.to_string high_water);
    (match Invites.find state.S.invites invite_id with
     | Some { Invites.status = Invites.Revoked; _ } -> ()
     | Some _ | None -> Alcotest.fail "the invitation is not revoked")
;;

let test_an_invitation_by_mode () =
  (match S.step S.empty (invite_record ()) with
   | Error (S.Before_bootstrap K.Invite) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match S.step (switched_off ()) (invite_record ()) with
  | Error (S.Accounts_off K.Invite) -> ()
  | other -> Alcotest.failf "while the accounts are off: %s" (step_label other)
;;

let test_an_invitation_that_is_refused () =
  let refused label record expected =
    match S.step (bootstrapped ()) record with
    | Error refusal when expected refusal -> ()
    | other -> Alcotest.failf "%s: %s" label (step_label other)
  in
  refused
    "a member invited by the local operator"
    (invite_record ~role:I.Member ())
    (function
      | S.Invite Invites.Local_operator_invites_only_admins -> true
      | _ -> false);
  refused
    "an invitation by an authenticated principal"
    (invite_record ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Human user)) ())
    (function
      | S.Invite (Invites.Authenticated_author_not_read _) -> true
      | _ -> false);
  let unreadable =
    match R.make ~head:R.genesis ~at_ms ~author:Authz_records.Author.Local_operator ~kind:K.Invite
            ~body:(body_of_json (`Assoc [ "note", `String "x" ])) with
    | Ok record -> record
    | Error _ -> Alcotest.fail "fixture record refused"
  in
  refused "a body that is not an invite record" unreadable (function
    | S.Invite_unreadable _ -> true
    | _ -> false)
;;

(* ---- admissions ---- *)

module Adm = Authz_admission_event
module People = Authz_principal_state
module X = Authz_external_identity

let identity_of sub =
  match X.google ~sub with
  | Ok identity -> identity
  | Error error -> Alcotest.failf "fixture identity refused: %s" (X.error_to_string error)
;;

let bob = id_of_string Authz_types.User_id.of_string "user-2"
let second_invite = id_of_string Authz_types.Invite_id.of_string "invite-2"

let issue_record id token =
  match
    I.to_body
      (I.Issued
         { invite_id = id
         ; token_digest = I.Token_digest.of_token token
         ; expires_at_ms = at_ms + 1000
         ; role = I.Admin
         })
  with
  | Error _ -> Alcotest.fail "fixture invite refused"
  | Ok body ->
    (match R.make ~head:R.genesis ~at_ms ~author:Authz_records.Author.Local_operator ~kind:K.Invite ~body with
     | Ok record -> record
     | Error _ -> Alcotest.fail "fixture invite record refused")
;;

let admission_record ?author ?(at_ms = at_ms) ~user_id ~identity ~invite () =
  let author =
    match author with
    | Some author -> author
    | None -> Authz_records.Author.Authenticated (Authz_types.Principal.Human user_id)
  in
  match Adm.to_body { Adm.user_id; identity; invite_id = invite } with
  | Error _ -> Alcotest.fail "fixture admission refused"
  | Ok body ->
    (match R.make ~head:R.genesis ~at_ms ~author ~kind:K.Admission ~body with
     | Ok record -> record
     | Error _ -> Alcotest.fail "fixture admission record refused")
;;

let invited () =
  step_ok (step_ok (bootstrapped ()) (issue_record invite_id "token-1")) (issue_record second_invite "token-2")
;;

let alice_identity = identity_of "111"

let test_an_admission_through_an_admin_invitation () =
  let change =
    Alcotest.testable
      (fun fmt c -> Format.pp_print_string fmt (Authz_external_store.Change.to_string c))
      Authz_external_store.Change.equal
  in
  match S.apply (invited ()) (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) with
  | Error refusal -> Alcotest.failf "the admission was refused: %s" (S.refusal_to_string refusal)
  | Ok { S.state; high_water } ->
    Alcotest.check (Alcotest.option change) "the role epoch of the new Admin"
      (Some
         (Authz_external_store.Change.Authz
            { event = Authz_external_store.Change.Grant
            ; subject = Authz_records.Subject.Principal (Authz_types.Principal.Human user)
            }))
      high_water;
    (match People.find state.S.principals user with
     | Some { People.status = People.Active; identity } ->
       Alcotest.(check bool) "the identity" true (X.equal identity alice_identity)
     | None -> Alcotest.fail "no principal was made");
    Alcotest.(check bool) "an Admin" true (People.is_admin state.S.principals user);
    Alcotest.(check (option string)) "the identity finds the principal" (Some "user-1")
      (Option.map Authz_types.User_id.to_string (People.find_identity state.S.principals alice_identity));
    (match Invites.find state.S.invites invite_id with
     | Some { Invites.status = Invites.Consumed spent_by; _ } ->
       Alcotest.(check string) "spent by" "user-1" (Authz_types.User_id.to_string spent_by)
     | Some _ | None -> Alcotest.fail "the invitation is not spent")
;;

let test_an_admission_that_is_refused () =
  let admitted = step_ok (invited ()) (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) in
  let refused label state record expected =
    match S.step state record with
    | Error refusal -> Alcotest.(check string) label expected (S.refusal_to_string refusal)
    | Ok _ -> Alcotest.failf "%s: the admission was taken" label
  in
  refused "written by another person" (invited ())
    (admission_record ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Human bob))
       ~user_id:user ~identity:alice_identity ~invite:invite_id ())
    "the principal human:user-2 wrote the admission of user-1, which only that person writes";
  refused "written by a service" (invited ())
    (admission_record
       ~author:(Authz_records.Author.Authenticated
                  (Authz_types.Principal.Service (id_of_string Authz_types.Service_id.of_string "keeper-1")))
       ~user_id:user ~identity:alice_identity ~invite:invite_id ())
    "the principal service:keeper-1 wrote the admission of user-1, which only that person writes";
  refused "an invitation never issued" (bootstrapped ())
    (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ())
    "no invitation invite-1 was issued";
  refused "an invitation at its expiry" (invited ())
    (admission_record ~at_ms:(at_ms + 1000) ~user_id:user ~identity:alice_identity ~invite:invite_id ())
    (Printf.sprintf "the invitation invite-1 expired at %d, and the admission is at %d" (at_ms + 1000)
       (at_ms + 1000));
  refused "an invitation spent before" admitted
    (admission_record ~user_id:bob ~identity:(identity_of "222") ~invite:invite_id ())
    "the invitation invite-1 was spent by an admission before";
  refused "a user id given before" admitted
    (admission_record ~user_id:user ~identity:(identity_of "222") ~invite:second_invite ())
    "the user id user-1 was given before";
  refused "an identity bound before" admitted
    (admission_record ~user_id:bob ~identity:alice_identity ~invite:second_invite ())
    "the identity google:111 is bound to user-1";
  (match
     S.step
       (S.hold_revocations (invited ()) [ Authz_records.Subject.Invite invite_id ])
       (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ())
   with
   | Error (S.Revocation_pending subject) ->
     Alcotest.(check string) "a revocation given up" "invite:invite-1" (Authz_records.Subject.to_string subject)
   | other -> Alcotest.failf "an invitation whose revocation was given up: %s" (step_label other));
  (match S.step S.empty (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) with
   | Error (S.Before_bootstrap K.Admission) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match S.step (step_ok (invited ()) (mode_record M.Off workspace))
          (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) with
  | Error (S.Accounts_off K.Admission) -> ()
  | other -> Alcotest.failf "while the accounts are off: %s" (step_label other)
;;

(* ---- the log of a real bootstrap ---- *)

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o700;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Sys.remove path
;;

(* The zones of the log and the store are [Eio.Mutex]es, so the case runs in an
   event loop. The base path is 0700, which the owner check of the install
   record needs of the config directory it creates next to it. *)
let test_fresh_bootstrap_log () =
  Eio_main.run (fun _env ->
    let root = Filename.temp_dir "authz-state-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree root)
      (fun () ->
        let base_path = Filename.concat root "base" in
        Unix.mkdir base_path 0o700;
        (match
           Authz_bootstrap.fresh_bootstrap
             { Authz_bootstrap.base_path
             ; config_dir = Some (Filename.concat root "config")
             ; external_store = Filename.concat (Filename.concat root "store") "external.jsonl"
             ; workspace_id = workspace
             ; at_ms
             }
         with
         | Ok _ -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
        match L.open_at_start ~path:(L.path_of_base_path ~base_path) ~init:S.empty ~step:S.step with
        | Error error -> Alcotest.failf "the log did not fold: %s" (L.open_error_to_string S.refusal_to_string error)
        | Ok (_log, state, _recovered) ->
          Alcotest.check mode "the workspace of the bootstrap" (Mode.Multi_account workspace) state.S.mode))
;;

let () =
  Alcotest.run
    "authz_state"
    [ ( "mode events"
      , [ Alcotest.test_case "every pair" `Quick test_every_pair
        ; Alcotest.test_case "workspace differs" `Quick test_workspace_differs
        ; Alcotest.test_case "in turn" `Quick test_mode_events_in_turn
        ; Alcotest.test_case "intents of the store" `Quick test_mode_events_are_intents
        ] )
    ; ( "records"
      , [ Alcotest.test_case "bootstrap" `Quick test_bootstrap_record
        ; Alcotest.test_case "mode event out of order" `Quick test_mode_event_out_of_order
        ; Alcotest.test_case "mode event unreadable" `Quick test_mode_event_unreadable
        ; Alcotest.test_case "kinds no layer reads" `Quick test_kinds_not_read
        ] )
    ; ( "invitations"
      , [ Alcotest.test_case "after the bootstrap" `Quick test_an_invitation_after_the_bootstrap
        ; Alcotest.test_case "a revocation is an intent" `Quick test_a_revocation_is_an_intent
        ; Alcotest.test_case "by mode" `Quick test_an_invitation_by_mode
        ; Alcotest.test_case "refused" `Quick test_an_invitation_that_is_refused
        ] )
    ; ( "admissions"
      , [ Alcotest.test_case "through an Admin invitation" `Quick
            test_an_admission_through_an_admin_invitation
        ; Alcotest.test_case "refused" `Quick test_an_admission_that_is_refused
        ] )
    ; "log", [ Alcotest.test_case "of a real bootstrap" `Quick test_fresh_bootstrap_log ]
    ]
;;
