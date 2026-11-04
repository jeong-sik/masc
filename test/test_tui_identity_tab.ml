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
    ; idp_app = None
    ; idp_callback = None
    }

(* A providers reading as the loader delivers it: the rows, and the callback
   the server named (none here). *)
let reading providers = Result.map (fun providers -> providers, None) providers

let unreadable id problem =
  Masc_tui_identity_model.Identity_unreadable { idp_id = id; idp_problem = problem }

(* The listing the tab opens with, narrowed to [query]. *)
let listing query = { Masc_tui_identity_model.identity_listing_default with query }

let ids providers =
  List.map fst (Masc_tui_identity_model.identity_connectable ~listing:(listing "") providers)

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

let login ~provider =
  {
    Masc_tui_identity_model.ils_keeper = "attaching-fixture";
    ils_provider = provider;
    ils_label = "Whatever The Screen Calls It";
    ils_url = "https://auth.example.com/authorize?x=1";
    ils_expires_at = 100.;
    ils_attempt_id = "attempt-slack";
  }

(* ── when a service counts as attached ─────────────────────────────── *)

let attached providers =
  Masc_tui_identity_model.identity_provider_attached ~providers
    ~provider_id:"atlassian"

let test_a_service_that_reports_tools_is_attached () =
  check Alcotest.bool "attached" true
    (attached [ declared ~tools:[ "getJiraIssue" ] "atlassian" "Atlassian" ])

let test_attached_with_no_tools_still_counts () =
  (* A service can be attached and offer nothing. The login did happen. *)
  check Alcotest.bool "attached" true
    (attached [ declared ~tools:[] "atlassian" "Atlassian" ])

let test_a_declaration_without_tools_is_not_attached () =
  check Alcotest.bool "not attached" false
    (attached [ declared "atlassian" "Atlassian" ])

let test_another_service_does_not_count () =
  (* Matched by id, not by the label a screen shows: a declaration is free
     to change what it is called. *)
  check Alcotest.bool "not attached" false
    (attached
       [ declared ~tools:[ "sendMessage" ] "slack" "Whatever The Screen Calls It" ])

let pending_login ?(expires_at = 100.) ~keeper ~provider ~url () =
  { (login ~provider) with ils_keeper = keeper; ils_url = url; ils_expires_at = expires_at }

let pending_urls state keeper =
  Masc_tui_types.identity_logins_for_keeper state keeper
  |> List.map (fun login -> login.Masc_tui_identity_model.ils_url)

let identity_state () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935
 ()

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

let hold_expectation ?(expires_at = Float.infinity) state ~keeper ~provider ~base_path
      ~masc_root =
  Masc_tui_types.remember_identity_login_expectation state
    { Masc_tui_types.ile_origin = workspace_identity ~base_path ~masc_root
    ; Masc_tui_types.ile_keeper = keeper
    ; Masc_tui_types.ile_provider = provider
    ; Masc_tui_types.ile_attempt_id = "attempt-" ^ provider
    ; Masc_tui_types.ile_expires_at = expires_at }

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
      Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore
        ~attempts:[expectation, Ok (Masc_tui_identity_model.Credentials_published (Ok 0))]
        (reading (Ok (Masc_tui_types.identity_expectations_for_keeper state keeper
          |> List.map (fun held -> declared ~tools:[] held.Masc_tui_types.ile_provider held.ile_provider))))

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

let test_only_its_own_workspace_reopens_the_wait () =
  let state = identity_state () in
  let admitted = workspace_identity ~base_path:"/w/a" ~masc_root:"/r" in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  state.server_identity <- Some (workspace_identity ~base_path:"/w/next" ~masc_root:"/r");
  check Alcotest.bool "a different workspace does not reopen the wait" false
    (Masc_tui_types.identity_expectation_workspace_matches ~origin:admitted state);
  state.server_identity <- Some admitted;
  check Alcotest.bool "the same workspace returning does" true
    (Masc_tui_types.identity_expectation_workspace_matches ~origin:admitted state);
  state.server_identity <- None;
  check Alcotest.bool "an unread workspace reads nothing" false
    (Masc_tui_types.identity_expectation_workspace_matches ~origin:admitted state)

(* Every Keeper a login waits on is read, wherever the operator
   is: consent happens in a browser, and the Identity tab of one Keeper is
   rarely what is on screen when it lands. *)
let test_every_waiting_keeper_is_read_from_any_surface () =
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
  check (Alcotest.list Alcotest.string) "a completed login stops being read"
    [ "A" ] (pending ());
  state.server_identity <- None;
  check (Alcotest.list Alcotest.string) "an unread workspace reads nobody" []
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

(* A failed read leaves no callback behind from the reading before it. *)
let test_failed_read_forgets_the_previous_callback () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  let load result =
    let read = Masc_tui_types.mark_detail_read_started state
      ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:1L in
    Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore ~attempts:[]
      result
  in
  load (Ok ([], Some (Masc_tui_identity_model.Callback_url "https://example.org/cb")));
  check Alcotest.bool "the first reading's callback is held" true
    (state.identity_callback <> None);
  load (Error "unavailable");
  check Alcotest.bool "a failed reading forgets it" true
    (state.identity_callback = None)

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
  Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore ~attempts:[]
    (reading (Ok []));
  apply_login state pending ~now:10. (login_result ());
  check (Alcotest.list Alcotest.string) "removed provider cannot restore its URL" []
    (pending_urls state "A");
  check (Alcotest.list Alcotest.string) "removed provider cannot restore its wait" []
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
  check (Alcotest.list Alcotest.string) "only the surviving Keeper is read" ["B"]
    (Masc_tui_types.identity_login_pending_keepers state ~now:10.)

let test_expiry_stops_waiting_and_retires_consent () =
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
    Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore
      ~attempts:[expectation, Masc_tui_identity_model.decode_identity_login_status json]
      (reading (Ok [declared "slack" "Slack"])) in
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
  check (Alcotest.list Alcotest.string) "actual completion ends the wait" [] (held_expectations state "A");
  check Alcotest.bool "credential success remains distinct from discovery failure" true
    (match state.identity_attempt_error with
     | Some (_, detail) -> contains "credentials attached" detail | None -> false)

(* The server applies a consent deadline only when the attempt is read and
   announces nothing as it passes, so each waited attempt owes its Keeper one
   read once the deadline is behind the TUI's clock. *)
let test_a_passed_consent_deadline_owes_one_read () =
  let state = identity_state () in
  hold_expectation state ~expires_at:20. ~keeper:"A" ~provider:"slack" ~base_path:"/w/a"
    ~masc_root:"/r";
  let owed () = Masc_tui_owed_read.due ~now:0. (Masc_tui_types.identity_login_read state "A") in
  Masc_tui_types.owe_identity_deadline_reads state ~now:19.;
  check Alcotest.bool "nothing is owed before the deadline" false (owed ());
  Masc_tui_types.owe_identity_deadline_reads state ~now:20.;
  check Alcotest.bool "the deadline owes its Keeper a read" true (owed ());
  Masc_tui_types.update_identity_login_read state "A" Masc_tui_owed_read.started;
  Masc_tui_types.update_identity_login_read state "A" Masc_tui_owed_read.succeeded;
  Masc_tui_types.owe_identity_deadline_reads state ~now:30.;
  check Alcotest.bool "one deadline owes one read" false (owed ())

(* An announcement names a Keeper; only a Keeper this workspace waits on a
   login for holds a read record, and the record goes with its last wait. *)
let test_only_a_waited_keeper_owes_attempt_reads () =
  let state = identity_state () in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a" ~masc_root:"/r";
  Masc_tui_types.owe_identity_login_read state "B";
  Masc_tui_types.owe_identity_login_read state "A";
  check (Alcotest.list Alcotest.string) "only the waited Keeper owes a read" [ "A" ]
    (List.map fst state.identity_login_reads);
  Masc_tui_types.forget_identity_login state ~keeper_name:"A" ~provider_id:"slack";
  Masc_tui_types.update_identity_login_read state "A" Masc_tui_owed_read.succeeded;
  check (Alcotest.list Alcotest.string) "a Keeper whose wait ended holds none" []
    (List.map fst state.identity_login_reads)

(* A callback that finished while the reading authority was gone reached
   nobody, so recovering owes every waited Keeper a read even before the
   authority is confirmed again. *)
let test_recovery_owes_every_waited_keeper () =
  let state = identity_state () in
  hold_expectation state ~keeper:"A" ~provider:"slack" ~base_path:"/w/a" ~masc_root:"/r";
  hold_expectation state ~keeper:"B" ~provider:"slack" ~base_path:"/w/a" ~masc_root:"/r";
  state.server_identity <- None;
  Masc_tui_types.owe_every_identity_login_read state;
  check (Alcotest.list Alcotest.string) "both waited Keepers owe a read" [ "A"; "B" ]
    (state.identity_login_reads
     |> List.filter_map (fun (keeper, read) ->
       if Masc_tui_owed_read.due ~now:0. read then Some keeper else None)
     |> List.sort String.compare)

(* A reading settles the read that owed it: a consent the server still calls
   waiting past its deadline, or a status it could not read, is a failure to
   retry; a callback in progress or an outcome settles it. *)
let test_a_reading_reports_how_it_settles () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  Masc_tui_types.remember_identity_login state
    (pending_login ~expires_at:20. ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  let expectation = List.hd (Masc_tui_types.identity_expectations_for_keeper state "A") in
  let settle ~now ?(providers = reading (Ok [ declared "slack" "Slack" ])) json =
    let read = Masc_tui_types.mark_detail_read_started state
      ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:10L in
    let settled = ref None in
    Masc_tui_identity_updates.providers_loaded ~now ~settle:(fun outcome -> settled := Some outcome)
      state read ~report:ignore
      ~attempts:[ expectation, Masc_tui_identity_model.decode_identity_login_status json ]
      providers;
    !settled in
  let waiting = `Assoc [ "kind", `String "awaiting_consent"; "expires_at", `Float 20. ] in
  check Alcotest.bool "a consent still before its deadline settles" true
    (settle ~now:19. waiting = Some Masc_tui_identity_updates.Reading_succeeded);
  check Alcotest.bool "a consent past its deadline the server still holds fails" true
    (settle ~now:21. waiting = Some Masc_tui_identity_updates.Reading_failed);
  check Alcotest.bool "an unreadable status fails" true
    (settle ~now:19. (`Assoc [ "kind", `String "elsewhere" ])
     = Some Masc_tui_identity_updates.Reading_failed);
  check Alcotest.bool "an unreadable catalog fails" true
    (settle ~now:19. ~providers:(Error "HTTP 503") waiting
     = Some Masc_tui_identity_updates.Reading_failed);
  check Alcotest.bool "an admitted callback settles past the deadline" true
    (settle ~now:21. (`Assoc [ "kind", `String "callback_admitted" ])
     = Some Masc_tui_identity_updates.Reading_succeeded);
  state.server_identity <- None;
  check Alcotest.bool "a reading without authority is superseded" true
    (settle ~now:19. waiting = Some Masc_tui_identity_updates.Reading_superseded)

let assert_an_offscreen_login_failure_is_reported outcome =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  let keeper name = { Decode.k_origin=Decode.Persisted_keeper; k_name=name; k_paused=false;
    k_identity=Ok {k_trace_id="trace-" ^ name;k_created_at="2026-09-01T00:00:00Z";
      k_updated_at="2026-09-05T12:00:00Z"};k_activity=None } in
  state.keepers <- [keeper "A"; keeper "B"];
  state.keeper_cursor <- 1;
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://auth/A" ());
  let expectation = List.hd (Masc_tui_types.identity_expectations_for_keeper state "A") in
  let reported = ref [] in
  let read = Masc_tui_types.mark_detail_read_started state
    ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:10L in
  Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read
    ~report:(fun line -> reported := line :: !reported)
    ~attempts:[expectation, Ok outcome]
    (reading (Ok [declared "slack" "Slack"]));
  check (Alcotest.list Alcotest.string) "the failed attempt ends the wait"
    [] (held_expectations state "A");
  check Alcotest.int "the outcome is reported once" 1 (List.length !reported);
  check Alcotest.bool "the report names the Keeper and the provider" true
    (List.for_all (fun line -> contains "A slack" line) !reported);
  check Alcotest.bool "the Keeper on screen gets no notice that is not its own" true
    (Option.is_none state.identity_attempt_error)

let test_an_offscreen_login_failure_is_reported () =
  List.iter assert_an_offscreen_login_failure_is_reported
    Masc_tui_identity_model.[Login_exchange_failed; Credential_publication_incomplete]

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
      Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore
        ~attempts:[expectation, Ok Masc_tui_identity_model.Attempt_unavailable]
        (reading catalog) in
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
  let apply read providers = Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore
    ~attempts:[expectation,completed] (reading providers) in
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
  Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore
    ~attempts:[replacement,Ok Masc_tui_identity_model.Consent_expired]
    (reading (Error "catalog unavailable"));
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
  check (Alcotest.list Alcotest.string) "replacement is still read" ["A"]
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
  check (Alcotest.list Alcotest.string) "expired queued login is never read" []
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
  check Alcotest.bool "an unread workspace cannot read" false
    (Masc_tui_types.identity_login_read_ready state ~now:10. "A");

  state.server_identity <- Some origin;
  let recovery_read =
    Masc_tui_types.mark_detail_read_started state ~tab:Masc_tui_types.Detail_identity
      ~keeper:"A" ~now_ns:1L
  in
  check Alcotest.bool "pending recovery read blocks a second read" false
    (Masc_tui_types.identity_login_read_ready state ~now:10. "A");
  Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state recovery_read ~report:ignore ~attempts:[]
    (reading (Ok [ declared "slack" "Slack" ]));
  check (Alcotest.list Alcotest.string)
    "incomplete provider read keeps the browser wait" [ "slack" ]
    (held_expectations state "A");
  check Alcotest.bool "an owed read can re-read the same workspace" true
    (Masc_tui_types.identity_login_read_ready state ~now:10. "A");

  let late_callback_read =
    Masc_tui_types.mark_detail_read_started state ~tab:Masc_tui_types.Detail_identity
      ~keeper:"A" ~now_ns:2L
  in
  Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state late_callback_read ~report:ignore ~attempts:[]
    (reading (Ok [ declared ~tools:[ "postMessage" ] "slack" "Slack" ]));
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
  check Alcotest.bool "nothing is waited on after attachment" false
    (Masc_tui_types.identity_login_read_ready state ~now:10. "A")

let test_workspace_withdrawal_retires_identity_consent () =
  let state = identity_state () in
  Masc_tui_types.remember_identity_login state
    (pending_login ~keeper:"A" ~provider:"slack" ~url:"https://old-workspace/consent" ());
  state.identity_view <- Some ("A", [declared "slack" "Slack"]);
  state.github_identity_view <- Some ("A", ["old identity"]);
  let old = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  Masc_tui_types.withdraw_identity_readings state;
  check (Alcotest.list Alcotest.string) "new workspace neither shows nor reads old consent"
    [] (pending_urls state "A");
  check Alcotest.bool "old provider list withdrawn" true (state.identity_view = None);
  check Alcotest.bool "old GitHub reading withdrawn" true (state.github_identity_view = None);
  let successor = Masc_tui_types.start_identity_login_request state
    ~keeper_name:"A" ~provider_id:"slack" in
  check Alcotest.bool "same named successor rejects the old queued answer" false
    (Masc_tui_types.finish_identity_login_request state old);
  check Alcotest.bool "new workspace request remains current" true
    (Masc_tui_types.finish_identity_login_request state successor)

let test_oauth_wait_survives_unread_authority () =
  let state = identity_state () in
  let origin : Masc.Tui_decode.server_identity =
    { sid_version = "test"; sid_binary_commit = "test";
      sid_binary_commit_age_s = None; sid_runtime_instance_id = None; sid_base_path = Masc.Tui_decode.Canonical_path.of_path "/workspace/a";
      sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/a/.masc"; sid_executable_in_worktree = None;
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
  check Alcotest.bool "unread authority cannot read" false (pending ());
  check (Alcotest.list Alcotest.string) "withdrawal removes consent URL" [] (pending_urls state "A");
  Masc_tui_types.reconcile_detail_intent_origins state (Error "unread");
  Masc_tui_types.reconcile_detail_intent_origins state
    (Ok { origin with sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "" });
  state.server_identity <- Some origin;
  Masc_tui_types.reconcile_detail_intent_origins state (Ok origin);
  (* The first successful recovery GET still says consent has not landed.
     There is no URL left to drive the old cadence, but waiting must continue. *)
  Masc_tui_types.retire_identity_logins state ~keeper_name:"A"
    ~providers:[declared "slack" "Slack"];
  check Alcotest.bool "pending recovery reading keeps the wait" true (pending ());
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
    (Ok { origin with sid_masc_root = Masc.Tui_decode.Canonical_path.of_path "/workspace/b/.masc" });
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
  (* An attached inventory does not end a login attempt: the previous
     credentials still report attached during a re-login, so the consent
     URL stays until its attempt reports terminal or its deadline passes. *)
  Masc_tui_types.retire_identity_logins state ~keeper_name:"B"
    ~providers:[declared ~tools:["sendMessage"] "atlassian" "Atlassian"];
  check (Alcotest.list Alcotest.string) "an attached report preserves A's URL"
    ["https://auth/A"] (pending_urls state "A");
  check (Alcotest.list Alcotest.string)
    "an attached report keeps B's re-login consent URL open"
    ["https://auth/B"] (pending_urls state "B")

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
  (* Tools on the row may belong to the previous credentials of a re-login;
     only the attempt's own terminal status retires the consent URL. *)
  check (Alcotest.list Alcotest.string)
    "an attached provider's pending consent URL stays open"
    ["https://auth/A/atlas"; "https://auth/A/slack"] (pending_urls state "A");
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

let test_login_receipt_during_unconfirmation_keeps_waiting () =
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
  check Alcotest.bool "unconfirmed workspace cannot read" false
    (Masc_tui_types.identity_login_pending_for_keeper state ~now:10. "A");
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  check Alcotest.bool "same workspace resumes reading" true
    (Masc_tui_types.identity_login_pending_for_keeper state ~now:10. "A");
  state.server_identity <- Some (workspace_identity ~base_path:"/w/b" ~masc_root:"/other");
  check Alcotest.bool "replacement workspace cannot inherit the wait" false
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
    (Masc_tui_identity_model.identity_cursor_provider ~listing:(listing "") ~providers 1)

let test_a_cursor_past_the_end_names_the_last_row () =
  (* A list that shrank under a cursor -- a declaration stopped reading, say
     -- answers from a row that is there rather than from none at all. *)
  let providers = [ declared "atlassian" "Atlassian" ] in
  check Alcotest.int "clamped" 0
    (Masc_tui_identity_model.identity_cursor_clamped ~listing:(listing "") ~providers 7);
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "still names something" (Some ("atlassian", "Atlassian"))
    (Masc_tui_identity_model.identity_cursor_provider ~listing:(listing "") ~providers 7)

let test_nothing_connectable_names_nothing () =
  let providers = [ unreadable "jira" "unreadable" ] in
  check
    (Alcotest.option (Alcotest.pair Alcotest.string Alcotest.string))
    "no row to start" None
    (Masc_tui_identity_model.identity_cursor_provider ~listing:(listing "") ~providers 0)

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
  List.map fst (Masc_tui_identity_model.identity_connectable ~listing:(listing query) sample)

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
      (Masc_tui_identity_model.identity_cursor_provider ~listing:(listing query) ~providers:sample index)
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

(* ── what the server said about callbacks and apps ──────────────────── *)

let test_the_callback_and_app_state_are_read_strictly () =
  let decode callback rows =
    Masc_tui_identity_model.decode_identity_providers
      (`Assoc [ "providers", `List rows; "callback", callback ])
  in
  let row app_state =
    `Assoc
      [ "provider", `String "slack"
      ; "provider_label", `String "Slack"
      ; "attached", `Bool false
      ; "app_state", app_state
      ]
  in
  let callback_of json =
    match decode json [] with
    | Ok (_, callback) -> callback
    | Error detail -> Alcotest.failf "decode failed: %s" detail
  in
  let url = "https://masc.example.org/api/v1/keepers/oauth/callback" in
  check Alcotest.bool "a URL is the callback" true
    (callback_of (`Assoc [ "url", `String url ])
     = Some (Masc_tui_identity_model.Callback_url url));
  check Alcotest.bool "a problem says why there is none" true
    (callback_of (`Assoc [ "problem", `String "no base URL" ])
     = Some (Masc_tui_identity_model.Callback_unknown "no base URL"));
  check Alcotest.bool "any other shape is not read as either" true
    (callback_of (`Assoc [ "url", `String url; "problem", `String "both" ]) = None);
  let app_of state =
    match decode `Null [ row state ] with
    | Ok ([ Masc_tui_identity_model.Identity_declared { idp_app; _ } ], _) -> idp_app
    | Ok _ -> Alcotest.fail "the row did not decode as one declared provider"
    | Error detail -> Alcotest.failf "decode failed: %s" detail
  in
  let kind ?problem name =
    `Assoc
      (("kind", `String name)
       :: (match problem with None -> [] | Some why -> [ "problem", `String why ]))
  in
  check Alcotest.bool "on file" true
    (app_of (kind "on_file") = Some Masc_tui_identity_model.App_on_file);
  check Alcotest.bool "none" true
    (app_of (kind "none") = Some Masc_tui_identity_model.App_none);
  check Alcotest.bool "a problem keeps its reason" true
    (app_of (kind ~problem:"unreadable" "problem")
     = Some (Masc_tui_identity_model.App_problem "unreadable"));
  check Alcotest.bool "a problem without a reason is unknown" true
    (app_of (kind "problem") = None);
  check Alcotest.bool "an unknown kind is unknown" true (app_of (kind "shared") = None);
  let own_callback row_callback =
    match
      decode `Null
        [ `Assoc
            [ "provider", `String "asana"
            ; "provider_label", `String "Asana"
            ; "attached", `Bool false
            ; "callback", row_callback
            ]
        ]
    with
    | Ok ([ Masc_tui_identity_model.Identity_declared { idp_callback; _ } ], _) -> idp_callback
    | Ok _ -> Alcotest.fail "the row did not decode as one declared provider"
    | Error detail -> Alcotest.failf "decode failed: %s" detail
  in
  let loopback fields = `Assoc (("kind", `String "loopback") :: fields) in
  check Alcotest.bool "a loopback row's callback is read" true
    (own_callback (loopback [ "url", `String "http://127.0.0.1:8935/cb" ])
     = Some
         (Masc_tui_identity_model.Loopback_row
            (Masc_tui_identity_model.Callback_url "http://127.0.0.1:8935/cb")));
  check Alcotest.bool "a loopback row's problem is read" true
    (own_callback (loopback [ "problem", `String "not on loopback" ])
     = Some
         (Masc_tui_identity_model.Loopback_row
            (Masc_tui_identity_model.Callback_unknown "not on loopback")));
  List.iter
    (fun (why, value) ->
      check Alcotest.bool (why ^ " is unreadable, not the server's callback") true
        (own_callback value = Some Masc_tui_identity_model.Row_callback_unreadable))
    [ "a callback with no kind", `Assoc [ "url", `String "http://127.0.0.1:8935/cb" ]
    ; "an unknown kind", `Assoc [ "kind", `String "public"; "url", `String "https://x" ]
    ; "a loopback url that is not a string", loopback [ "url", `Int 1 ]
    ; "a callback that is not an object", `String "http://127.0.0.1:8935/cb"
    ]

let test_a_read_keeps_the_servers_callback () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  let read = Masc_tui_types.mark_detail_read_started state
    ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:1L in
  let callback =
    Masc_tui_identity_model.Callback_url "http://127.0.0.1:8935/api/v1/keepers/oauth/callback"
  in
  Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore ~attempts:[]
    (Ok ([ declared "slack" "Slack" ], Some callback));
  check Alcotest.bool "the callback the server named is held" true
    (state.Masc_tui_types.identity_callback = Some callback)

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

(* ── detaching a service takes two presses ──────────────────────────── *)

let keeper_fixture name =
  { Decode.k_origin = Decode.Persisted_keeper
  ; k_name = name
  ; k_paused = false
  ; k_identity =
      Ok
        { k_trace_id = "trace-" ^ name
        ; k_created_at = "2026-09-01T00:00:00Z"
        ; k_updated_at = "2026-09-05T12:00:00Z"
        }
  ; k_activity = None
  }

let detach_state providers =
  let state = identity_state () in
  state.keepers <- [ keeper_fixture "A" ];
  state.keeper_cursor <- 0;
  state.detail_tab <- Masc_tui_types.Detail_identity;
  state.identity_view <- Some ("A", providers);
  state.identity_cursor <- 0;
  state

let test_detaching_takes_two_presses_on_the_same_row () =
  (* One press that forgets a token is one keystroke away from an accident,
     so the first press only arms the row and says so where the pane already
     reads its notice; the second press on that row is what sends it. *)
  let state = detach_state [ declared ~tools:[ "sendMessage" ] "slack" "Slack" ] in
  let sent = ref [] in
  let unbind ~keeper_name ~provider_id = sent := (keeper_name, provider_id) :: !sent in
  let disconnect () =
    Masc_tui_identity_input.disconnect state ~unbind ~report:(fun _ _ -> ())
  in
  disconnect ();
  check (Alcotest.list Alcotest.string) "the first press sends nothing" [] (List.map snd !sent);
  check Alcotest.(option (pair string string)) "it arms the row" (Some ("A", "slack"))
    state.identity_disconnect_armed;
  check Alcotest.bool "and says the second press is what sends it" true
    (match state.identity_attempt_error with
     | Some (_, detail) -> contains "press D again" detail
     | None -> false);
  disconnect ();
  check (Alcotest.list Alcotest.string) "the second press detaches it" [ "slack" ]
    (List.map snd !sent);
  check Alcotest.(option (pair string string)) "and leaves nothing armed" None
    state.identity_disconnect_armed

let test_detaching_a_service_that_is_not_attached_arms_nothing () =
  (* A declared-but-unattached provider has no token and no tools; offering
     to remove them would be a lie, so the press says so instead of arming. *)
  let state = detach_state [ declared "slack" "Slack" ] in
  let sent = ref [] in
  Masc_tui_identity_input.disconnect state
    ~unbind:(fun ~keeper_name ~provider_id -> sent := (keeper_name, provider_id) :: !sent)
    ~report:(fun _ _ -> ());
  check Alcotest.(option (pair string string)) "nothing armed" None
    state.identity_disconnect_armed;
  check (Alcotest.list Alcotest.string) "nothing sent" [] (List.map snd !sent)

let test_the_arm_does_not_move_to_another_row () =
  (* Arming Slack and then pressing over Atlassian must not detach Slack: the
     confirmation compares the armed id with the row under the cursor, so the
     moved cursor arms its own row instead of acting on the remembered one. *)
  let state =
    detach_state
      [ declared ~tools:[ "getJiraIssue" ] "atlassian" "Atlassian";
        declared ~tools:[ "sendMessage" ] "slack" "Slack" ]
  in
  let sent = ref [] in
  let unbind ~keeper_name ~provider_id = sent := (keeper_name, provider_id) :: !sent in
  state.identity_cursor <- 1;
  Masc_tui_identity_input.disconnect state ~unbind ~report:(fun _ _ -> ());
  check Alcotest.(option (pair string string)) "slack armed" (Some ("A", "slack"))
    state.identity_disconnect_armed;
  state.identity_cursor <- 0;
  Masc_tui_identity_input.disconnect state ~unbind ~report:(fun _ _ -> ());
  check (Alcotest.list Alcotest.string) "moving to another row detaches nothing" []
    (List.map snd !sent);
  check Alcotest.(option (pair string string)) "and arms the row now under the cursor"
    (Some ("A", "atlassian")) state.identity_disconnect_armed

let test_the_arm_belongs_to_the_keeper_it_was_made_on () =
  (* Arming Slack on Keeper A and walking to Keeper B, which also holds
     Slack, must not detach B's Slack on one press: the arm names the Keeper
     as well as the service, so the same provider id on another Keeper is a
     different row. *)
  let state = detach_state [ declared ~tools:[ "sendMessage" ] "slack" "Slack" ] in
  let sent = ref [] in
  let unbind ~keeper_name ~provider_id = sent := (keeper_name, provider_id) :: !sent in
  Masc_tui_identity_input.disconnect state ~unbind ~report:(fun _ _ -> ());
  check Alcotest.(option (pair string string)) "A's slack armed" (Some ("A", "slack"))
    state.identity_disconnect_armed;
  state.keepers <- [ keeper_fixture "B" ];
  state.keeper_cursor <- 0;
  state.identity_view <- Some ("B", [ declared ~tools:[ "sendMessage" ] "slack" "Slack" ]);
  Masc_tui_identity_input.disconnect state ~unbind ~report:(fun _ _ -> ());
  check (Alcotest.list Alcotest.string) "B's slack is not detached on one press" []
    (List.map snd !sent);
  check Alcotest.(option (pair string string)) "it is B's slack that is armed now"
    (Some ("B", "slack")) state.identity_disconnect_armed

(* ── order and view ───────────────────────────────────────────────── *)

let mixed =
  [ declared "airtable" "Airtable";
    declared ~tools:[ "a" ] "cloudflare" "Cloudflare";
    declared "datadog" "Datadog";
    declared ~tools:[ "a"; "b" ] "railway" "Railway";
    declared ~tools:[ "a" ] ~enabled:false "supabase" "Supabase" ]

let listed ~order ~show =
  List.map fst
    (Masc_tui_identity_model.identity_connectable
       ~listing:{ Masc_tui_identity_model.identity_listing_default with order; show }
       mixed)

let sorted = List.sort String.compare

let test_a_view_shows_only_its_services () =
  let order = Masc_tui_identity_model.Identity_declared_order in
  check (Alcotest.list Alcotest.string) "attached ones, a switched-off one included"
    [ "cloudflare"; "railway"; "supabase" ]
    (sorted (listed ~order ~show:Masc_tui_identity_model.Identity_show_attached));
  check (Alcotest.list Alcotest.string) "the others"
    [ "airtable"; "datadog" ]
    (sorted (listed ~order ~show:Masc_tui_identity_model.Identity_show_not_attached));
  check (Alcotest.list Alcotest.string) "every order shows the same set"
    (sorted (listed ~order ~show:Masc_tui_identity_model.Identity_show_all))
    (sorted
       (listed ~order:Masc_tui_identity_model.Identity_attached_first
          ~show:Masc_tui_identity_model.Identity_show_all))

let at_cursor ~listing ~providers cursor =
  Option.map fst
    (Masc_tui_identity_model.identity_cursor_provider ~listing ~providers cursor)

let test_another_order_keeps_the_cursor_on_its_service () =
  let declared_order =
    { Masc_tui_identity_model.identity_listing_default with
      order = Masc_tui_identity_model.Identity_declared_order }
  in
  let attached_first = Masc_tui_identity_model.identity_listing_default in
  List.iteri
    (fun cursor _ ->
       let before = at_cursor ~listing:declared_order ~providers:mixed cursor in
       let landed =
         Masc_tui_identity_model.identity_cursor_following
           ~before:(declared_order, mixed) ~after:(attached_first, mixed) cursor
       in
       check (Alcotest.option Alcotest.string) "the same service"
         before (at_cursor ~listing:attached_first ~providers:mixed landed))
    mixed

let test_a_login_that_lands_keeps_the_cursor_on_its_service () =
  let listing = Masc_tui_identity_model.identity_listing_default in
  let before = [ declared "airtable" "Airtable"; declared "box" "Box"; declared "canva" "Canva" ] in
  let after = [ declared "airtable" "Airtable"; declared "box" "Box";
                declared ~tools:[ "a" ] "canva" "Canva" ] in
  let landed =
    Masc_tui_identity_model.identity_cursor_following ~before:(listing, before)
      ~after:(listing, after) 2
  in
  check (Alcotest.option Alcotest.string) "still on the service that attached"
    (Some "canva") (at_cursor ~listing ~providers:after landed)

let test_a_reading_keeps_the_cursor_on_its_service () =
  let state = identity_state () in
  state.server_identity <- Some (workspace_identity ~base_path:"/w/a" ~masc_root:"/r");
  state.keepers <- [ keeper_fixture "A" ];
  state.keeper_cursor <- 0;
  let load providers =
    let read = Masc_tui_types.mark_detail_read_started state
      ~tab:Masc_tui_types.Detail_identity ~keeper:"A" ~now_ns:1L in
    Masc_tui_identity_updates.providers_loaded ~now:0. ~settle:ignore state read ~report:ignore ~attempts:[]
      (reading (Ok providers))
  in
  load [ declared "airtable" "Airtable"; declared "box" "Box"; declared "canva" "Canva" ];
  state.identity_cursor <- 2;
  load [ declared "airtable" "Airtable"; declared "box" "Box";
         declared ~tools:[ "a" ] "canva" "Canva" ];
  let providers = match state.identity_view with Some (_, p) -> p | None -> [] in
  check (Alcotest.option Alcotest.string) "the cursor followed canva"
    (Some "canva")
    (at_cursor ~listing:(Masc_tui_identity_input.current_listing state) ~providers
       state.identity_cursor)

let test_a_view_that_hides_the_cursor_clamps_it () =
  let all = Masc_tui_identity_model.identity_listing_default in
  let attached =
    { all with show = Masc_tui_identity_model.Identity_show_attached }
  in
  (* Airtable is not attached, so the attached view does not list it. *)
  let landed =
    Masc_tui_identity_model.identity_cursor_following ~before:(all, mixed)
      ~after:(attached, mixed) 4
  in
  check Alcotest.bool "inside the shorter list" true
    (landed >= 0 && landed < List.length (listed ~order:attached.order ~show:attached.show))

let test_the_cursor_row_is_the_cursor_provider_row () =
  (* The pane scrolls to [cursor_row], so it has to be the row of the
     provider under the cursor in either order, the gap between the
     attached services and the rest included. *)
  List.iter
    (fun order ->
       let listing =
         { Masc_tui_identity_model.identity_listing_default with order }
       in
       List.iteri
         (fun cursor _ ->
            let drawn =
              Masc_tui_render_identity.draw ~cols:120
                { keeper_name = "A"; providers = mixed; filter = None; cursor;
                  logins = []; attempt_error = None; app_form = None;
                  callback = None; order; show = listing.show }
            in
            match drawn.cursor_row, at_cursor ~listing ~providers:mixed cursor with
            | Some row, Some id ->
              let label =
                List.assoc id
                  (Masc_tui_identity_model.identity_connectable ~listing mixed)
              in
              check Alcotest.bool ("the row of " ^ id) true
                (contains label (List.nth drawn.rows row))
            | None, _ | _, None -> Alcotest.fail "no cursor row")
         mixed)
    [ Masc_tui_identity_model.Identity_attached_first;
      Masc_tui_identity_model.Identity_declared_order ]

let () =
  Alcotest.run "tui_identity_tab"
    [ ( "callback and apps",
        [ Alcotest.test_case "the callback and app state are read strictly" `Quick
            test_the_callback_and_app_state_are_read_strictly;
          Alcotest.test_case "a read keeps the server's callback" `Quick
            test_a_read_keeps_the_servers_callback;
          Alcotest.test_case "a failed read forgets the previous callback" `Quick
            test_failed_read_forgets_the_previous_callback;
        ] );
      ( "order and view",
        [ Alcotest.test_case "a view shows only its services" `Quick
            test_a_view_shows_only_its_services;
          Alcotest.test_case "another order keeps the cursor on its service" `Quick
            test_another_order_keeps_the_cursor_on_its_service;
          Alcotest.test_case "a login that lands keeps the cursor on its service" `Quick
            test_a_login_that_lands_keeps_the_cursor_on_its_service;
          Alcotest.test_case "a reading keeps the cursor on its service" `Quick
            test_a_reading_keeps_the_cursor_on_its_service;
          Alcotest.test_case "a view that hides the cursor clamps it" `Quick
            test_a_view_that_hides_the_cursor_clamps_it;
          Alcotest.test_case "the cursor row is the cursor provider's row" `Quick
            test_the_cursor_row_is_the_cursor_provider_row;
        ] );
      ( "numbering",
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
      ( "detaching a service",
        [ Alcotest.test_case "takes two presses on the same row" `Quick
            test_detaching_takes_two_presses_on_the_same_row;
          Alcotest.test_case "an unattached service arms nothing" `Quick
            test_detaching_a_service_that_is_not_attached_arms_nothing;
          Alcotest.test_case "the arm does not move to another row" `Quick
            test_the_arm_does_not_move_to_another_row;
          Alcotest.test_case "the arm belongs to the Keeper it was made on" `Quick
            test_the_arm_belongs_to_the_keeper_it_was_made_on;
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
      ( "when a service counts as attached",
        [ Alcotest.test_case "a service that reports tools is attached"
            `Quick test_a_service_that_reports_tools_is_attached;
          Alcotest.test_case "attached with no tools still counts" `Quick
            test_attached_with_no_tools_still_counts;
          Alcotest.test_case "a declaration without tools is not attached"
            `Quick test_a_declaration_without_tools_is_not_attached;
          Alcotest.test_case "another service does not count" `Quick
            test_another_service_does_not_count;
        ] );
      ( "pending consent lifecycle",
        [ Alcotest.test_case "completed attempt requires current owned catalog" `Quick test_completed_attempt_requires_current_owned_catalog;
          Alcotest.test_case "an offscreen login failure is reported" `Quick test_an_offscreen_login_failure_is_reported;
          Alcotest.test_case "a lost attempt is read against the catalog" `Quick test_a_lost_attempt_is_read_against_the_catalog;
          Alcotest.test_case "admitted callback outlives consent deadline" `Quick test_admitted_callback_outlives_consent_deadline;
          Alcotest.test_case "wire decoder preserves the server deadline" `Quick
            test_login_wire_preserves_the_server_deadline;
          Alcotest.test_case "removed provider retires display and late start" `Quick
            test_removed_provider_retires_display_and_late_start;
          Alcotest.test_case "deleted Keeper needs a complete roster" `Quick
            test_deleted_keeper_retires_only_after_a_complete_roster;
          Alcotest.test_case "expiry stops waiting and retires consent" `Quick
            test_expiry_stops_waiting_and_retires_consent;
          Alcotest.test_case "expiry survives authority loss" `Quick
            test_expiry_survives_authority_loss_without_resurrection;
          Alcotest.test_case "expiry preserves a replacement request" `Quick
            test_previous_expiry_preserves_a_replacement_request;
          Alcotest.test_case "queued login can expire before presentation" `Quick
            test_login_that_expires_while_queued_cannot_start;
          Alcotest.test_case "workspace withdrawal retires identity consent"
            `Quick test_workspace_withdrawal_retires_identity_consent;
          Alcotest.test_case "OAuth wait survives unread authority"
            `Quick test_oauth_wait_survives_unread_authority;
          Alcotest.test_case "late login receipt retains its origin"
            `Quick test_login_receipt_during_unconfirmation_keeps_waiting;
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
          Alcotest.test_case "only its own workspace reopens the wait" `Quick
            test_only_its_own_workspace_reopens_the_wait;
          Alcotest.test_case "a passed consent deadline owes one read" `Quick
            test_a_passed_consent_deadline_owes_one_read;
          Alcotest.test_case "only a waited Keeper owes attempt reads" `Quick
            test_only_a_waited_keeper_owes_attempt_reads;
          Alcotest.test_case "a reading reports how it settles" `Quick
            test_a_reading_reports_how_it_settles;
          Alcotest.test_case "recovery owes every waited Keeper" `Quick
            test_recovery_owes_every_waited_keeper;
          Alcotest.test_case "every waiting Keeper is read from any surface"
            `Quick test_every_waiting_keeper_is_read_from_any_surface;
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
