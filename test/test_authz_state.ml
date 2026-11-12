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

(* The replay keeps the state and counts the changes ([S.apply]); these cases read only the state. *)
let step state record = Result.map (fun (applied : S.applied) -> applied.S.state) (S.apply state record)

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
  List.filter
    (fun kind ->
      kind <> K.Mode_event
      && kind <> K.Invite
      && kind <> K.Admission
      && kind <> K.Admin_assignment
      && kind <> K.Principal
      && kind <> K.Revocation_cancel
      && kind <> K.Registration
      && kind <> K.Session
      && kind <> K.Pat
      && kind <> K.Provider_account
      && kind <> K.Runtime
      && kind <> K.Keeper
      && kind <> K.Internal_service_credential)
    K.all

let mode = Alcotest.testable (fun fmt m -> Format.pp_print_string fmt (Mode.to_string m)) Mode.equal

let step_label = function
  | Ok (state : S.t) -> "ok: " ^ Mode.to_string state.S.mode
  | Error refusal -> "refused: " ^ S.refusal_to_string refusal
;;

let step_ok state record =
  match step state record with
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
  match step S.empty (mode_record M.Off workspace) with
  | Error (S.Mode (Mode.Out_of_order _)) -> ()
  | other -> Alcotest.failf "expected an out-of-order refusal, got %s" (step_label other)
;;

let test_mode_event_unreadable () =
  let body = body_of_json (`Assoc [ "event", `String "fresh_bootstrap" ]) in
  match step S.empty (record K.Mode_event body) with
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
      (match step S.empty (record kind body) with
       | Error (S.Before_bootstrap refused) when refused = kind -> ()
       | other -> Alcotest.failf "%s before the bootstrap: %s" name (step_label other));
      List.iter
        (fun (mode_name, state) ->
          match step state (record kind body) with
          | Error (S.Kind_not_read refused) when refused = kind -> ()
          | other -> Alcotest.failf "%s while %s: %s" name mode_name (step_label other))
        after)
    other_kinds
;;

(* ---- invitations ---- *)

module I = Authz_invite_event
module Invites = Authz_invite_state

let invite_id = id_of_string Authz_types.Invite_id.of_string "invite-1"

(* A reduction that the store gave up, named by the record it was for. *)
let intent_for ~aborted change =
  match Authz_record.Hash.of_hex aborted with
  | Some aborted ->
    { Authz_external_store.previous_record_hash = R.Hash.genesis
    ; intended_next_record_digest = aborted
    ; change
    }
  | None -> Alcotest.fail "fixture digest refused"
;;

let held ?(aborted = String.make 64 'a') ?(event = Authz_external_store.Change.Revoke) subject =
  match S.held_of_intent (intent_for ~aborted (Authz_external_store.Change.Authz { event; subject })) with
  | Some held -> held
  | None -> Alcotest.fail "fixture change reduces nothing"
;;

(* Only the intent of a reduction is a block, so every block is one that a
   retry of its change can close. *)
let test_only_a_reduction_is_a_block () =
  let invite = Authz_records.Subject.Invite invite_id in
  let block change = Option.is_some (S.held_of_intent (intent_for ~aborted:(String.make 64 'a') change)) in
  List.iter
    (fun event ->
      Alcotest.(check bool)
        (Authz_external_store.Change.to_string (Authz_external_store.Change.Authz { event; subject = invite }))
        (match event with
         | Authz_external_store.Change.Grant -> false
         | Authz_external_store.Change.Revoke
         | Authz_external_store.Change.Disable
         | Authz_external_store.Change.Delete
         | Authz_external_store.Change.Block
         | Authz_external_store.Change.Purge
         | Authz_external_store.Change.Policy_revoke
         | Authz_external_store.Change.Credential_replace -> true)
        (block (Authz_external_store.Change.Authz { event; subject = invite })))
    Authz_external_store.Change.authz_events;
  Alcotest.(check bool)
    "a mode event"
    false
    (block (Authz_external_store.Change.Mode { event = M.Off; workspace_id = workspace }))
;;

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
  (match step S.empty (invite_record ()) with
   | Error (S.Before_bootstrap K.Invite) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match step (switched_off ()) (invite_record ()) with
  | Error (S.Accounts_off K.Invite) -> ()
  | other -> Alcotest.failf "while the accounts are off: %s" (step_label other)
;;

let test_an_invitation_that_is_refused () =
  let refused label record expected =
    match step (bootstrapped ()) record with
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
      | S.Invite (Invites.Author_is_not_an_admin _) -> true
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
let third_invite = id_of_string Authz_types.Invite_id.of_string "invite-3"

let issue_record ?(at_ms = at_ms) id token =
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

let admission_through_record ?author ?(at_ms = at_ms) ~user_id ~identity through =
  let author =
    match author with
    | Some author -> author
    | None -> Authz_records.Author.Authenticated (Authz_types.Principal.Human user_id)
  in
  let membership =
    { Adm.workspace_id = workspace
    ; account_home_namespace =
        id_of_string Authz_types.Account_home_namespace.of_string ("ns-" ^ Authz_types.User_id.to_string user_id)
    }
  in
  match Adm.to_body { Adm.user_id; identity; through; membership } with
  | Error _ -> Alcotest.fail "fixture admission refused"
  | Ok body ->
    (match R.make ~head:R.genesis ~at_ms ~author ~kind:K.Admission ~body with
     | Ok record -> record
     | Error _ -> Alcotest.fail "fixture admission record refused")
;;

let admission_record ?author ?at_ms ~user_id ~identity ~invite () =
  admission_through_record ?author ?at_ms ~user_id ~identity (Adm.Invite invite)
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
     | Some { People.status = People.Disabled; _ } -> Alcotest.fail "the principal is disabled"
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
    match step state record with
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
     step
       (S.hold_revocations (invited ()) [ held (Authz_records.Subject.Invite invite_id) ])
       (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ())
   with
   | Error (S.Revocation_pending subject) ->
     Alcotest.(check string) "a revocation given up" "invite:invite-1" (Authz_records.Subject.to_string subject)
   | other -> Alcotest.failf "an invitation whose revocation was given up: %s" (step_label other));
  (match step S.empty (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) with
   | Error (S.Before_bootstrap K.Admission) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  refused "an admission before a record already read"
    (step_ok (invited ()) (issue_record ~at_ms:(at_ms + 5) third_invite "token-3"))
    (admission_record ~at_ms:(at_ms + 4) ~user_id:user ~identity:alice_identity ~invite:invite_id ())
    (Printf.sprintf
       "the admission is at %d ms, before a record of the log at %d ms: the clock went back"
       (at_ms + 4)
       (at_ms + 5));
  match step (step_ok (invited ()) (mode_record M.Off workspace))
          (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) with
  | Error (S.Accounts_off K.Admission) -> ()
  | other -> Alcotest.failf "while the accounts are off: %s" (step_label other)
;;

(* Every record moves the latest time, whatever its kind, and only an
   admission is held to it: an [off] from a clock that went back is read. *)
let test_the_latest_time_of_the_log () =
  Alcotest.(check (option int)) "before the first record" None S.empty.S.latest_at_ms;
  let later = step_ok (invited ()) (issue_record ~at_ms:(at_ms + 5) third_invite "token-3") in
  Alcotest.(check (option int)) "after a later invitation" (Some (at_ms + 5)) later.S.latest_at_ms;
  let off = step_ok later (mode_record M.Off workspace) in
  Alcotest.(check (option int)) "an earlier off leaves it" (Some (at_ms + 5)) off.S.latest_at_ms;
  Alcotest.check mode "the off is read" (Mode.Off workspace) off.S.mode
;;

(* ---- Admin assignments ---- *)

module Admin = Authz_admin_event

let admin_record ~by ~user_id =
  match Admin.to_body (Admin.Revoked { user_id; cause = Admin.Operational }) with
  | Error _ -> Alcotest.fail "fixture revocation refused"
  | Ok body ->
    (match
       R.make
         ~head:R.genesis
         ~at_ms
         ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Human by))
         ~kind:K.Admin_assignment
         ~body
     with
     | Ok record -> record
     | Error _ -> Alcotest.fail "fixture revocation record refused")
;;

(* user and bob, both Admins. *)
let two_admins () =
  let state = step_ok (invited ()) (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) in
  step_ok state (admission_record ~user_id:bob ~identity:(identity_of "222") ~invite:second_invite ())
;;

let test_an_admin_revokes_an_admin () =
  match S.apply (two_admins ()) (admin_record ~by:user ~user_id:bob) with
  | Error refusal -> Alcotest.failf "the revocation was refused: %s" (S.refusal_to_string refusal)
  | Ok { S.state; high_water } ->
    Alcotest.(check (option string))
      "the role epoch of bob for the store"
      (Some "revoke of principal:human:user-2")
      (Option.map Authz_external_store.Change.to_string high_water);
    Alcotest.(check bool) "bob is no longer an Admin" false (People.is_admin state.S.principals bob);
    (match step state (admin_record ~by:user ~user_id:user) with
     | Error refusal ->
       Alcotest.(check string)
         "the last Admin"
         "user-1 is the last Admin, so the assignment stays"
         (S.refusal_to_string refusal)
     | Ok _ -> Alcotest.fail "the last Admin was revoked")
;;

(* Each given-up reduction is its own block, so a record that closes one
   leaves another of the same subject (design 8.3); the same reduction read
   twice, at the entry and at the replay, is one block. *)
let test_a_block_is_one_per_given_up_reduction () =
  let invite = Authz_records.Subject.Invite invite_id in
  let first = held invite in
  let second = held ~aborted:(String.make 64 'b') invite in
  let state = S.hold_revocations (invited ()) [ first; first ] in
  Alcotest.(check int) "the same reduction twice" 1 (List.length state.S.revocation_pending);
  let state = S.hold_revocations state [ second ] in
  Alcotest.(check int) "another reduction of the subject" 2 (List.length state.S.revocation_pending);
  let answer subject =
    match S.revocation state subject with
    | Authz_records.Revocation_state.Pending -> "pending"
    | Authz_records.Revocation_state.Not_pending -> "clear"
  in
  Alcotest.(check string) "the held subject" "pending" (answer invite);
  Alcotest.(check string) "another subject" "clear"
    (answer (Authz_records.Subject.Invite (id_of_string Authz_types.Invite_id.of_string "invite-2")))
;;

(* The revocation of an invitation that closes the given blocks. *)
let revoke_record ~closes id =
  match I.to_body (I.Revoked { invite_id = id }) with
  | Error error -> Alcotest.failf "fixture revocation refused: %s" (Authz_body.error_to_string error)
  | Ok body ->
    (match R.make ~head:R.genesis ~at_ms ~author:Authz_records.Author.Local_operator ~kind:K.Invite ~body with
     | Ok record -> R.closing record ~closes:(List.map (fun held -> held.S.aborted) closes)
     | Error _ -> Alcotest.fail "fixture revocation record refused")
;;

let hex_list hashes = List.sort String.compare (List.map R.Hash.to_hex hashes)
let held_digests state = hex_list (List.map (fun held -> held.S.aborted) state.S.revocation_pending)

let revocation_word state subject =
  match S.revocation state subject with
  | Authz_records.Revocation_state.Pending -> "pending"
  | Authz_records.Revocation_state.Not_pending -> "clear"
;;

(* A record that makes a given-up reduction again closes the blocks it names
   (design 8.3). A block it does not name stays, of the same subject or of
   another, and so does its subject. *)
let test_a_retry_closes_the_blocks_it_names () =
  let invite = Authz_records.Subject.Invite invite_id in
  let first = held invite in
  let second = held ~aborted:(String.make 64 'b') invite in
  let other = held ~aborted:(String.make 64 'c') (Authz_records.Subject.Invite second_invite) in
  let state = S.hold_revocations (invited ()) [ first; second; other ] in
  let change event = Authz_external_store.Change.Authz { event; subject = invite } in
  Alcotest.(check (list string))
    "a revocation of invite-1 closes its two blocks"
    (hex_list [ first.S.aborted; second.S.aborted ])
    (hex_list (S.closable state (change Authz_external_store.Change.Revoke)));
  Alcotest.(check (list string))
    "a grant closes nothing"
    []
    (hex_list (S.closable state (change Authz_external_store.Change.Grant)));
  let one = step_ok state (revoke_record ~closes:[ first ] invite_id) in
  Alcotest.(check (list string))
    "closing one leaves the others"
    (hex_list [ second.S.aborted; other.S.aborted ])
    (held_digests one);
  Alcotest.(check string) "invite-1 after one" "pending" (revocation_word one invite);
  let both = step_ok state (revoke_record ~closes:[ first; second ] invite_id) in
  Alcotest.(check (list string)) "closing both" (hex_list [ other.S.aborted ]) (held_digests both);
  Alcotest.(check string) "invite-1 after both" "clear" (revocation_word both invite)
;;

(* A record closes only a block of the change it makes, and only a reduction
   closes one. *)
let test_closes_that_name_no_block_of_the_change_are_refused () =
  let invite = Authz_records.Subject.Invite invite_id in
  let first = held invite in
  let other = held ~aborted:(String.make 64 'c') (Authz_records.Subject.Invite second_invite) in
  let state = S.hold_revocations (invited ()) [ first; other ] in
  let refused label record expected =
    match step state record with
    | Error refusal -> Alcotest.(check string) label expected (S.refusal_to_string refusal)
    | Ok _ -> Alcotest.failf "%s: the record was read" label
  in
  let unknown = held ~aborted:(String.make 64 'd') invite in
  refused
    "a digest that no block has"
    (revoke_record ~closes:[ unknown ] invite_id)
    (S.refusal_to_string (S.Closes_not_held unknown.S.aborted));
  refused
    "the block of another subject"
    (revoke_record ~closes:[ other ] invite_id)
    (S.refusal_to_string (S.Closes_not_held other.S.aborted));
  refused
    "a record that reduces nothing"
    (R.closing (issue_record third_invite "token-3") ~closes:[ first.S.aborted ])
    (S.refusal_to_string S.Closes_without_reduction)
;;

(* The revocation of bob was given up, so bob writes nothing while the block
   stands, and alice is still an Admin. *)
let test_a_principal_whose_revocation_was_given_up_writes_nothing () =
  let held =
    S.hold_revocations
      (two_admins ())
      [ held (Authz_records.Subject.Principal (Authz_types.Principal.Human bob)) ]
  in
  match step held (admin_record ~by:bob ~user_id:user) with
  | Error (S.Revocation_pending subject) ->
    Alcotest.(check string) "the author" "principal:human:user-2" (Authz_records.Subject.to_string subject);
    Alcotest.(check bool) "user is still an Admin" true (People.is_admin held.S.principals user);
    (match step held (admin_record ~by:user ~user_id:user) with
     | Error refusal ->
       Alcotest.(check string)
         "bob does not count as the Admin that remains"
         "user-1 is the last Admin, so the assignment stays"
         (S.refusal_to_string refusal)
     | Ok _ -> Alcotest.fail "the last Admin who can write was revoked")
  | other -> Alcotest.failf "bob wrote while blocked: %s" (step_label other)
;;

let test_an_admin_invites_a_member () =
  let admitted = step_ok (invited ()) (admission_record ~user_id:user ~identity:alice_identity ~invite:invite_id ()) in
  let member_invite =
    match
      I.to_body
        (I.Issued
           { invite_id = id_of_string Authz_types.Invite_id.of_string "invite-3"
           ; token_digest = I.Token_digest.of_token "token-3"
           ; expires_at_ms = at_ms + 1000
           ; role = I.Member
           })
    with
    | Error _ -> Alcotest.fail "fixture invite refused"
    | Ok body ->
      (match
         R.make
           ~head:R.genesis
           ~at_ms
           ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Human user))
           ~kind:K.Invite
           ~body
       with
       | Ok record -> record
       | Error _ -> Alcotest.fail "fixture invite record refused")
  in
  (match step (invited ()) member_invite with
   | Error (S.Invite (Invites.Author_is_not_an_admin _)) -> ()
   | other -> Alcotest.failf "before user is an Admin: %s" (step_label other));
  let state = step_ok admitted member_invite in
  match Invites.find state.S.invites (id_of_string Authz_types.Invite_id.of_string "invite-3") with
  | Some { Invites.status = Invites.Open; role = I.Member; _ } -> ()
  | Some _ | None -> Alcotest.fail "the Member invitation is not open"
;;

let test_an_admin_assignment_by_mode () =
  (match step S.empty (admin_record ~by:user ~user_id:bob) with
   | Error (S.Before_bootstrap K.Admin_assignment) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match step (step_ok (two_admins ()) (mode_record M.Off workspace)) (admin_record ~by:user ~user_id:bob) with
  | Error (S.Accounts_off K.Admin_assignment) -> ()
  | other -> Alcotest.failf "while the accounts are off: %s" (step_label other)
;;

(* ---- principal records ---- *)

module Pe = Authz_principal_event

let principal_record ~by event =
  match Pe.to_body event with
  | Error _ -> Alcotest.fail "fixture principal event refused"
  | Ok body ->
    (match
       R.make
         ~head:R.genesis
         ~at_ms
         ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Human by))
         ~kind:K.Principal
         ~body
     with
     | Ok record -> record
     | Error _ -> Alcotest.fail "fixture principal record refused")
;;

let applied_change label state record expected =
  match S.apply state record with
  | Error refusal -> Alcotest.failf "%s: refused: %s" label (S.refusal_to_string refusal)
  | Ok { S.state; high_water } ->
    Alcotest.(check (option string))
      label
      expected
      (Option.map Authz_external_store.Change.to_string high_water);
    state
;;

let check_inactive label state record =
  match step state record with
  | Error (S.Author_inactive id) ->
    Alcotest.(check string) label "user-2" (Authz_types.User_id.to_string id)
  | other -> Alcotest.failf "%s: %s" label (step_label other)
;;

(* A disable and a deletion are intents on the principal, and an enable has
   none. A disabled or deleted principal writes nothing. *)
let test_a_principal_record () =
  let disabled =
    applied_change
      "a disable"
      (two_admins ())
      (principal_record ~by:user (Pe.Disabled { user_id = bob }))
      (Some "disable of principal:human:user-2")
  in
  check_inactive "bob writes while disabled" disabled (admin_record ~by:bob ~user_id:user);
  (match step disabled (admin_record ~by:user ~user_id:user) with
   | Error refusal ->
     Alcotest.(check string)
       "a disabled Admin does not count as the one that remains"
       "user-1 is the last Admin, so the assignment stays"
       (S.refusal_to_string refusal)
   | Ok _ -> Alcotest.fail "the last Admin that acts was revoked");
  let enabled =
    applied_change
      "an enable"
      disabled
      (principal_record ~by:user (Pe.Enabled { user_id = bob }))
      None
  in
  let deleted =
    applied_change
      "a deletion"
      enabled
      (principal_record ~by:user (Pe.Deleted { user_id = bob; identity = identity_of "222" }))
      (Some "delete of principal:human:user-2")
  in
  check_inactive "bob writes once deleted" deleted (admin_record ~by:bob ~user_id:user);
  Alcotest.(check bool) "the identity is free" true
    (Option.is_none (People.find_identity deleted.S.principals (identity_of "222")))
;;

let test_a_principal_record_by_mode () =
  let disable = principal_record ~by:user (Pe.Disabled { user_id = bob }) in
  (match step S.empty disable with
   | Error (S.Before_bootstrap K.Principal) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match step (step_ok (two_admins ()) (mode_record M.Off workspace)) disable with
  | Error (S.Accounts_off K.Principal) -> ()
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
             ; now_ms = (fun () -> at_ms)
             }
         with
         | Ok _ -> ()
         | Error error -> Alcotest.failf "bootstrap refused: %s" (Authz_bootstrap.error_to_string error));
        match L.open_at_start ~path:(L.path_of_base_path ~base_path) ~init:S.empty ~step:step with
        | Error error -> Alcotest.failf "the log did not fold: %s" (L.open_error_to_string S.refusal_to_string error)
        | Ok (_log, state, _recovered) ->
          Alcotest.check mode "the workspace of the bootstrap" (Mode.Multi_account workspace) state.S.mode))
;;

(* ---- revocation cancels ---- *)

module Cancel = Authz_cancel_event

let human id = Authz_records.Author.Authenticated (Authz_types.Principal.Human id)
let carol = id_of_string Authz_types.User_id.of_string "user-3"
let fourth_invite = id_of_string Authz_types.Invite_id.of_string "invite-4"

let record_by ~author kind body =
  match R.make ~head:R.genesis ~at_ms ~author ~kind ~body with
  | Ok record -> record
  | Error _ -> Alcotest.failf "fixture %s record refused" (K.to_string kind)
;;

let issued_by ~by id token =
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
  | Ok body -> record_by ~author:(human by) K.Invite body
;;

let cancel_named ?(author = human bob) ~aborted subject =
  match Cancel.to_body { Cancel.aborted; subject } with
  | Error _ -> Alcotest.fail "fixture cancel refused"
  | Ok body -> record_by ~author K.Revocation_cancel body
;;

let cancel_record ?author (held : S.held) = cancel_named ?author ~aborted:held.S.aborted held.S.subject

let principal_subject id = Authz_records.Subject.Principal (Authz_types.Principal.Human id)

(* user and bob are Admins through invitations of the local operator. user
   issues invite-3, which carol joins through, and invite-4, which is open. *)
let three_admins () =
  let state = step_ok (two_admins ()) (issued_by ~by:user third_invite "token-3") in
  let state =
    step_ok state (admission_record ~user_id:carol ~identity:(identity_of "333") ~invite:third_invite ())
  in
  step_ok state (issued_by ~by:user fourth_invite "token-4")
;;

let cancel_word state record =
  match S.apply state record with
  | Ok { S.state = (_ : S.t); high_water = None } -> "lifted"
  | Ok { S.state = (_ : S.t); high_water = Some change } ->
    "lifted with an intent: " ^ Authz_external_store.Change.to_string change
  | Error refusal -> S.refusal_to_string refusal
;;

(* An eligible Admin lifts one block (design 8.3), and the store takes no
   intent for it. The reduction stays undone: carol is still an Admin, and the
   invitation is still open. *)
let test_an_eligible_admin_lifts_a_block () =
  let carol_held = held (principal_subject carol) in
  let invite_held = held ~aborted:(String.make 64 'b') (Authz_records.Subject.Invite fourth_invite) in
  let state = S.hold_revocations (three_admins ()) [ carol_held; invite_held ] in
  Alcotest.(check string) "bob lifts the block of carol" "lifted" (cancel_word state (cancel_record carol_held));
  let lifted = step_ok state (cancel_record carol_held) in
  Alcotest.(check (list string)) "the other block stays" (hex_list [ invite_held.S.aborted ]) (held_digests lifted);
  Alcotest.(check string) "carol after it" "clear" (revocation_word lifted (principal_subject carol));
  Alcotest.(check bool) "carol is still an Admin" true (People.is_admin lifted.S.principals carol);
  let both = step_ok lifted (cancel_record invite_held) in
  Alcotest.(check (list string)) "both lifted" [] (held_digests both);
  match Invites.find both.S.invites fourth_invite with
  | Some { Invites.status = Invites.Open; _ } -> ()
  | Some _ | None -> Alcotest.fail "the invitation is not open after its block is lifted"
;;

(* Design 4.1 leaves out the owner of the subject and its original approver:
   the issuer of the invitation that is the subject, and of the one the
   principal joined through. The local operator is neither an Admin nor
   eligible, so an invitation it issued leaves no Admin out. *)
let test_the_issuer_behind_the_subject_does_not_cancel () =
  let carol_held = held (principal_subject carol) in
  let invite_held = held ~aborted:(String.make 64 'b') (Authz_records.Subject.Invite fourth_invite) in
  let bob_held = held ~aborted:(String.make 64 'c') (principal_subject bob) in
  let state = S.hold_revocations (three_admins ()) [ carol_held; invite_held ] in
  let refused subject = S.refusal_to_string (S.Canceller_owns_the_subject subject) in
  Alcotest.(check string)
    "user approved carol"
    (refused (principal_subject carol))
    (cancel_word state (cancel_record ~author:(human user) carol_held));
  Alcotest.(check string)
    "user owns invite-4"
    (refused (Authz_records.Subject.Invite fourth_invite))
    (cancel_word state (cancel_record ~author:(human user) invite_held));
  Alcotest.(check string)
    "carol, blocked herself, does not lift the block of invite-4"
    (S.refusal_to_string (S.Revocation_pending (principal_subject carol)))
    (cancel_word state (cancel_record ~author:(human carol) invite_held));
  Alcotest.(check string)
    "carol lifts it once she is not blocked"
    "lifted"
    (cancel_word
       (S.hold_revocations (three_admins ()) [ invite_held ])
       (cancel_record ~author:(human carol) invite_held));
  let bob_blocked = S.hold_revocations (three_admins ()) [ bob_held ] in
  Alcotest.(check string)
    "user lifts the block of bob, whom the local operator invited"
    "lifted"
    (cancel_word bob_blocked (cancel_record ~author:(human user) bob_held))
;;

let test_a_cancel_that_is_refused () =
  let carol_held = held (principal_subject carol) in
  let bob_held = held ~aborted:(String.make 64 'c') (principal_subject bob) in
  let grant =
    held
      ~aborted:(String.make 64 'e')
      (Authz_records.Subject.Grant (id_of_string Authz_types.Grant_id.of_string "grant-1"))
  in
  let state = S.hold_revocations (three_admins ()) [ carol_held; grant ] in
  let check label expected record = Alcotest.(check string) label expected (cancel_word state record) in
  let not_held = held ~aborted:(String.make 64 'd') (principal_subject carol) in
  check "a digest that no block has" (S.refusal_to_string (S.Cancel_not_held not_held.S.aborted))
    (cancel_record not_held);
  check
    "another subject than the block"
    (S.refusal_to_string
       (S.Cancel_subject_differs
          { aborted = carol_held.S.aborted; named = principal_subject bob; held = principal_subject carol }))
    (cancel_named ~aborted:carol_held.S.aborted (principal_subject bob));
  check
    "a block with no invitation behind it"
    (S.refusal_to_string (S.Cancel_owner_unknown grant.S.subject))
    (cancel_record grant);
  let not_admin author = S.refusal_to_string (S.Canceller_is_not_an_admin author) in
  let stranger = human (id_of_string Authz_types.User_id.of_string "user-9") in
  check "a principal that never joined" (not_admin stranger) (cancel_record ~author:stranger carol_held);
  let service =
    Authz_records.Author.Authenticated
      (Authz_types.Principal.Service (id_of_string Authz_types.Service_id.of_string "keeper-1"))
  in
  check "a service" (not_admin service) (cancel_record ~author:service carol_held);
  let bob_blocked = S.hold_revocations state [ bob_held ] in
  Alcotest.(check string)
    "a blocked Admin"
    (S.refusal_to_string (S.Revocation_pending (principal_subject bob)))
    (cancel_word bob_blocked (cancel_record carol_held));
  Alcotest.(check string)
    "a blocked Admin lifting their own block"
    (S.refusal_to_string (S.Revocation_pending (principal_subject bob)))
    (cancel_word bob_blocked (cancel_record bob_held));
  check
    "a cancel that also closes"
    (S.refusal_to_string S.Closes_without_reduction)
    (R.closing (cancel_record carol_held) ~closes:[ carol_held.S.aborted ]);
  let unreadable = record_by ~author:(human bob) K.Revocation_cancel (body_of_json (`Assoc [])) in
  check "an unreadable body" (S.refusal_to_string (S.Cancel_unreadable Cancel.Wrong_members)) unreadable;
  Alcotest.(check (list string))
    "nothing changed after the refusals"
    (hex_list [ carol_held.S.aborted; grant.S.aborted ])
    (held_digests state)
;;

let test_a_cancel_by_mode () =
  let carol_held = held (principal_subject carol) in
  (match step S.empty (cancel_record carol_held) with
   | Error (S.Before_bootstrap K.Revocation_cancel) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  let off = S.hold_revocations (step_ok (three_admins ()) (mode_record M.Off workspace)) [ carol_held ] in
  match step off (cancel_record carol_held) with
  | Error (S.Accounts_off K.Revocation_cancel) -> ()
  | other -> Alcotest.failf "with the accounts off: %s" (step_label other)
;;

(* What the replay holds before it reads a record: the closes of a retry, and
   the digest that a cancel names. *)
let test_what_a_record_names () =
  let carol_held = held (principal_subject carol) in
  let first = held (Authz_records.Subject.Invite invite_id) in
  Alcotest.(check (list string))
    "a cancel"
    (hex_list [ carol_held.S.aborted ])
    (hex_list (S.closed_by (cancel_record carol_held)));
  Alcotest.(check (list string))
    "a retry"
    (hex_list [ first.S.aborted ])
    (hex_list (S.closed_by (revoke_record ~closes:[ first ] invite_id)));
  Alcotest.(check (list string)) "an issue" [] (hex_list (S.closed_by (issue_record third_invite "token-3")));
  Alcotest.(check (list string))
    "an unreadable cancel"
    []
    (hex_list (S.closed_by (record_by ~author:(human bob) K.Revocation_cancel (body_of_json (`Assoc [])))))
;;

(* ---- the allowlist ---- *)

module Reg = Authz_registration_event
module Regs = Authz_registration_state

let first_registration = id_of_string Authz_types.Registration_id.of_string "registration-1"
let registration_subject = Authz_records.Subject.Registration first_registration
let dana_identity = identity_of "444"

let registration_record ~by event =
  match Reg.to_body event with
  | Error _ -> Alcotest.fail "fixture registration refused"
  | Ok body -> record_by ~author:(human by) K.Registration body
;;

let registered_by ~by identity =
  registration_record ~by (Reg.Registered { registration_id = first_registration; identity })
;;

let removed_by ~by = registration_record ~by (Reg.Removed { registration_id = first_registration })

let intent_word = function
  | Ok { S.high_water = None; state = (_ : S.t) } -> "no intent"
  | Ok { S.high_water = Some change; state = (_ : S.t) } -> Authz_external_store.Change.to_string change
  | Error refusal -> S.refusal_to_string refusal
;;

let open_word state identity =
  match Regs.find_open state.S.registrations identity with
  | None -> "none"
  | Some (id, { Regs.registrar; _ }) ->
    Authz_types.Registration_id.to_string id ^ " by " ^ Authz_types.User_id.to_string registrar
;;

(* A registration raises no epoch and has no intent. Its removal is a [Revoke]
   of the registration, so a log restored from before it disagrees with the
   store (plan C2d). Any Admin removes it. *)
let test_an_admin_registers_and_removes () =
  let state = three_admins () in
  Alcotest.(check string)
    "a registration"
    "no intent"
    (intent_word (S.apply state (registered_by ~by:user dana_identity)));
  let state = step_ok state (registered_by ~by:user dana_identity) in
  Alcotest.(check string) "open" "registration-1 by user-1" (open_word state dana_identity);
  Alcotest.(check string)
    "a removal by another Admin"
    "revoke of registration:registration-1"
    (intent_word (S.apply state (removed_by ~by:bob)));
  let state = step_ok state (removed_by ~by:bob) in
  Alcotest.(check string) "removed" "none" (open_word state dana_identity)
;;

(* The state says who is an Admin and which identities are bound. The identity
   of a deleted principal is free again, so an Admin registers it. *)
let test_a_registration_that_is_refused () =
  let state = three_admins () in
  let stranger = id_of_string Authz_types.User_id.of_string "user-9" in
  Alcotest.(check string)
    "a principal that never joined"
    (S.refusal_to_string
       (S.Registration (Regs.Author_is_not_an_admin (Authz_types.Principal.Human stranger))))
    (intent_word (S.apply state (registered_by ~by:stranger dana_identity)));
  Alcotest.(check string)
    "the identity of user"
    (S.refusal_to_string (S.Registration Regs.Identity_bound))
    (intent_word (S.apply state (registered_by ~by:bob alice_identity)));
  Alcotest.(check string)
    "a removal of nothing"
    (S.refusal_to_string (S.Registration (Regs.Not_registered first_registration)))
    (intent_word (S.apply state (removed_by ~by:bob)));
  Alcotest.(check string)
    "an unreadable body"
    "Registration_unreadable"
    (match S.apply state (record_by ~author:(human bob) K.Registration (body_of_json (`Assoc []))) with
     | Error (S.Registration_unreadable _) -> "Registration_unreadable"
     | other -> step_label (Result.map (fun { S.state; high_water = _ } -> state) other));
  let deleted =
    step_ok state (principal_record ~by:user (Pe.Deleted { user_id = bob; identity = identity_of "222" }))
  in
  Alcotest.(check string)
    "the identity of a deleted principal"
    "no intent"
    (intent_word (S.apply deleted (registered_by ~by:user (identity_of "222"))))
;;

let test_a_registration_by_mode () =
  (match step S.empty (registered_by ~by:user dana_identity) with
   | Error (S.Before_bootstrap K.Registration) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match step (step_ok (three_admins ()) (mode_record M.Off workspace)) (registered_by ~by:user dana_identity) with
  | Error (S.Accounts_off K.Registration) -> ()
  | other -> Alcotest.failf "with the accounts off: %s" (step_label other)
;;

(* A removal whose intent the store gave up blocks the registration (design
   8.3). The Admin who wrote the registration owns it, so another Admin lifts
   the block, and the registration stays open. *)
let test_the_registrar_does_not_cancel_the_block_of_a_removal () =
  let state = step_ok (three_admins ()) (registered_by ~by:user dana_identity) in
  let removal_held = held registration_subject in
  let state = S.hold_revocations state [ removal_held ] in
  Alcotest.(check string) "blocked" "pending" (revocation_word state registration_subject);
  Alcotest.(check string)
    "user wrote it"
    (S.refusal_to_string (S.Canceller_owns_the_subject registration_subject))
    (cancel_word state (cancel_record ~author:(human user) removal_held));
  Alcotest.(check string)
    "bob lifts it"
    "lifted"
    (cancel_word state (cancel_record ~author:(human bob) removal_held));
  let lifted = step_ok state (cancel_record ~author:(human bob) removal_held) in
  Alcotest.(check string) "still open" "registration-1 by user-1" (open_word lifted dana_identity);
  Alcotest.(check string)
    "a block of a registration never written"
    (S.refusal_to_string (S.Cancel_owner_unknown registration_subject))
    (cancel_word
       (S.hold_revocations (three_admins ()) [ removal_held ])
       (cancel_record ~author:(human bob) removal_held))
;;

let erin = id_of_string Authz_types.User_id.of_string "user-5"

let registration_admission ~user_id identity =
  admission_through_record ~user_id ~identity (Adm.Registration first_registration)
;;

(* A registered identity joins as a Member through its entry, and the store
   takes a [Grant] on the principal, as for every admission. The Admin who wrote
   the entry is the original approver of the person (design 4.1), so that Admin
   does not lift a block of them. *)
let test_an_admission_through_a_registration () =
  let state = step_ok (three_admins ()) (registered_by ~by:user dana_identity) in
  Alcotest.(check string)
    "the admission"
    "grant of principal:human:user-5"
    (intent_word (S.apply state (registration_admission ~user_id:erin dana_identity)));
  let state = step_ok state (registration_admission ~user_id:erin dana_identity) in
  Alcotest.(check bool) "a Member" false (People.is_admin state.S.principals erin);
  Alcotest.(check string) "the entry is spent" "none" (open_word state dana_identity);
  Alcotest.(check string)
    "a second admission through it"
    (S.refusal_to_string
       (S.Admission (People.Registration (Regs.Registration_consumed first_registration))))
    (intent_word (S.apply state (registration_admission ~user_id:carol (identity_of "555"))));
  let erin_held = held ~aborted:(String.make 64 'f') (principal_subject erin) in
  let blocked = S.hold_revocations state [ erin_held ] in
  Alcotest.(check string)
    "user wrote the entry erin came through"
    (S.refusal_to_string (S.Canceller_owns_the_subject (principal_subject erin)))
    (cancel_word blocked (cancel_record ~author:(human user) erin_held));
  Alcotest.(check string)
    "bob lifts it"
    "lifted"
    (cancel_word blocked (cancel_record ~author:(human bob) erin_held))
;;

(* A removal whose intent the store gave up holds the entry, so no admission
   spends it (design 8.3). *)
let test_a_held_removal_keeps_the_entry_out () =
  let state = step_ok (three_admins ()) (registered_by ~by:user dana_identity) in
  let blocked = S.hold_revocations state [ held registration_subject ] in
  Alcotest.(check string)
    "the admission"
    (S.refusal_to_string (S.Revocation_pending registration_subject))
    (intent_word (S.apply blocked (registration_admission ~user_id:erin dana_identity)))
;;

(* An invitation admission spends the open entry of the identity, so the
   person does not come back through it once deleted. *)
let test_an_invitation_admission_spends_the_entry () =
  let state = step_ok (three_admins ()) (registered_by ~by:user dana_identity) in
  let state =
    step_ok state (admission_record ~user_id:erin ~identity:dana_identity ~invite:fourth_invite ())
  in
  Alcotest.(check string) "the entry is spent" "none" (open_word state dana_identity);
  match Regs.find state.S.registrations first_registration with
  | Some { Regs.status = Regs.Consumed by; _ } ->
    Alcotest.(check string) "spent by" "user-5" (Authz_types.User_id.to_string by)
  | Some _ | None -> Alcotest.fail "the entry is not spent by the invitation admission"
;;

(* ---- browser sessions ---- *)

module Se = Authz_session_event
module Sessions = Authz_session_state

let session_of text = id_of_string Authz_types.Session_id.of_string text
let first_session = session_of "session-1"
let second_session = session_of "session-2"

let session_record ?(closes = []) ~by event =
  match Se.to_body event with
  | Error _ -> Alcotest.fail "fixture session body refused"
  | Ok body ->
    R.closing (record_by ~author:(human by) K.Session body) ~closes:(List.map (fun held -> held.S.aborted) closes)
;;

let issued ?replaces ~by session_id =
  Se.Issued { session_id; user_id = by; secret_digest = Se.Secret_digest.of_secret "secret"; replaces }
;;

let session_status state session_id =
  match Sessions.find state.S.sessions session_id with
  | None -> "none"
  | Some { Sessions.status = Sessions.Open; user_id; _ } -> "open for " ^ Authz_types.User_id.to_string user_id
  | Some { Sessions.status = Sessions.Revoked; _ } -> "revoked"
  | Some { Sessions.status = Sessions.Replaced by; _ } -> "replaced by " ^ Authz_types.Session_id.to_string by
;;

(* A sign-in that ends nothing takes no intent. A sign-in that ends the session
   its browser held, and a sign-out, are Revoke intents on the session they
   end (design 8.1 and 8.2). *)
let test_sessions_and_their_intents () =
  let signed_in =
    applied_change "a sign-in" (two_admins ()) (session_record ~by:user (issued ~by:user first_session)) None
  in
  Alcotest.(check string) "the session" "open for user-1" (session_status signed_in first_session);
  let acts_at now_ms =
    match Sessions.find_active signed_in.S.sessions first_session ~now_ms with
    | Ok (_ : Sessions.session) -> "acts"
    | Error Sessions.Expired -> "expired"
    | Error (Sessions.Unknown | Sessions.Ended) -> "not open"
  in
  Alcotest.(check string) "the last moment of its 7 days" "acts" (acts_at (at_ms + Sessions.lifetime_ms - 1));
  Alcotest.(check string) "7 days after its record" "expired" (acts_at (at_ms + Sessions.lifetime_ms));
  let again =
    applied_change
      "the same browser signs in as bob"
      signed_in
      (session_record ~by:bob (issued ~by:bob ~replaces:first_session second_session))
      (Some "revoke of session:session-1")
  in
  Alcotest.(check string) "the old one" "replaced by session-2" (session_status again first_session);
  Alcotest.(check string) "the new one" "open for user-2" (session_status again second_session);
  let out =
    applied_change
      "a sign-out"
      again
      (session_record ~by:bob (Se.Revoked { session_id = second_session }))
      (Some "revoke of session:session-2")
  in
  Alcotest.(check string) "signed out" "revoked" (session_status out second_session)
;;

let step_word state record =
  match step state record with
  | Ok (_ : S.t) -> "taken"
  | Error refusal -> S.refusal_to_string refusal
;;

let test_a_session_record_that_is_refused () =
  let state = step_ok (two_admins ()) (session_record ~by:user (issued ~by:user first_session)) in
  List.iter
    (fun (label, record, expected) -> Alcotest.(check string) label (S.refusal_to_string expected) (step_word state record))
    [ ( "an unreadable body"
      , record_by ~author:(human user) K.Session (body_of_json (`Assoc []))
      , S.Session_unreadable Se.Wrong_members )
    ; ( "a sign-out of another's session"
      , session_record ~by:bob (Se.Revoked { session_id = first_session })
      , S.Session (Sessions.Not_the_owner { session_id = first_session; author = bob }) )
    ; ( "a person who never joined"
      , session_record ~by:carol (issued ~by:carol second_session)
      , S.Session (Sessions.User_not_active carol) )
    ; ( "the id again"
      , session_record ~by:bob (issued ~by:bob first_session)
      , S.Session (Sessions.Already_issued first_session) )
    ];
  let disabled = step_ok state (principal_record ~by:bob (Pe.Disabled { user_id = user })) in
  match step disabled (session_record ~by:user (Se.Revoked { session_id = first_session })) with
  | Error (S.Author_inactive id) ->
    Alcotest.(check string) "a disabled principal writes no session record" "user-1" (Authz_types.User_id.to_string id)
  | other -> Alcotest.failf "a disabled principal: %s" (step_label other)
;;

let test_a_session_record_by_mode () =
  let record = session_record ~by:user (issued ~by:user first_session) in
  (match step S.empty record with
   | Error (S.Before_bootstrap K.Session) -> ()
   | other -> Alcotest.failf "before the bootstrap: %s" (step_label other));
  match step (step_ok (two_admins ()) (mode_record M.Off workspace)) record with
  | Error (S.Accounts_off K.Session) -> ()
  | other -> Alcotest.failf "while the accounts are off: %s" (step_label other)
;;

(* A session whose revocation the store gave up stays blocked: no Admin cancels
   the block, and a sign-out by its owner or a new sign-in of its browser
   closes it. *)
let test_a_blocked_session () =
  let state = step_ok (two_admins ()) (session_record ~by:user (issued ~by:user first_session)) in
  let subject = Authz_records.Subject.Session first_session in
  let blocked = held subject in
  let state = S.hold_revocations state [ blocked ] in
  Alcotest.(check string) "blocked" "pending" (revocation_word state subject);
  Alcotest.(check string)
    "an Admin does not cancel it"
    (S.refusal_to_string (S.Cancel_owner_unknown subject))
    (cancel_word state (cancel_record blocked));
  let out = step_ok state (session_record ~closes:[ blocked ] ~by:user (Se.Revoked { session_id = first_session })) in
  Alcotest.(check string) "a sign-out closes it" "clear" (revocation_word out subject);
  Alcotest.(check string) "and ends the session" "revoked" (session_status out first_session);
  let again =
    step_ok state (session_record ~closes:[ blocked ] ~by:bob (issued ~by:bob ~replaces:first_session second_session))
  in
  Alcotest.(check string) "a new sign-in closes it" "clear" (revocation_word again subject);
  Alcotest.(check string) "and ends the session" "replaced by session-2" (session_status again first_session)
;;

(* ---- PATs and Service credentials ---- *)

module Pa = Authz_pat_event
module Pats = Authz_pat_state
module Sc = Authz_service_credential_event
module Scs = Authz_service_credential_state

let first_pat = id_of_string Authz_types.Pat_id.of_string "pat-1"
let second_pat = id_of_string Authz_types.Pat_id.of_string "pat-2"
let first_credential = id_of_string Authz_types.Service_credential_id.of_string "cred-1"
let keeper_service = id_of_string Authz_types.Service_id.of_string "keeper-runner"

let digest_of of_hex =
  match of_hex (String.make 64 'a') with
  | Some digest -> digest
  | None -> Alcotest.fail "fixture digest refused"
;;

let pat_record ~author event =
  match Pa.to_body event with
  | Error _ -> Alcotest.fail "fixture PAT body refused"
  | Ok body -> record_by ~author K.Pat body
;;

let pat_issued ?expires_at_ms ~by pat_id =
  Pa.Issued
    { pat_id
    ; user_id = by
    ; secret_digest = digest_of Authz_credential_token.Pat.Digest.of_hex
    ; scope = Authz_types.Authorization_scope.all
    ; expires_at_ms
    }
;;

let credential_record event =
  match Sc.to_body event with
  | Error _ -> Alcotest.fail "fixture Service credential body refused"
  | Ok body -> record_by ~author:Authz_records.Author.Local_operator K.Internal_service_credential body
;;

let refused_as label state record expected =
  Alcotest.(check string) label (S.refusal_to_string expected) (step_word state record)
;;

(* Plan C4-4: another's PAT is not revoked, a PAT is not revoked twice, it
   expires at its expiry, and its revocation is a Revoke intent. *)
let test_pats_and_their_intents () =
  let issued =
    applied_change
      "a PAT"
      (two_admins ())
      (pat_record ~author:(human user) (pat_issued ~expires_at_ms:(at_ms + 1000) ~by:user first_pat))
      None
  in
  let acts_at state now_ms =
    match Pats.find_active state.S.pats first_pat ~now_ms with
    | Ok (_ : Pats.pat) -> "acts"
    | Error Pats.Expired -> "expired"
    | Error Pats.Ended -> "revoked"
    | Error Pats.Unknown -> "unknown"
  in
  Alcotest.(check string) "before its expiry" "acts" (acts_at issued (at_ms + 999));
  Alcotest.(check string) "at its expiry" "expired" (acts_at issued (at_ms + 1000));
  refused_as
    "another's PAT"
    issued
    (pat_record ~author:(human bob) (Pa.Revoked { pat_id = first_pat }))
    (S.Pat (Pats.Not_the_owner { pat_id = first_pat; author = bob }));
  refused_as
    "a PAT for another"
    issued
    (pat_record ~author:(human bob) (pat_issued ~by:user second_pat))
    (S.Pat (Pats.Issued_for_another { author = bob; user_id = user }));
  refused_as
    "a service"
    issued
    (pat_record
       ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Service keeper_service))
       (pat_issued ~by:user second_pat))
    (S.Pat (Pats.Not_a_human (Authz_types.Principal.Service keeper_service)));
  let revoked =
    applied_change
      "its revoke"
      issued
      (pat_record ~author:(human user) (Pa.Revoked { pat_id = first_pat }))
      (Some "revoke of pat:pat-1")
  in
  Alcotest.(check string) "revoked" "revoked" (acts_at revoked at_ms);
  refused_as
    "revoked twice"
    revoked
    (pat_record ~author:(human user) (Pa.Revoked { pat_id = first_pat }))
    (S.Pat (Pats.Already_revoked first_pat))
;;

(* The local operator issues and revokes a Service credential; its revocation
   is a Revoke intent. *)
let test_service_credentials_and_their_intents () =
  let issued =
    applied_change
      "a credential"
      (two_admins ())
      (credential_record
         (Sc.Issued
            { credential_id = first_credential
            ; service_id = keeper_service
            ; secret_digest = digest_of Authz_credential_token.Service_credential.Digest.of_hex
            }))
      None
  in
  let acts state =
    match Scs.find_active state.S.service_credentials first_credential with
    | Ok (_ : Scs.credential) -> "acts"
    | Error Scs.Ended -> "revoked"
    | Error Scs.Unknown -> "unknown"
  in
  Alcotest.(check string) "issued" "acts" (acts issued);
  let revoked =
    applied_change
      "its revoke"
      issued
      (credential_record (Sc.Revoked { credential_id = first_credential }))
      (Some "revoke of service_credential:cred-1")
  in
  Alcotest.(check string) "revoked" "revoked" (acts revoked);
  refused_as
    "revoked twice"
    revoked
    (credential_record (Sc.Revoked { credential_id = first_credential }))
    (S.Service_credential (Scs.Already_revoked first_credential));
  match step S.empty (credential_record (Sc.Revoked { credential_id = first_credential })) with
  | Error (S.Before_bootstrap K.Internal_service_credential) -> ()
  | other -> Alcotest.failf "before the bootstrap: %s" (step_label other)
;;

(* ---- provider accounts ---- *)

module Pae = Authz_provider_account_event
module Pas = Authz_provider_account_state

let first_account = id_of_string Authz_types.Provider_account_id.of_string "claude-code-user"

let account_record ~author event =
  match Pae.to_body event with
  | Error _ -> Alcotest.fail "fixture provider account body refused"
  | Ok body -> record_by ~author K.Provider_account body
;;

let linked ~by = Pae.Linked { provider_account_id = first_account; user_id = by }

(* Plan D1-1: a person links an account for themselves once, takes no intent,
   and links none for another, an Admin included. *)
let test_provider_accounts () =
  let state =
    applied_change "a link" (two_admins ()) (account_record ~author:(human user) (linked ~by:user)) None
  in
  Alcotest.(check (option string))
    "its owner"
    (Some (Authz_types.User_id.to_string user))
    (Option.map Authz_types.User_id.to_string (Pas.owner state.S.provider_accounts first_account));
  refused_as
    "linked twice"
    state
    (account_record ~author:(human user) (linked ~by:user))
    (S.Provider_account (Pas.Already_linked first_account));
  refused_as
    "an Admin links one for another"
    (two_admins ())
    (account_record ~author:(human bob) (linked ~by:user))
    (S.Provider_account (Pas.Linked_for_another { author = bob; user_id = user }));
  refused_as
    "a service"
    (two_admins ())
    (account_record
       ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Service keeper_service))
       (linked ~by:user))
    (S.Provider_account (Pas.Not_a_human (Authz_types.Principal.Service keeper_service)))
;;

(* ---- Runtimes ---- *)

module Re = Authz_runtime_event
module Rs = Authz_runtime_state

let first_runtime = id_of_string Authz_types.Runtime_id.of_string "claude-code-user.claude-sonnet-5-5"
let second_runtime = id_of_string Authz_types.Runtime_id.of_string "claude-code-user.claude-opus-5-5"
let first_grant = id_of_string Authz_types.Grant_id.of_string "grant-1"
let second_grant = id_of_string Authz_types.Grant_id.of_string "grant-2"

let runtime_record ~author event =
  match Re.to_body event with
  | Error _ -> Alcotest.fail "fixture Runtime body refused"
  | Ok body -> record_by ~author K.Runtime body
;;

let fixture_self_effects = Authz_types.Effect.(Set.of_list [ Invoke_model; Use_tool ])

let made ?(runtime_id = first_runtime) ?(grant_id = first_grant) ~by () =
  Re.Made
    { runtime_id
    ; provider_account_id = first_account
    ; user_id = by
    ; grant_id
    ; self_effects = fixture_self_effects
    }
;;

(* Plan D1: a person makes a Runtime on an account they own, with its Self
   grant, once; an Admin makes none for another person, nor on the account of
   another person, and a grant id names one grant. *)
let test_runtimes () =
  let linked_state =
    applied_change "a link" (two_admins ()) (account_record ~author:(human user) (linked ~by:user)) None
  in
  refused_as
    "on an account no one linked"
    (two_admins ())
    (runtime_record ~author:(human user) (made ~by:user ()))
    (S.Runtime (Rs.Account_not_theirs { provider_account_id = first_account; user_id = user }));
  let state =
    applied_change "a Runtime" linked_state (runtime_record ~author:(human user) (made ~by:user ())) None
  in
  Alcotest.(check (list (pair string string)))
    "its owner owns it with its Self grant"
    [ Authz_types.Runtime_id.to_string first_runtime, Authz_types.Grant_id.to_string first_grant ]
    (List.map
       (fun (id, (runtime : Rs.runtime)) ->
         ( Authz_types.Runtime_id.to_string id
         , Authz_types.Grant_id.to_string runtime.Rs.self_grant ))
       (Rs.owned_by state.S.runtimes user));
  Alcotest.(check (list string))
    "its Self grant keeps the effects the record names"
    [ "invoke_model"; "use_tool" ]
    (List.concat_map
       (fun (_, (runtime : Rs.runtime)) ->
         List.map Authz_types.Effect.to_string (Authz_types.Effect.Set.elements runtime.Rs.self_effects))
       (Rs.owned_by state.S.runtimes user));
  Alcotest.(check int) "another person owns none" 0 (List.length (Rs.owned_by state.S.runtimes bob));
  refused_as
    "made twice"
    state
    (runtime_record ~author:(human user) (made ~grant_id:second_grant ~by:user ()))
    (S.Runtime (Rs.Already_made first_runtime));
  refused_as
    "a grant named twice"
    state
    (runtime_record ~author:(human user) (made ~runtime_id:second_runtime ~by:user ()))
    (S.Runtime (Rs.Grant_named_before first_grant));
  refused_as
    "an Admin makes one for another"
    linked_state
    (runtime_record ~author:(human bob) (made ~by:user ()))
    (S.Runtime (Rs.Made_for_another { author = bob; user_id = user }));
  refused_as
    "an Admin makes one on the account of another"
    linked_state
    (runtime_record ~author:(human bob) (made ~by:bob ()))
    (S.Runtime (Rs.Account_not_theirs { provider_account_id = first_account; user_id = bob }));
  refused_as
    "a service"
    linked_state
    (runtime_record
       ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Service keeper_service))
       (made ~by:user ()))
    (S.Runtime (Rs.Not_a_human (Authz_types.Principal.Service keeper_service)))
;;

(* ---- Keepers ---- *)

module Ke = Authz_keeper_event
module Ks = Authz_keeper_state

let first_keeper = id_of_string Authz_types.Keeper_id.of_string "keeper-1"
let second_keeper = id_of_string Authz_types.Keeper_id.of_string "keeper-2"
let second_account = id_of_string Authz_types.Provider_account_id.of_string "claude-code-bob"
let bob_runtime = id_of_string Authz_types.Runtime_id.of_string "claude-code-bob.claude-sonnet-5-5"

(* No admission names this id. *)
let stranger = id_of_string Authz_types.User_id.of_string "user-9"

let keeper_record ~author event =
  match Ke.to_body event with
  | Error _ -> Alcotest.fail "fixture Keeper body refused"
  | Ok body -> record_by ~author K.Keeper body
;;

let first_policy = id_of_string Authz_types.Policy_id.of_string "policy-1"
let second_policy = id_of_string Authz_types.Policy_id.of_string "policy-2"

let fixture_turn_scope =
  { Authz_types.Authorization_scope.runtimes = Authz_types.Runtime_scope.all
  ; channels =
      Authz_types.Channel_scope.only
        (Authz_types.Channel.Set.of_list Authz_types.Channel.[ Autonomous; Direct ])
  ; allowed_effects = Authz_types.Effect_scope.all
  }
;;

let keeper_made ?(keeper_id = first_keeper) ?(policy_id = first_policy) ~by () =
  Ke.Made { keeper_id; user_id = by; policy_id; turn_scope = fixture_turn_scope }
;;

let assigned ?(keeper_id = first_keeper) runtime_id = Ke.Assigned { keeper_id; runtime_id }

let owned_keepers state user_id =
  List.map
    (fun (keeper_id, (keeper : Ks.keeper)) ->
      ( Authz_types.Keeper_id.to_string keeper_id
      , Option.map Authz_types.Runtime_id.to_string keeper.Ks.runtime ))
    (Authz_keeper.owned state user_id)
;;

(* Plan D1-5: a person makes a Keeper for themselves, once, and gives it only
   a Runtime they own. A Keeper name is a person's own (issue #51073): another
   person makes a Keeper of the same name, and it is another Keeper. Both
   people here are Admins: an Admin makes no Keeper for another person, gives
   no Runtime to the Keeper of another person, and gives their own Keeper no
   Runtime of another person. *)
let test_keepers () =
  let state =
    applied_change "a Keeper" (two_admins ()) (keeper_record ~author:(human user) (keeper_made ~by:user ())) None
  in
  Alcotest.(check (list (pair string (option string))))
    "its owner owns it, with no Runtime yet"
    [ Authz_types.Keeper_id.to_string first_keeper, None ]
    (owned_keepers state user);
  Alcotest.(check int) "another person owns none" 0 (List.length (Authz_keeper.owned state bob));
  (match Ke.to_body (keeper_made ~by:user ()) with
   | Error _ -> Alcotest.fail "the made body was not built"
   | Ok body ->
     Alcotest.(check string)
       "the made body on disk"
       ({|{"event":"made","keeper_id":"|}
        ^ Authz_types.Keeper_id.to_string first_keeper
        ^ {|","user_id":"|}
        ^ Authz_types.User_id.to_string user
        ^ {|","policy_id":"policy-1","turn_scope":{"runtimes":"all","channels":["autonomous","direct"],"allowed_effects":"all"}}|})
       (Authz_body.to_string body));
  Alcotest.(check bool)
    "the name is no Keeper of another person"
    true
    (Option.is_none (Ks.find state.S.keepers ~owner:bob first_keeper));
  (match Ks.find state.S.keepers ~owner:user first_keeper with
   | None -> Alcotest.fail "the Keeper is not in the state"
   | Some keeper ->
     Alcotest.(check string)
       "its policy id"
       "policy-1"
       (Authz_types.Policy_id.to_string keeper.Ks.policy_id);
     Alcotest.(check bool)
       "its turn scope"
       true
       (Authz_types.Authorization_scope.equal fixture_turn_scope keeper.Ks.turn_scope));
  refused_as
    "made twice"
    state
    (keeper_record ~author:(human user) (keeper_made ~policy_id:second_policy ~by:user ()))
    (S.Keeper (Ks.Already_made first_keeper));
  refused_as
    "a policy id another Keeper named"
    state
    (keeper_record ~author:(human user) (keeper_made ~keeper_id:second_keeper ~by:user ()))
    (S.Keeper (Ks.Policy_named_before first_policy));
  let both =
    applied_change
      "a Keeper of the same name by another person"
      state
      (keeper_record ~author:(human bob) (keeper_made ~policy_id:second_policy ~by:bob ()))
      None
  in
  Alcotest.(check (list (pair string (option string))))
    "the other person owns their Keeper of that name"
    [ Authz_types.Keeper_id.to_string first_keeper, None ]
    (owned_keepers both bob);
  Alcotest.(check (list (pair string (option string))))
    "and the first person still owns theirs"
    [ Authz_types.Keeper_id.to_string first_keeper, None ]
    (owned_keepers both user);
  (match Ks.find both.S.keepers ~owner:bob first_keeper with
   | None -> Alcotest.fail "the other person's Keeper is not in the state"
   | Some keeper ->
     Alcotest.(check string)
       "with its own policy"
       (Authz_types.Policy_id.to_string second_policy)
       (Authz_types.Policy_id.to_string keeper.Ks.policy_id));
  refused_as
    "an Admin makes one for another"
    (two_admins ())
    (keeper_record ~author:(human bob) (keeper_made ~by:user ()))
    (S.Keeper (Ks.Made_for_another { author = bob; user_id = user }));
  refused_as
    "a person who never joined"
    (two_admins ())
    (keeper_record ~author:(human stranger) (keeper_made ~by:stranger ()))
    (S.Keeper (Ks.User_not_active stranger));
  refused_as
    "a service"
    (two_admins ())
    (keeper_record
       ~author:(Authz_records.Author.Authenticated (Authz_types.Principal.Service keeper_service))
       (keeper_made ~by:user ()))
    (S.Keeper (Ks.Not_a_human (Authz_types.Principal.Service keeper_service)));
  refused_as
    "a Runtime for a Keeper no record made"
    (two_admins ())
    (keeper_record ~author:(human user) (assigned first_runtime))
    (S.Keeper (Ks.Not_made first_keeper));
  refused_as
    "a Runtime no record made"
    state
    (keeper_record ~author:(human user) (assigned first_runtime))
    (S.Keeper (Ks.Runtime_not_made first_runtime));
  let state =
    List.fold_left
      (fun state (label, record) -> applied_change label state record None)
      state
      [ "a link", account_record ~author:(human user) (linked ~by:user)
      ; "a Runtime", runtime_record ~author:(human user) (made ~by:user ())
      ; ( "a link of the Admin"
        , account_record
            ~author:(human bob)
            (Pae.Linked { provider_account_id = second_account; user_id = bob }) )
      ; ( "a Runtime of the Admin"
        , runtime_record
            ~author:(human bob)
            (Re.Made
               { runtime_id = bob_runtime
               ; provider_account_id = second_account
               ; user_id = bob
               ; grant_id = second_grant
               ; self_effects = fixture_self_effects
               }) )
      ; ( "a Keeper of the Admin"
        , keeper_record
            ~author:(human bob)
            (keeper_made ~keeper_id:second_keeper ~policy_id:second_policy ~by:bob ()) )
      ]
  in
  refused_as
    "a Runtime of another Admin"
    state
    (keeper_record ~author:(human user) (assigned bob_runtime))
    (S.Keeper
       (Ks.Not_the_owners_runtime
          { keeper_id = first_keeper; runtime_id = bob_runtime; runtime_owner = bob }));
  refused_as
    "the other way round"
    state
    (keeper_record ~author:(human bob) (assigned ~keeper_id:second_keeper first_runtime))
    (S.Keeper
       (Ks.Not_the_owners_runtime
          { keeper_id = second_keeper; runtime_id = first_runtime; runtime_owner = user }));
  refused_as
    "an Admin gives a Runtime to the Keeper of another"
    state
    (keeper_record ~author:(human bob) (assigned bob_runtime))
    (S.Keeper (Ks.Not_made first_keeper));
  let state =
    applied_change
      "a Runtime of the owner"
      state
      (keeper_record ~author:(human user) (assigned first_runtime))
      None
  in
  Alcotest.(check (list (pair string (option string))))
    "its turns run on that Runtime"
    [ ( Authz_types.Keeper_id.to_string first_keeper
      , Some (Authz_types.Runtime_id.to_string first_runtime) )
    ]
    (owned_keepers state user)
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
        ; Alcotest.test_case "the latest time of the log" `Quick test_the_latest_time_of_the_log
        ] )
    ; ( "admin assignments"
      , [ Alcotest.test_case "an Admin revokes an Admin" `Quick test_an_admin_revokes_an_admin
        ; Alcotest.test_case "a blocked principal writes nothing" `Quick
            test_a_principal_whose_revocation_was_given_up_writes_nothing
        ; Alcotest.test_case "one block per given-up reduction" `Quick
            test_a_block_is_one_per_given_up_reduction
        ; Alcotest.test_case "only a reduction is a block" `Quick test_only_a_reduction_is_a_block
        ; Alcotest.test_case "a retry closes the blocks it names" `Quick
            test_a_retry_closes_the_blocks_it_names
        ; Alcotest.test_case "closes that name no block of the change" `Quick
            test_closes_that_name_no_block_of_the_change_are_refused
        ; Alcotest.test_case "an Admin invites a Member" `Quick test_an_admin_invites_a_member
        ; Alcotest.test_case "by mode" `Quick test_an_admin_assignment_by_mode
        ] )
    ; ( "revocation cancels"
      , [ Alcotest.test_case "an eligible Admin" `Quick test_an_eligible_admin_lifts_a_block
        ; Alcotest.test_case "the issuer behind the subject" `Quick
            test_the_issuer_behind_the_subject_does_not_cancel
        ; Alcotest.test_case "refused" `Quick test_a_cancel_that_is_refused
        ; Alcotest.test_case "by mode" `Quick test_a_cancel_by_mode
        ; Alcotest.test_case "what a record names" `Quick test_what_a_record_names
        ] )
    ; ( "allowlist"
      , [ Alcotest.test_case "register and remove" `Quick test_an_admin_registers_and_removes
        ; Alcotest.test_case "refused" `Quick test_a_registration_that_is_refused
        ; Alcotest.test_case "by mode" `Quick test_a_registration_by_mode
        ; Alcotest.test_case "the registrar behind a block" `Quick
            test_the_registrar_does_not_cancel_the_block_of_a_removal
        ; Alcotest.test_case "an admission through an entry" `Quick
            test_an_admission_through_a_registration
        ; Alcotest.test_case "a held removal" `Quick test_a_held_removal_keeps_the_entry_out
        ; Alcotest.test_case "an invitation spends the entry" `Quick
            test_an_invitation_admission_spends_the_entry
        ] )
    ; ( "principal records"
      , [ Alcotest.test_case "disable, enable, delete" `Quick test_a_principal_record
        ; Alcotest.test_case "by mode" `Quick test_a_principal_record_by_mode
        ] )
    ; ( "sessions"
      , [ Alcotest.test_case "and their intents" `Quick test_sessions_and_their_intents
        ; Alcotest.test_case "refused" `Quick test_a_session_record_that_is_refused
        ; Alcotest.test_case "by mode" `Quick test_a_session_record_by_mode
        ; Alcotest.test_case "blocked" `Quick test_a_blocked_session
        ] )
    ; ( "credentials"
      , [ Alcotest.test_case "PATs and their intents" `Quick test_pats_and_their_intents
        ; Alcotest.test_case
            "Service credentials and their intents"
            `Quick
            test_service_credentials_and_their_intents
        ] )
    ; "provider accounts", [ Alcotest.test_case "linked by their owner" `Quick test_provider_accounts ]
    ; "runtimes", [ Alcotest.test_case "made by their owner on their account" `Quick test_runtimes ]
    ; "keepers", [ Alcotest.test_case "made by their owner, given their Runtimes" `Quick test_keepers ]
    ; "log", [ Alcotest.test_case "of a real bootstrap" `Quick test_fresh_bootstrap_log ]
    ]
;;
