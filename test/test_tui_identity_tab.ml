(** The Identity tab's numbering.

    The screen prints a number beside each provider and a keypress acts on
    that number. Both read [identity_connectable], and this is what says so:
    if one side ever filters differently the numbers stop naming what they
    appear to name, and an operator attaches the wrong Keeper to the wrong
    service. *)

let check = Alcotest.check

let contains needle text =
  let n = String.length needle and len = String.length text in
  let rec seek i =
    i + n <= len && (String.equal (String.sub text i n) needle || seek (i + 1))
  in
  n = 0 || seek 0

let declared ?tools ?(also_on = []) ?enabled ?switch_problem id label =
  Masc_tui_identity_model.Identity_declared
    { idp_id = id
    ; idp_label = label
    ; idp_tools = tools
    ; idp_also_on = also_on
    ; idp_enabled = enabled
    ; idp_switch_problem = switch_problem
    }

let unreadable id problem =
  Masc_tui_identity_model.Identity_unreadable { idp_id = id; idp_problem = problem }

let ids providers =
  List.map fst (Masc_tui_identity_model.identity_connectable providers)

let test_a_broken_declaration_does_not_take_a_number () =
  (* It is still shown -- an operator has to see why the provider they came
     for is missing -- but pressing 2 has to reach the second one that can
     actually be connected, not the broken one sitting between them. *)
  let providers =
    [ declared "atlassian" "Atlassian";
      unreadable "jira" "id does not match the file name";
      declared "slack" "Slack" ]
  in
  check (Alcotest.list Alcotest.string) "only what can be connected"
    [ "atlassian"; "slack" ] (ids providers)

let test_the_order_is_the_declared_order () =
  let providers = [ declared "b" "B"; declared "a" "A" ] in
  check (Alcotest.list Alcotest.string) "not re-sorted behind the screen's back"
    [ "b"; "a" ] (ids providers)

let test_nothing_connectable_is_not_an_error () =
  let providers = [ unreadable "jira" "unreadable" ] in
  check (Alcotest.list Alcotest.string) "no numbers to press" [] (ids providers)

(* ── when the tick stops asking ──────────────────────────────────────── *)

let login ~provider =
  {
    Masc_tui_identity_model.ils_keeper = "attaching-fixture";
    ils_provider = provider;
    ils_label = "Whatever The Screen Calls It";
    ils_url = "https://auth.example.com/authorize?x=1";
    ils_expires_at = 100.;
    ils_attempt_id = "attempt-slack";
  }

let test_a_login_lands_when_its_service_reports_tools () =
  let providers = [ declared ~tools:[ "getJiraIssue" ] "atlassian" "Atlassian" ] in
  check Alcotest.bool "landed" true
    (Masc_tui_identity_model.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let test_attached_with_no_tools_still_counts_as_landed () =
  (* A service can be attached and offer nothing. The login did happen, and
     a tick that kept asking would ask forever. *)
  let providers = [ declared ~tools:[] "atlassian" "Atlassian" ] in
  check Alcotest.bool "landed" true
    (Masc_tui_identity_model.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let test_not_attached_has_not_landed () =
  let providers = [ declared "atlassian" "Atlassian" ] in
  check Alcotest.bool "still waiting" false
    (Masc_tui_identity_model.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let test_another_service_landing_does_not_end_this_login () =
  (* Matched by id, not by the label a screen shows: a declaration is free
     to change what it is called. *)
  let providers =
    [ declared ~tools:[ "sendMessage" ] "slack" "Whatever The Screen Calls It" ]
  in
  check Alcotest.bool "this login is still outstanding" false
    (Masc_tui_identity_model.identity_login_landed ~providers
       ~login:(login ~provider:"atlassian"))

let pending_login ?(expires_at = 100.) ~keeper ~provider ~url () =
  { (login ~provider) with ils_keeper = keeper; ils_url = url; ils_expires_at = expires_at }

let pending_urls state keeper =
  Masc_tui_types.identity_logins_for_keeper state keeper
  |> List.map (fun login -> login.Masc_tui_identity_model.ils_url)

let identity_state () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935
    ~refresh_interval:2.0 ()

module Decode = Masc.Tui_decode

(* A [server_identity] carrying only what workspace equality reads, built
   through the real decoder path so a field rename here is a compile error
   instead of a silently-empty comparison. *)
let workspace_identity ~base_path ~masc_root : Decode.server_identity =
  Decode.decode_server_identity
    (`Assoc
      [ ("build", `Assoc [ ("version", `String "test") ])
      ; ( "paths"
        , `Assoc
            [ ("effective_base_path", `String base_path)
            ; ("effective_masc_root", `String masc_root) ] )
      ])
  |> function
  | Ok identity -> identity
  | Error detail -> failwith ("test fixture: " ^ detail)

let hold_expectation state ~keeper ~provider ~base_path ~masc_root =
  Masc_tui_types.remember_identity_login_expectation state
    { Masc_tui_types.ile_origin = workspace_identity ~base_path ~masc_root
    ; Masc_tui_types.ile_keeper = keeper
    ; Masc_tui_types.ile_provider = provider
    ; Masc_tui_types.ile_attempt_id = "attempt-" ^ provider }

let held_expectations state keeper =
  Masc_tui_types.identity_expectations_for_keeper state keeper
  |> List.map (fun expectation -> expectation.Masc_tui_types.ile_provider)

let complete_attempt state keeper provider =
  match List.find_opt (fun held -> held.Masc_tui_types.ile_provider=provider)
      (Masc_tui_types.identity_expectations_for_keeper state keeper) with
  | None -> Alcotest.fail "expected live completion handle"
  | Some expectation ->
      let read = Masc_tui_types.mark_detail_read_started state
        ~tab:Masc_tui_types.Detail_identity ~keeper ~now_ns:10L in
      Masc_tui_identity_updates.providers_loaded state read
        ~attempts:[expectation, Ok (Masc_tui_identity_model.Credentials_published (Ok 0))]
        (Ok (Masc_tui_types.identity_expectations_for_keeper state keeper
          |> List.map (fun held -> declared ~tools:[] held.Masc_tui_types.ile_provider held.ile_provider)))

let test_withdrawal_retires_the_display_but_keeps_the_wait () =
  let state = identity_state () in
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A/consent" ());
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  Masc_tui_types.withdraw_identity_readings state;
  check (Alcotest.list Alcotest.string) "consent display is withdrawn" []
    (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "the login is still owed" [ "slack" ]
    (held_expectations state "A")

let test_only_its_own_workspace_reopens_the_poll () =
  let state = identity_state () in
  let admitted = workspace_identity ~base_path:"/w/a" ~masc_root:"/r" in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  state.server_identity <- Some (workspace_identity ~base_path:"/w/next" ~masc_root:"/r");
  check Alcotest.bool "a different workspace does not reopen the poll" false
    (Masc_tui_types.identity_expectation_workspace_matches ~origin:admitted state);
  state.server_identity <- Some admitted;
  check Alcotest.bool "the same workspace returning does" true
    (Masc_tui_types.identity_expectation_workspace_matches ~origin:admitted state);
  state.server_identity <- None;
  check Alcotest.bool "an unread workspace polls nothing" false
    (Masc_tui_types.identity_expectation_workspace_matches ~origin:admitted state)

(* The tick asks after every Keeper a login waits on, wherever the operator
   is: consent happens in a browser, and the Identity tab of one Keeper is
   rarely what is on screen when it lands. *)
let test_every_waiting_keeper_is_polled_from_any_surface () =
  let state = identity_state () in
  let pending () = Masc_tui_types.identity_login_pending_keepers state ~now:10. in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  state.view <- Masc_tui_types.Overview;
  hold_expectation state ~keeper:"B" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"A" ~provider:"atlassian" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"C" ~provider:"slack" ~base_path:"/w/other"
    ~masc_root:"/r";
  check (Alcotest.list Alcotest.string)
    "each waiting Keeper once, this workspace only" [ "A"; "B" ] (pending ());
  Masc_tui_types.retire_identity_logins state ~keeper_name:"B"
    ~providers:[declared ~tools:[ "sendMessage" ] "slack" "Slack"];
  complete_attempt state "B" "slack";
  check (Alcotest.list Alcotest.string) "a completed login stops being polled"
    [ "A" ] (pending ());
  state.server_identity <- None;
  check (Alcotest.list Alcotest.string) "an unread workspace polls nobody" []
    (pending ())

(* A provider removed while consent was pending never attaches. Its absence
   from the inventory is the answer; a declared or unreadable one may still
   finish. *)
let test_a_removed_provider_ends_the_wait () =
  let state = identity_state () in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"A" ~provider:"atlassian" ~base_path:"/w/a"
    ~masc_root:"/r";
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[declared "atlassian" "Atlassian"];
  check (Alcotest.list Alcotest.string)
    "the absent provider retires, the declared one still waits" [ "atlassian" ]
    (held_expectations state "A");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[unreadable "atlassian" "read failed"];
  check (Alcotest.list Alcotest.string) "an unreadable declaration still waits"
    [ "atlassian" ] (held_expectations state "A");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A" ~providers:[];
  check (Alcotest.list Alcotest.string) "gone from the inventory, the wait ends"
    [] (held_expectations state "A")

let login_result ?(expires_at = 100.) () =
  Masc_tui_identity_model.Login_started
    { provider_id = "slack"; label = "Slack"; url = "https://auth/new"; expires_at; attempt_id = "attempt-slack" }

let apply_login state request ~now result =
  Masc_tui_identity_updates.login_started state request ~now
    ~report:(fun _ _ -> ()) ~notice:(fun ~keeper_name:_ _ -> ()) result

let test_login_wire_preserves_the_server_deadline () =
  let decode json = Masc_tui_identity_model.decode_identity_login
    ~provider_id:"slack" ~label:"Slack" ~now:10. json in
  let response deadline = `Assoc
    [ "authorize_url", `String "https://auth/slack";
      "provider", `String "slack"; "expires_at", deadline; "attempt_id", `String "attempt-slack" ] in
  List.iter (fun deadline ->
    match decode (response deadline) with
    | Masc_tui_identity_model.Login_started { expires_at; _ } ->
        check (Alcotest.float 0.) "server deadline is retained exactly" 42. expires_at
    | _ -> Alcotest.fail "valid server deadline was rejected") [`Float 42.; `Int 42];
  List.iter (fun json ->
    check Alcotest.bool "invalid or expired consent cannot begin a wait" true
      (match decode json with Masc_tui_identity_model.Login_failed _ -> true | _ -> false))
    [ `Assoc ["authorize_url", `String "https://auth/slack"];
      response `Null; response (`String "42"); response (`Float nan);
      response (`Float infinity); response (`Float neg_infinity);
      response (`Float 10.); response (`Int 9); `Null; `List []; `Bool true ];
  check Alcotest.bool "CLI attachment needs no consent deadline" true
    (match decode (`Assoc ["attached", `Bool true]) with
     | Masc_tui_identity_model.Login_attached _ -> true | _ -> false)

let test_removed_provider_retires_display_and_late_start () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"B" ~provider:"slack" ~url:"https://auth/B" ());
  let pending = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  let read = Masc_tui_types.mark_detail_read_started state
    ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:1L in
  Masc_tui_identity_updates.providers_loaded state read ~attempts:[]
    (Ok []);
  apply_login state pending ~now:10. (login_result ());
  check (Alcotest.list Alcotest.string) "removed provider cannot restore its URL" []
    (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "removed provider cannot restore its poll" []
    (held_expectations state "A");
  check (Alcotest.list Alcotest.string) "other Keeper's consent survives" ["https://auth/B"]
    (pending_urls state "B")

let test_deleted_keeper_retires_only_after_a_complete_roster () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  List.iter (fun keeper -> Masc_tui_types.remember_identity_login state
    (pending_login ~keeper ~provider:"slack" ~url:("https://auth/" ^ keeper) ())) ["A"; "B"];
  let request = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  let start_only = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"C" ~provider_id:"slack" in
  Masc_tui_types.reconcile_identity_login_keepers state ~keeper_names:[]
    ~error:(Some "roster unavailable");
  check (Alcotest.list Alcotest.string) "failed roster keeps every wait" ["A"; "B"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:10.);
  Masc_tui_types.reconcile_identity_login_keepers state ~keeper_names:["B"] ~error:None;
  apply_login state request ~now:10. (login_result ());
  apply_login state start_only ~now:10. (login_result ());
  check (Alcotest.list Alcotest.string) "deleted Keeper's URL retires" [] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "a late first response cannot resurrect deletion" []
    (pending_urls state "C");
  check (Alcotest.list Alcotest.string) "only the surviving Keeper is polled" ["B"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:10.)

let test_expiry_stops_polling_and_retires_consent () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  Masc_tui_types.remember_identity_login state
    (pending_login ~expires_at:20. ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"B" ~provider:"slack" ~url:"https://auth/B" ());
  check (Alcotest.list Alcotest.string) "before server deadline, both waits are live" ["A"; "B"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:19.);
  check (Alcotest.list Alcotest.string) "deadline keeps both exact completion reads" ["A";"B"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:20.);
  check Alcotest.bool "expiry requests a redraw for the retired URL" true
    (Masc_tui_types.expire_identity_logins state ~now:20.);
  check (Alcotest.list Alcotest.string) "expired URL is removed" [] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "expired URL retains exact completion expectation" ["slack"] (held_expectations state "A");
  check (Alcotest.list Alcotest.string) "unexpired URL remains" ["https://auth/B"]
    (pending_urls state "B");
  check Alcotest.bool "a later tick does not repaint the same expiry" false
    (Masc_tui_types.expire_identity_logins state ~now:20.)

let test_admitted_callback_outlives_consent_deadline () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  state.keepers <- [{ Decode.k_origin=Decode.Persisted_keeper; k_name="A"; k_paused=false;
    k_identity=Ok {k_trace_id="trace-A";k_created_at="2026-09-01T00:00:00Z";k_updated_at="2026-09-05T12:00:00Z"};k_activity=None }];
  state.keeper_cursor <- 0;
  Masc_tui_types.remember_identity_login state
    (pending_login ~expires_at:20. ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  let expectation = List.hd (Masc_tui_types.identity_expectations_for_keeper state "A") in
  let apply json =
    let read = Masc_tui_types.mark_detail_read_started state
      ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:10L in
    Masc_tui_identity_updates.providers_loaded state read
      ~attempts:[expectation, Masc_tui_identity_model.decode_identity_login_status json]
      (Ok [declared "slack" "Slack"]) in
  apply (`Assoc ["kind", `String "callback_admitted"]);
  ignore (Masc_tui_types.expire_identity_logins state ~now:21.);
  check (Alcotest.list Alcotest.string) "expired URL cannot be reopened" [] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "admitted callback stays observable" ["A"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:21.);
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[declared ~tools:[] "slack" "Slack"];
  check (Alcotest.list Alcotest.string) "catalog does not elect completion" ["slack"] (held_expectations state "A");
  apply (`Assoc ["kind", `String "completed"; "credential_publication", `String "published";
    "tool_discovery", `Assoc ["kind", `String "failed"]]);
  check (Alcotest.list Alcotest.string) "actual completion ends polling" [] (held_expectations state "A");
  check Alcotest.bool "credential success remains distinct from discovery failure" true
    (match state.identity_attempt_error with
     | Some (_, detail) -> contains "credentials attached" detail | None -> false)

let test_a_lost_attempt_is_read_against_the_catalog () =
  let setup () =
    let state = identity_state () in
    state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
    state.keepers <- [{ Decode.k_origin=Decode.Persisted_keeper; k_name="A"; k_paused=false;
      k_identity=Ok {k_trace_id="trace-A";k_created_at="2026-09-01T00:00:00Z";k_updated_at="2026-09-05T12:00:00Z"};k_activity=None }];
    state.keeper_cursor <- 0;
    Masc_tui_types.remember_identity_login state
      (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
    let expectation = List.hd (Masc_tui_types.identity_expectations_for_keeper state "A") in
    let apply catalog =
      let read = Masc_tui_types.mark_detail_read_started state
        ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:10L in
      Masc_tui_identity_updates.providers_loaded state read
        ~attempts:[expectation, Ok Masc_tui_identity_model.Attempt_unavailable] catalog in
    state, apply in
  let notice state = match state.Masc_tui_types.identity_attempt_error with
    | Some (_, detail) -> detail | None -> "" in
  (* A server restart loses the attempt table. Attachment alone cannot say
     this attempt attached the provider: an attached provider can be logged
     into again. *)
  let state, apply = setup () in
  apply (Error "catalog unavailable");
  check (Alcotest.list Alcotest.string) "an unreadable catalog keeps the wait"
    ["slack"] (held_expectations state "A");
  apply (Ok [declared ~tools:[] "slack" "Slack"]);
  check (Alcotest.list Alcotest.string) "a lost attempt ends the wait"
    [] (held_expectations state "A");
  check Alcotest.bool "an attached provider is named without claiming this login" true
    (contains "possibly from an earlier login" (notice state));
  check Alcotest.bool "and is not a reason to log in again" false
    (contains "start a new login" (notice state));
  let state, apply = setup () in
  apply (Ok [declared "slack" "Slack"]);
  check (Alcotest.list Alcotest.string) "a lost attempt ends the wait when detached"
    [] (held_expectations state "A");
  check Alcotest.bool "a detached provider asks for a new login" true
    (contains "start a new login" (notice state))

let test_completed_attempt_requires_current_owned_catalog () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  let expectation = List.hd (Masc_tui_types.identity_expectations_for_keeper state "A") in
  let completed = Masc_tui_identity_model.decode_identity_login_status
    (`Assoc ["kind", `String "completed"; "credential_publication", `String "published";
      "tool_discovery", `Assoc ["kind", `String "discovered"; "count", `Int 0]]) in
  let start ns = Masc_tui_types.mark_detail_read_started state
    ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:ns in
  let apply read providers = Masc_tui_identity_updates.providers_loaded state read
    ~attempts:[expectation,completed] providers in
  let stale = start 1L in
  let current = start 2L in
  apply stale (Ok [declared ~tools:[] "slack" "Slack"]);
  check (Alcotest.list Alcotest.string) "rejected stale catalog cannot consume completion"
    ["slack"] (held_expectations state "A");
  apply current (Error "catalog unavailable");
  check (Alcotest.list Alcotest.string) "failed current catalog retains completion read"
    ["slack"] (held_expectations state "A");
  apply (start 3L) (Ok [declared ~tools:[] "slack" "Slack"]);
  check (Alcotest.list Alcotest.string) "current post-status catalog completes attempt"
    [] (held_expectations state "A");
  Masc_tui_types.remember_identity_login state
    { (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/new" ())
      with ils_attempt_id="attempt-replacement" };
  let replacement = List.hd (Masc_tui_types.identity_expectations_for_keeper state "A") in
  apply (start 4L) (Ok [declared ~tools:[] "slack" "Slack"]);
  check (Alcotest.list Alcotest.string) "old attempt cannot retire replacement under current read"
    ["slack"] (held_expectations state "A");
  let read = start 5L in
  Masc_tui_identity_updates.providers_loaded state read
    ~attempts:[replacement,Ok Masc_tui_identity_model.Consent_expired]
    (Error "catalog unavailable");
  check (Alcotest.list Alcotest.string) "immutable consent expiry needs no catalog"
    [] (held_expectations state "A")

let test_expiry_survives_authority_loss_without_resurrection () =
  let state = identity_state () in
  let origin = workspace_identity ~base_path:"/w/a" ~masc_root:"/r" in
  state.server_identity <- Some origin;
  Masc_tui_types.remember_identity_login state
    (pending_login ~expires_at:20. ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  Masc_tui_types.withdraw_identity_readings state;
  state.server_identity <- None;
  ignore (Masc_tui_types.expire_identity_logins state ~now:20.);
  state.server_identity <- Some origin;
  check (Alcotest.list Alcotest.string) "recovery resumes completion read after URL deadline" ["A"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:21.)

let test_previous_expiry_preserves_a_replacement_request () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  Masc_tui_types.remember_identity_login state
    (pending_login ~expires_at:20. ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  let replacement = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  ignore (Masc_tui_types.expire_identity_logins state ~now:20.);
  apply_login state replacement ~now:21. (login_result ~expires_at:40. ());
  check (Alcotest.list Alcotest.string) "replacement uses its own deadline" ["https://auth/new"]
    (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "replacement still polls" ["A"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:21.)

let test_login_that_expires_while_queued_cannot_start () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  let request = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  let noticed = ref "" in
  Masc_tui_identity_updates.login_started state request ~now:20.
    ~report:(fun _ _ -> ()) ~notice:(fun ~keeper_name:_ (_, detail) -> noticed := detail)
    (login_result ~expires_at:20. ());
  check Alcotest.bool "expiry is explained" true (contains "expired" !noticed);
  check (Alcotest.list Alcotest.string) "expired queued URL never appears" [] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "expired queued login never starts polling" []
    (held_expectations state "A")

let test_the_recovery_read_retires_only_the_landed_login () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"A" ~provider:"atlassian" ~base_path:"/w/a"
    ~masc_root:"/r";
  (* The inventory lists every declared provider; atlassian is declared and
     not attached yet, so its login is still owed. *)
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[ declared ~tools:[ "sendMessage" ] "slack" "Slack"
               ; declared "atlassian" "Atlassian" ];
  complete_attempt state "A" "slack";
  check (Alcotest.list Alcotest.string) "the landed login stops being owed"
    [ "atlassian" ] (held_expectations state "A");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[unreadable "atlassian" "read failed"];
  check (Alcotest.list Alcotest.string) "an unreadable read is not completion"
    [ "atlassian" ] (held_expectations state "A")

let test_a_workspace_change_keeps_only_its_own_expectations () =
  let state = identity_state () in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"A" ~provider:"atlassian" ~base_path:"/w/next"
    ~masc_root:"/r";
  (* The server read confirming /w/next runs before [state.server_identity]
     is updated; a held /w/a expectation must not survive it, the one held
     for the confirmed workspace must, and the filter must not lean on the
     stale field. *)
  Masc_tui_types.reconcile_detail_intent_origins state
    (Ok (workspace_identity ~base_path:"/w/next" ~masc_root:"/r"));
  check (Alcotest.list Alcotest.string)
    "only the confirmed workspace keeps its expectations" [ "atlassian" ]
    (held_expectations state "A");
  state.server_identity <- Some (workspace_identity ~base_path:"/w/next" ~masc_root:"/r");
  check (Alcotest.list Alcotest.string)
    "the surviving expectation is unaffected by the identity update"
    [ "atlassian" ] (held_expectations state "A")

let test_restart_and_forget_end_the_waiting_login () =
  let state = identity_state () in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  Masc_tui_types.forget_identity_login state ~keeper_name:"A" ~provider_id:"slack";
  check (Alcotest.list Alcotest.string) "a stopped login is no longer owed" []
    (held_expectations state "A")

let test_a_rework_rerun_ends_every_admitted_login () =
  let state = identity_state () in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"A" ~provider:"atlassian" ~base_path:"/w/a"
    ~masc_root:"/r";
  hold_expectation state ~keeper:"B" ~provider:"slack" ~base_path:"/w/b"
    ~masc_root:"/r";
  Masc_tui_types.retire_identity_login_expectations state;
  check (Alcotest.list Alcotest.string) "the rerun leaves nothing held" []
    (held_expectations state "A");
  check (Alcotest.list Alcotest.string) "no other keeper keeps one either" []
    (held_expectations state "B")

let test_late_callback_is_observed_after_authority_recovery () =
  let state = identity_state () in
  let origin = workspace_identity ~base_path:"/w/a" ~masc_root:"/r" in
  let keeper : Decode.keeper =
    { k_origin = Decode.Persisted_keeper
    ; k_name = "A"
    ; k_paused = false
    ; k_identity =
        Ok
          { k_trace_id = "trace-A"
          ; k_created_at = "2026-09-01T00:00:00Z"
          ; k_updated_at = "2026-09-05T12:00:00Z"
          }
    ; k_activity = None
    }
  in
  state.server_identity <- Some origin;
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  state.keepers <- [ keeper ];
  state.keeper_cursor <- 0;
  state.view <- Masc_tui_types.Keepers Masc_tui_types.Keeper_detail;
  state.detail_tab <- Masc_tui_types.Detail_identity;
  let request =
    Masc_tui_types.start_identity_login_request state ~keeper_name:"A"
      ~provider_id:"slack"
  in
  Masc_tui_identity_updates.login_started state request ~now:10.
    ~report:(fun _ _ -> ())
    ~notice:(fun ~keeper_name:_ _ -> ())
    (Masc_tui_identity_model.Login_started
       { provider_id = "slack"; label = "Slack"; url = "https://auth/A/consent"; expires_at = 100.; attempt_id = "attempt-slack" });
  check (Alcotest.list Alcotest.string) "consent was presented"
    [ "https://auth/A/consent" ] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "the wait was recorded" [ "slack" ]
    (held_expectations state "A");

  state.server_identity <- None;
  Masc_tui_types.withdraw_identity_readings state;
  check (Alcotest.list Alcotest.string) "unread hides the consent" []
    (pending_urls state "A");
  check Alcotest.bool "unread workspace cannot poll" false
    (Masc_tui_types.identity_login_recovery_poll_ready state ~now:10. "A");

  state.server_identity <- Some origin;
  let recovery_read =
    Masc_tui_types.mark_detail_read_started state ~tab:Masc_tui_types.Detail_identity
      ~keeper:"A" ~now_ns:1L
  in
  check Alcotest.bool "pending recovery read blocks a second read" false
    (Masc_tui_types.identity_login_recovery_poll_ready state ~now:10. "A");
  Masc_tui_identity_updates.providers_loaded state recovery_read ~attempts:[]
    (Ok [ declared "slack" "Slack" ]);
  check (Alcotest.list Alcotest.string)
    "incomplete provider read keeps the browser wait" [ "slack" ]
    (held_expectations state "A");
  check Alcotest.bool "the next tick can re-read the same workspace" true
    (Masc_tui_types.identity_login_recovery_poll_ready state ~now:10. "A");

  let late_callback_read =
    Masc_tui_types.mark_detail_read_started state ~tab:Masc_tui_types.Detail_identity
      ~keeper:"A" ~now_ns:2L
  in
  Masc_tui_identity_updates.providers_loaded state late_callback_read ~attempts:[]
    (Ok [ declared ~tools:[ "postMessage" ] "slack" "Slack" ]);
  check Alcotest.bool "the attached provider is visible" true
    (match state.identity_view with
     | Some
         ( "A"
         , [ Masc_tui_identity_model.Identity_declared
               { idp_id = "slack"; idp_tools = Some _; _ } ] ) -> true
     | _ -> false);
  complete_attempt state "A" "slack";
  check (Alcotest.list Alcotest.string) "the completed wait retires" []
    (held_expectations state "A");
  check Alcotest.bool "the tick stops after attachment" false
    (Masc_tui_types.identity_login_recovery_poll_ready state ~now:10. "A")

let test_workspace_withdrawal_retires_identity_consent () =
  let state = identity_state () in
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://old-workspace/consent" ());
  state.identity_view <- Some ("A", [declared "slack" "Slack"]);
  state.github_identity_view <- Some ("A", ["old identity"]);
  let old = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  Masc_tui_types.withdraw_identity_readings state;
  check (Alcotest.list Alcotest.string) "new workspace neither shows nor polls old consent"
    [] (pending_urls state "A");
  check Alcotest.bool "old provider list withdrawn" true (state.identity_view = None);
  check Alcotest.bool "old GitHub reading withdrawn" true (state.github_identity_view = None);
  let successor = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  check Alcotest.bool "same named successor rejects the old queued answer" false
    (Masc_tui_types.finish_identity_login_request state old);
  check Alcotest.bool "new workspace request remains current" true
    (Masc_tui_types.finish_identity_login_request state successor)

let test_oauth_polling_survives_unread_authority () =
  let state = identity_state () in
  let origin : Masc.Tui_decode.server_identity =
    { sid_version = "test"; sid_binary_commit = "test";
      sid_binary_commit_age_s = None; sid_base_path = "/workspace/a";
      sid_masc_root = "/workspace/a/.masc"; sid_executable_in_worktree = None;
      sid_state_ready = Some true; sid_uptime = None; sid_sse_clients = None;
      sid_gc = None; sid_scheduler = None } in
  let remember () = Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://consent" ()) in
  let pending () = Masc_tui_types.identity_login_pending_for_keeper state ~now:10. "A" in
  state.server_identity <- Some origin;
  remember ();
  check Alcotest.bool "accepted login participates in cadence" true (pending ());
  Masc_tui_types.withdraw_identity_readings state;
  state.server_identity <- None;
  check Alcotest.bool "unread authority cannot poll" false (pending ());
  check (Alcotest.list Alcotest.string) "withdrawal removes consent URL" [] (pending_urls state "A");
  Masc_tui_types.reconcile_detail_intent_origins state (Error "unread");
  Masc_tui_types.reconcile_detail_intent_origins state
    (Ok { origin with sid_masc_root = "" });
  state.server_identity <- Some origin;
  Masc_tui_types.reconcile_detail_intent_origins state (Ok origin);
  (* The first successful recovery GET still says consent has not landed.
     There is no URL left to drive the old cadence, but waiting must continue. *)
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[declared "slack" "Slack"];
  check Alcotest.bool "pending recovery reading keeps polling" true (pending ());
  check (Alcotest.list Alcotest.string) "recovery cannot resurrect URL" [] (pending_urls state "A");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[unreadable "slack" "temporarily unavailable"];
  check Alcotest.bool "unreadable provider retains intent" true (pending ());
  Masc_tui_types.retire_identity_logins state ~keeper_name:"B"
    ~providers:[declared ~tools:[] "slack" "Slack"];
  check Alcotest.bool "other Keeper cannot retire intent" true (pending ());
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[declared ~tools:[] "slack" "Slack"];
  complete_attempt state "A" "slack";
  check Alcotest.bool "completed attempt ends cadence" false (pending ());
  remember ();
  Masc_tui_types.forget_identity_login state ~keeper_name:"A" ~provider_id:"slack";
  check Alcotest.bool "explicit abandonment ends cadence" false (pending ());
  remember ();
  Masc_tui_types.withdraw_identity_readings state;
  Masc_tui_types.reconcile_detail_intent_origins state
    (Ok { origin with sid_masc_root = "/workspace/b/.masc" });
  Masc_tui_types.reconcile_detail_intent_origins state (Ok origin);
  check Alcotest.bool "foreign root then A cannot resurrect intent" false (pending ())

let test_switching_keepers_retains_each_consent_url () =
  let state = identity_state () in
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"atlassian" ~url:"https://auth/A" ());
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"B" ~provider:"atlassian" ~url:"https://auth/B" ());
  check (Alcotest.list Alcotest.string) "A can reopen its consent URL"
    ["https://auth/A"] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "B has its own consent URL"
    ["https://auth/B"] (pending_urls state "B");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"B"
    ~providers:[declared ~tools:[] "atlassian" "Atlassian"];
  check (Alcotest.list Alcotest.string) "B's completion preserves A's URL"
    ["https://auth/A"] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "B's completed login stops polling"
    [] (pending_urls state "B")

let test_multiple_providers_complete_independently () =
  let state = identity_state () in
  List.iter (Masc_tui_types.remember_identity_login state)
    [pending_login ~keeper:"A" ~provider:"atlassian" ~url:"https://auth/A/atlas" ();
     pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A/slack" ();
     pending_login ~keeper:"B" ~provider:"slack" ~url:"https://auth/B/slack" ()];
  check (Alcotest.list Alcotest.string) "both provider URLs remain available"
    ["https://auth/A/atlas"; "https://auth/A/slack"] (pending_urls state "A");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[declared ~tools:["sendMessage"] "slack" "Slack";
                declared "atlassian" "Atlassian"];
  check (Alcotest.list Alcotest.string) "unfinished provider stays pending"
    ["https://auth/A/atlas"] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "another keeper's Slack stays pending"
    ["https://auth/B/slack"] (pending_urls state "B")

let test_restarting_and_forgetting_only_change_the_matching_login () =
  let state = identity_state () in
  List.iter (Masc_tui_types.remember_identity_login state)
    [pending_login ~keeper:"A" ~provider:"atlassian" ~url:"https://auth/old" ();
     pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A/slack" ();
     pending_login ~keeper:"B" ~provider:"atlassian" ~url:"https://auth/B/atlas" ()];
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"atlassian" ~url:"https://auth/new" ());
  check (Alcotest.list Alcotest.string) "restart replaces only that consent URL"
    ["https://auth/A/slack"; "https://auth/new"] (pending_urls state "A");
  Masc_tui_types.forget_identity_login state ~keeper_name:"A"
    ~provider_id:"atlassian";
  check (Alcotest.list Alcotest.string) "A's other provider remains"
    ["https://auth/A/slack"] (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "B's same provider remains"
    ["https://auth/B/atlas"] (pending_urls state "B");
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[unreadable "slack" "read failed"];
  check (Alcotest.list Alcotest.string) "a failed read keeps consent evidence"
    ["https://auth/A/slack"] (pending_urls state "A")

let test_login_receipt_during_unconfirmation_keeps_polling () =
  let state = identity_state () in
  let origin = workspace_identity ~base_path:"/w/a" ~masc_root:"/r" in
  state.server_identity <- Some origin;
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  let request = Masc_tui_types.start_identity_login_request state
      ~keeper_name:"A" ~provider_id:"slack" in
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match_unconfirmed "health unavailable";
  Masc_tui_identity_updates.login_started state request ~now:10.
    ~report:(fun _ _ -> ()) ~notice:(fun ~keeper_name:_ _ -> ())
    (Masc_tui_identity_model.Login_started
       { provider_id = "slack"; label = "Slack"; url = "https://auth/A/consent";
         expires_at = 100.; attempt_id = "attempt-slack" });
  check (Alcotest.list Alcotest.string) "late receipt retains its wait" ["slack"]
    (held_expectations state "A");
  check Alcotest.bool "unconfirmed workspace cannot poll" false
    (Masc_tui_types.identity_login_pending_for_keeper state ~now:10. "A");
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  check Alcotest.bool "same workspace resumes poll" true
    (Masc_tui_types.identity_login_pending_for_keeper state ~now:10. "A");
  state.server_identity <- Some (workspace_identity ~base_path:"/w/b" ~masc_root:"/other");
  check Alcotest.bool "replacement workspace cannot inherit poll" false
    (Masc_tui_types.identity_login_pending_for_keeper state ~now:10. "A")

let test_inverse_retry_responses_keep_the_newest_consent () =
  let state = identity_state () in
  let start keeper =
    Masc_tui_types.start_identity_login_request state ~keeper_name:keeper
      ~provider_id:"atlassian"
  in
  let older = start "A" in
  let other_keeper = start "B" in
  let newer = start "A" in
  let arrive request url =
    let current = Masc_tui_types.finish_identity_login_request state request in
    if current then
      Masc_tui_types.remember_identity_login state
        (pending_login ~keeper:request.Masc_tui_types.ilr_keeper
           ~provider:request.ilr_provider ~url ());
    current
  in
  check Alcotest.bool "new retry arrives first" true
    (arrive newer "https://auth/A/new");
  check Alcotest.bool "old response is rejected" false
    (arrive older "https://auth/A/old");
  check Alcotest.bool "duplicate response is rejected" false
    (arrive newer "https://auth/A/duplicate");
  check (Alcotest.list Alcotest.string) "new consent remains actionable"
    ["https://auth/A/new"] (pending_urls state "A");
  check Alcotest.bool "B's request was not superseded by A" true
    (arrive other_keeper "https://auth/B");
  check (Alcotest.list Alcotest.string) "B's consent remains separate"
    ["https://auth/B"] (pending_urls state "B")

let test_failed_restart_preserves_the_existing_consent () =
  let state = identity_state () in
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A/slack" ());
  let restart =
    Masc_tui_types.start_identity_login_request state ~keeper_name:"A"
      ~provider_id:"slack"
  in
  let other_provider =
    Masc_tui_types.start_identity_login_request state ~keeper_name:"A"
      ~provider_id:"atlassian"
  in
  check (Alcotest.list Alcotest.string) "URL stays visible while retry runs"
    ["https://auth/A/slack"] (pending_urls state "A");
  check Alcotest.bool "failed retry consumes its request" true
    (Masc_tui_types.finish_identity_login_request state restart);
  check (Alcotest.list Alcotest.string) "failed retry preserves consent URL"
    ["https://auth/A/slack"] (pending_urls state "A");
  check Alcotest.bool "other provider's request remains current" true
    (Masc_tui_types.finish_identity_login_request state other_provider)

(* ── the cursor, once the list outgrew the digits ───────────────────── *)

let test_the_cursor_names_a_provider () =
  let providers =
    [ declared "atlassian" "Atlassian";
      unreadable "jira" "unreadable";
      declared "slack" "Slack" ]
  in
  (* Indexes the connectable list, so the broken declaration in the middle
     does not shift what the second row means. *)
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "the second connectable one"
    (Some ("slack", "Slack"))
    (Masc_tui_identity_model.identity_cursor_provider ~query:"" ~providers 1)

let test_a_cursor_past_the_end_names_the_last_row () =
  (* A list that shrank under a cursor -- a declaration stopped reading, say
     -- answers from a row that is there rather than from none at all. *)
  let providers = [ declared "atlassian" "Atlassian" ] in
  check Alcotest.int "clamped" 0
    (Masc_tui_identity_model.identity_cursor_clamped ~query:"" ~providers 7);
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "still names something" (Some ("atlassian", "Atlassian"))
    (Masc_tui_identity_model.identity_cursor_provider ~query:"" ~providers 7)

let test_nothing_connectable_names_nothing () =
  let providers = [ unreadable "jira" "unreadable" ] in
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "no row to start" None
    (Masc_tui_identity_model.identity_cursor_provider ~query:"" ~providers 0)

let test_a_row_state_is_what_the_tally_counts () =
  let providers =
    [ declared ~tools:[ "a"; "b" ] "atlassian" "Atlassian"
    ; declared ~tools:[ "a" ] ~enabled:false "airtable" "Airtable"
    ; declared ~tools:[] "asana" "Asana"
    ; declared ~tools:[ "a" ] ~switch_problem:"unreadable" "box" "Box"
    ; declared "calendly" "Calendly"
    ]
  in
  let state id = Masc_tui_identity_model.identity_row_state ~providers ~id in
  check Alcotest.bool "two tools" true (state "atlassian" = Masc_tui_identity_model.Identity_attached 2);
  check Alcotest.bool "switched off" true (state "airtable" = Masc_tui_identity_model.Identity_switched_off);
  check Alcotest.bool "attached with nothing to offer" true
    (state "asana" = Masc_tui_identity_model.Identity_attached_without_tools);
  check Alcotest.bool "an unreadable switch is not an off switch" true
    (state "box" = Masc_tui_identity_model.Identity_switch_unreadable);
  check Alcotest.bool "never attached" true
    (state "calendly" = Masc_tui_identity_model.Identity_not_attached);
  check Alcotest.bool "a service the list does not declare" true
    (state "unknown" = Masc_tui_identity_model.Identity_not_attached)

let sample =
  [ declared "googlesheets" "Google Sheets";
    declared "gmail" "Gmail";
    declared "linear" "Linear";
    unreadable "broken" "unreadable" ]

let matched query =
  List.map fst (Masc_tui_identity_model.identity_connectable ~query sample)

let test_a_query_narrows_to_what_it_names () =
  check (Alcotest.list Alcotest.string) "both Google rows"
    [ "googlesheets"; "gmail" ] (matched "g");
  check (Alcotest.list Alcotest.string) "one of them" [ "googlesheets" ]
    (matched "sheet")

let test_the_id_is_searched_as_well_as_the_label () =
  (* The screen says "Google Sheets" and the tools are named
     "googlesheets_". An operator knows whichever one they know. *)
  check (Alcotest.list Alcotest.string) "found by its id" [ "googlesheets" ]
    (matched "googlesheets")

let test_case_does_not_matter () =
  check (Alcotest.list Alcotest.string) "typed lower, labelled upper"
    [ "linear" ] (matched "LINEAR")

let test_an_empty_query_is_the_whole_list () =
  check (Alcotest.list Alcotest.string) "everything connectable"
    [ "googlesheets"; "gmail"; "linear" ] (matched "")

let test_a_query_matching_nothing_is_not_an_error () =
  check (Alcotest.list Alcotest.string) "empty" [] (matched "zzz")

let test_the_cursor_indexes_what_is_left () =
  (* The number beside a row and the provider a keypress starts both come
     from the filtered list. If the cursor indexed the whole set, pressing
     enter on the second visible row would start whatever happens to be
     second overall. *)
  let at ~query index =
    Option.map fst
      (Masc_tui_identity_model.identity_cursor_provider ~query ~providers:sample index)
  in
  (* Row three is Linear with no filter, and does not exist under "g" -- so
     the same index has to answer differently, and the filtered one clamps
     to the last row that is actually drawn. *)
  check (Alcotest.option Alcotest.string) "unfiltered, row three"
    (Some "linear") (at ~query:"" 2);
  check (Alcotest.option Alcotest.string) "filtered, clamped to the last one"
    (Some "gmail") (at ~query:"g" 2)

let test_coverage_is_carried_per_provider () =
  (* A Keeper attaches on its own account, so "who else has this" is the one
     question this tab cannot answer from its own row -- and it is the answer
     that stops an operator consenting twice as the wrong account. *)
  let providers =
    [ declared ~also_on:[ "alpha"; "bravo" ] "atlassian" "Atlassian";
      declared "linear" "Linear" ]
  in
  let coverage id =
    List.find_map
      (function
        | Masc_tui_identity_model.Identity_declared { idp_id; idp_also_on; _ }
          when String.equal idp_id id -> Some idp_also_on
        | Masc_tui_identity_model.Identity_declared _
        | Masc_tui_identity_model.Identity_unreadable _ -> None)
      providers
  in
  check
    (Alcotest.option (Alcotest.list Alcotest.string))
    "the two that have it"
    (Some [ "alpha"; "bravo" ])
    (coverage "atlassian");
  check
    (Alcotest.option (Alcotest.list Alcotest.string))
    "and none for the one nobody has" (Some []) (coverage "linear")

(* ── the app form ───────────────────────────────────────────────────── *)

let form field secret =
  { Masc_tui_identity_model.iaf_provider = "slack"
  ; iaf_label = "Slack"
  ; iaf_field = field
  ; iaf_client_id = "an-app"
  ; iaf_client_secret = secret
  ; iaf_scopes = "chat:write"
  }

let test_the_secret_is_never_drawn () =
  (* A terminal scrolls back. A credential on screen is a credential in the
     scrollback, and in whatever recorded the session. *)
  let rows =
    Masc_tui_identity_model.identity_app_form_rows
      (Some (form Masc_tui_identity_model.App_client_secret "hunter2"))
  in
  let joined = String.concat "\n" rows in
  check Alcotest.bool "the value is nowhere" false
    (Masc_tui_pick_list.lowercase_contains ~needle:"hunter2" joined);
  check Alcotest.bool "its length still shows" true
    (Masc_tui_pick_list.lowercase_contains ~needle:"*******" joined)

let test_a_pasted_list_loses_its_newlines () =
  (* A scope list copied out of a browser arrives one per line. The
     terminal's own single-line helper is for drawing and turns a newline
     into the four characters "\x0A"; those were stored, sent to Slack
     inside a scope name, and came back as "Invalid permissions requested". *)
  check Alcotest.string "one line, single spaces"
    "chat:write files:read users:read"
    (Masc_tui_identity_model.identity_field_paste
       "chat:write\nfiles:read\r\n  users:read\n")

let test_a_pasted_secret_loses_its_trailing_newline () =
  check Alcotest.string "nothing around it" "xoxp-abc123"
    (Masc_tui_identity_model.identity_field_paste "  xoxp-abc123\n")

let test_a_paste_keeps_what_is_not_a_control_character () =
  (* Bytes at or above 0x80 are UTF-8, not control characters. *)
  check Alcotest.string "unharmed" "\xed\x95\x9c\xea\xb8\x80"
    (Masc_tui_identity_model.identity_field_paste "\xed\x95\x9c\xea\xb8\x80")

let () =
  Alcotest.run "tui_identity_tab"
    [ ( "numbering",
        [ Alcotest.test_case "a broken declaration does not take a number"
            `Quick test_a_broken_declaration_does_not_take_a_number;
          Alcotest.test_case "the order is the declared order" `Quick
            test_the_order_is_the_declared_order;
          Alcotest.test_case "nothing connectable is not an error" `Quick
            test_nothing_connectable_is_not_an_error;
        ] );
      ( "the cursor",
        [ Alcotest.test_case "names a provider" `Quick
            test_the_cursor_names_a_provider;
          Alcotest.test_case "past the end names the last row" `Quick
            test_a_cursor_past_the_end_names_the_last_row;
          Alcotest.test_case "nothing connectable names nothing" `Quick
            test_nothing_connectable_names_nothing; Alcotest.test_case "a row state is what the tally counts" `Quick
            test_a_row_state_is_what_the_tally_counts;
        ] );
      ( "which other Keepers hold a service",
        [ Alcotest.test_case "coverage is carried per provider" `Quick
            test_coverage_is_carried_per_provider;
        ] );
      ( "what a paste carries into a field",
        [ Alcotest.test_case "a pasted list loses its newlines" `Quick
            test_a_pasted_list_loses_its_newlines;
          Alcotest.test_case "a pasted secret loses its trailing newline"
            `Quick test_a_pasted_secret_loses_its_trailing_newline;
          Alcotest.test_case "a paste keeps what is not a control character"
            `Quick test_a_paste_keeps_what_is_not_a_control_character;
        ] );
      ( "the app form",
        [ Alcotest.test_case "the secret is never drawn" `Quick
            test_the_secret_is_never_drawn;
        ] );
      ( "typing to narrow the list",
        [ Alcotest.test_case "a query narrows to what it names" `Quick
            test_a_query_narrows_to_what_it_names;
          Alcotest.test_case "the id is searched as well as the label" `Quick
            test_the_id_is_searched_as_well_as_the_label;
          Alcotest.test_case "case does not matter" `Quick
            test_case_does_not_matter;
          Alcotest.test_case "an empty query is the whole list" `Quick
            test_an_empty_query_is_the_whole_list;
          Alcotest.test_case "a query matching nothing is not an error" `Quick
            test_a_query_matching_nothing_is_not_an_error;
          Alcotest.test_case "the cursor indexes what is left" `Quick
            test_the_cursor_indexes_what_is_left;
        ] );
      ( "when the tick stops asking",
        [ Alcotest.test_case "a login lands when its service reports tools"
            `Quick test_a_login_lands_when_its_service_reports_tools;
          Alcotest.test_case "attached with no tools still counts as landed"
            `Quick test_attached_with_no_tools_still_counts_as_landed;
          Alcotest.test_case "not attached has not landed" `Quick
            test_not_attached_has_not_landed;
          Alcotest.test_case "another service landing does not end this login"
            `Quick test_another_service_landing_does_not_end_this_login;
        ] );
      ( "pending consent lifecycle",
        [ Alcotest.test_case "completed attempt requires current owned catalog" `Quick test_completed_attempt_requires_current_owned_catalog;
          Alcotest.test_case "a lost attempt is read against the catalog" `Quick test_a_lost_attempt_is_read_against_the_catalog;
          Alcotest.test_case "admitted callback outlives consent deadline" `Quick test_admitted_callback_outlives_consent_deadline;
          Alcotest.test_case "wire decoder preserves the server deadline" `Quick
            test_login_wire_preserves_the_server_deadline;
          Alcotest.test_case "removed provider retires display and late start" `Quick
            test_removed_provider_retires_display_and_late_start;
          Alcotest.test_case "deleted Keeper needs a complete roster" `Quick
            test_deleted_keeper_retires_only_after_a_complete_roster;
          Alcotest.test_case "expiry stops polling and retires consent" `Quick
            test_expiry_stops_polling_and_retires_consent;
          Alcotest.test_case "expiry survives authority loss" `Quick
            test_expiry_survives_authority_loss_without_resurrection;
          Alcotest.test_case "expiry preserves a replacement request" `Quick
            test_previous_expiry_preserves_a_replacement_request;
          Alcotest.test_case "queued login can expire before presentation" `Quick
            test_login_that_expires_while_queued_cannot_start;
          Alcotest.test_case "workspace withdrawal retires identity consent"
            `Quick test_workspace_withdrawal_retires_identity_consent;
          Alcotest.test_case "OAuth polling survives unread authority"
            `Quick test_oauth_polling_survives_unread_authority;
          Alcotest.test_case "late login receipt retains polling origin"
            `Quick test_login_receipt_during_unconfirmation_keeps_polling;
          Alcotest.test_case "switching Keepers retains each consent URL"
            `Quick test_switching_keepers_retains_each_consent_url;
          Alcotest.test_case "multiple providers complete independently"
            `Quick test_multiple_providers_complete_independently;
          Alcotest.test_case "restart and forget change only the matching login"
            `Quick test_restarting_and_forgetting_only_change_the_matching_login;
          Alcotest.test_case "inverse retry responses keep newest consent"
            `Quick test_inverse_retry_responses_keep_the_newest_consent;
          Alcotest.test_case "failed restart preserves existing consent"
            `Quick test_failed_restart_preserves_the_existing_consent;
        ] );
      ( "a login survives a transient authority loss",
        [ Alcotest.test_case "withdrawal retires the display but keeps the wait"
            `Quick test_withdrawal_retires_the_display_but_keeps_the_wait;
          Alcotest.test_case "only its own workspace reopens the poll" `Quick
            test_only_its_own_workspace_reopens_the_poll;
          Alcotest.test_case "every waiting Keeper is polled from any surface"
            `Quick test_every_waiting_keeper_is_polled_from_any_surface;
          Alcotest.test_case "a removed provider ends the wait" `Quick
            test_a_removed_provider_ends_the_wait;
          Alcotest.test_case "the recovery read retires only the landed login"
            `Quick test_the_recovery_read_retires_only_the_landed_login;
          Alcotest.test_case "restart and forget end the waiting login" `Quick
            test_restart_and_forget_end_the_waiting_login;
          Alcotest.test_case "a rework rerun ends every admitted login" `Quick
            test_a_rework_rerun_ends_every_admitted_login;
          Alcotest.test_case "a workspace change keeps only its own expectations"
            `Quick test_a_workspace_change_keeps_only_its_own_expectations;
          Alcotest.test_case "late callback is observed after authority recovery"
            `Quick test_late_callback_is_observed_after_authority_recovery;
        ] );
    ]
