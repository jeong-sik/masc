module Tui_decode = Masc.Tui_decode

let identity base_path : Tui_decode.server_identity =
  { Tui_decode.sid_version = "0.24.0"
  ; sid_binary_commit = "abc1234"
  ; sid_binary_commit_age_s = Some 10.
  ; sid_base_path = base_path
  ; sid_masc_root = base_path ^ "/.masc"
  ; sid_executable_in_worktree = Some false
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  }

let test_same_endpoint_restart_replaces_a_with_b () =
  let current = ref None in
  let apply reading =
    current := Masc_tui_types.server_identity_of_refresh reading
  in
  apply (Ok (identity "/a"));
  apply (Ok (identity "/b"));
  match !current with
  | None -> Alcotest.fail "a successful B probe removed the identity"
  | Some reading ->
    Alcotest.(check string) "current base path" "/b"
      reading.Tui_decode.sid_base_path

let test_failed_probe_is_unread_not_stale () =
  Alcotest.(check bool) "failed probe has no current identity" true
    (Option.is_none
       (Masc_tui_types.server_identity_of_refresh (Error "one failed tick")))

let test_workspace_identity_matches_canonical_paths () =
  let dir = Filename.temp_file "tui-workspace-identity-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Unix.mkdir (Filename.concat dir ".masc") 0o755;
  let alias = dir ^ "-alias" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove alias with Sys_error _ -> ());
      Unix.rmdir (Filename.concat dir ".masc");
      Unix.rmdir dir)
    (fun () ->
       Unix.symlink dir alias;
       Alcotest.(check bool) "same canonical base and runtime root retain request authority" true
         (Masc_tui_types.server_workspace_matches ~expected:(Some (identity alias))
            (Ok (identity dir)));
       match
         Masc_tui_types.workspace_identity_of_refresh
           ~local_base_path:alias
           (Ok (identity dir))
       with
       | Masc_tui_types.Workspace_identity_match -> ()
       | _ -> Alcotest.fail "canonical aliases did not match")

let test_workspace_identity_mismatch_keeps_both_paths () =
  match
    Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:"/workspace/local"
      (Ok (identity "/workspace/server"))
  with
  | Masc_tui_types.Workspace_identity_mismatch
      { local_base_path; server_base_path } ->
    Alcotest.(check string) "local path" "/workspace/local" local_base_path;
    Alcotest.(check string) "server path" "/workspace/server" server_base_path
  | _ -> Alcotest.fail "different workspaces were not blocked"

(* The server reports [<base>/.masc] as its root and the TUI composes its
   own the same way. The same base matches; a server reporting another root
   under the same base is another store. *)
let test_workspace_identity_compares_the_masc_root () =
  let base = "/workspace/local" in
  let classify masc_root =
    Masc_tui_types.workspace_identity_of_refresh ~local_base_path:base
      (Ok { (identity base) with Tui_decode.sid_masc_root = masc_root })
  in
  let is_match = function
    | Masc_tui_types.Workspace_identity_match -> true
    | Masc_tui_types.Workspace_identity_match_unconfirmed _
    | Masc_tui_types.Workspace_identity_mismatch _
    | Masc_tui_types.Workspace_identity_unread -> false
  in
  Alcotest.(check bool) "the base's .masc is this workspace" true
    (is_match (classify (Filename.concat base ".masc")));
  Alcotest.(check bool) "another root under the same base is another store" false
    (is_match (classify (Filename.concat base "elsewhere/.masc")))

let test_broadcast_retry_scope_follows_verified_workspace () =
  let scope reading = Masc_tui_types.broadcast_workspace_scope
    ~local_base_path:"/workspace/local" reading in
  let original = identity "/workspace/local" in
  let restarted = { original with Tui_decode.sid_binary_commit = "after-restart";
    sid_uptime = Some "new process" } in
  Alcotest.(check (option string)) "port-independent workspace retry scope"
    (scope (Some original)) (scope (Some restarted));
  Alcotest.(check bool) "another MASC store has another scope" true
    (scope (Some original) <> scope (Some { restarted with sid_masc_root = "/workspace/other/.masc" }));
  Alcotest.(check (option string)) "foreign workspace refuses admission" None
    (scope (Some (identity "/workspace/foreign")));
  Alcotest.(check (option string)) "unread server refuses admission" None (scope None);
  Alcotest.(check (option string)) "booting server refuses admission" None
    (scope (Some { original with sid_state_ready = Some false }))

let test_detail_intents_wait_for_comparable_identity () =
  let state = Masc_tui_types.create_state ~workspace:"a"
    ~local_base_path:"/workspace/a" ~port:0 ~refresh_interval:0. () in
  let origin = identity "/workspace/a" in
  state.detail_focus_recovery <- Some (origin, "same-keeper", Masc_tui_types.Detail_instructions);
  state.connector_unbind_offer_pending <- ["same-keeper"];
  state.connector_unbind_offer_origin <- Some origin;
  state.keeper_sandbox_logs_requested <- Some "same-keeper";
  state.keeper_sandbox_logs_origin <- Some origin;
  let apply = Masc_tui_types.reconcile_detail_intent_origins state in
  let retained label =
    Alcotest.(check bool) (label ^ " source-bound detail focus") true
      (state.detail_focus_recovery = Some (origin, "same-keeper", Masc_tui_types.Detail_instructions));
    Alcotest.(check (list string)) (label ^ " connector intent")
      ["same-keeper"] state.connector_unbind_offer_pending;
    Alcotest.(check (option string)) (label ^ " Sandbox intent")
      (Some "same-keeper") state.keeper_sandbox_logs_requested;
    Alcotest.(check bool) (label ^ " origins remain bound") true
      (state.connector_unbind_offer_origin = Some origin
       && state.keeper_sandbox_logs_origin = Some origin)
  in
  apply (Error "health unavailable"); retained "failed probe";
  apply (Ok { origin with sid_base_path = "" }); retained "missing base";
  apply (Ok { origin with sid_masc_root = "" }); retained "missing root";
  apply (Ok { origin with sid_base_path = ""; sid_masc_root = "";
    sid_state_ready = Some false }); retained "booting unread";
  apply (Ok origin); retained "same workspace recovery";
  (* Same Keeper name and base, different runtime store: no inherited log
     request or post-action offer may become an action in that new store. *)
  apply (Ok { origin with sid_masc_root = "/workspace/a/another-masc-root" });
  Alcotest.(check bool) "foreign root retires detail focus" true
    (state.detail_focus_recovery = None);
  Alcotest.(check (list string)) "foreign root clears connector intent"
    [] state.connector_unbind_offer_pending;
  Alcotest.(check (option string)) "foreign root clears Sandbox intent"
    None state.keeper_sandbox_logs_requested;
  Alcotest.(check bool) "foreign root retires both origins" true
    (state.connector_unbind_offer_origin = None && state.keeper_sandbox_logs_origin = None);
  apply (Ok origin);
  Alcotest.(check bool) "return to A does not recreate detail focus" true
    (state.detail_focus_recovery = None);
  Alcotest.(check (option string)) "return to A does not recreate Sandbox intent"
    None state.keeper_sandbox_logs_requested

let test_same_base_with_different_masc_root_cannot_restore_inputs () =
  let a = identity "/workspace/shared" in
  let b = { a with sid_masc_root = "/workspace/other-store/.masc" } in
  (match Masc_tui_types.workspace_identity_of_refresh
      ~local_base_path:"/workspace/shared" (Ok b) with
   | Masc_tui_types.Workspace_identity_mismatch _ -> ()
   | _ -> Alcotest.fail "a different MASC root authorized local metadata");
  let key identity = Masc_tui_types.workspace_input_identity_of_server (Some identity) in
  let retained = [key a, "A's queued input and draft"] in
  Alcotest.(check (option string)) "B cannot restore A's retained input" None
    (List.assoc_opt (key b) retained);
  Alcotest.(check (option string)) "returning to A retains explicit resume"
    (Some "A's queued input and draft") (List.assoc_opt (key a) retained)

(* The keeper, task and log lists start empty and are read only once the server
   vouches for this workspace, so before that an empty list is not an empty
   workspace (#35747). *)
let test_local_rows_are_unread_until_the_workspace_is_read () =
  let state =
    Masc_tui_types.create_state ~workspace:"local"
      ~local_base_path:"/workspace/local" ~port:0 ~refresh_interval:0. ()
  in
  let page error =
    match Masc_tui_types.local_rows_page state ~error with
    | Masc_tui_types.Page_unread -> "unread"
    | Masc_tui_types.Page_failed -> "failed"
    | Masc_tui_types.Page_empty -> "empty"
  in
  Alcotest.(check string) "a fresh state has read nothing" "unread" (page None);
  state.Masc_tui_types.local_workspace <- Masc_tui_types.Local_workspace_read;
  Alcotest.(check string) "a read with no rows is empty" "empty" (page None);
  Alcotest.(check string) "a read with an error failed" "failed"
    (page (Some "keeper metadata unavailable"))

let test_request_authority_requires_complete_current_identity () =
  let before = identity "/a" in
  let accepts after =
    Masc_tui_types.server_workspace_matches ~expected:(Some before) after
  in
  Alcotest.(check bool) "same workspace" true (accepts (Ok before));
  Alcotest.(check bool) "dynamic health does not revoke" true
    (accepts (Ok { before with sid_uptime = Some "30s" }));
  Alcotest.(check bool) "different base" false (accepts (Ok (identity "/b")));
  Alcotest.(check bool) "different runtime root" false
    (accepts (Ok { before with sid_masc_root = "/a/other-root" }));
  Alcotest.(check bool) "booting successor" false
    (accepts (Ok { before with sid_state_ready = Some false }));
  Alcotest.(check bool) "unavailable successor" false (accepts (Error "unavailable"));
  Alcotest.(check bool) "no prior identity" false
    (Masc_tui_types.server_workspace_matches ~expected:None (Ok before));
  Alcotest.(check bool) "missing root cannot authorize" false
    (let incomplete = { before with sid_masc_root = "" } in
     Masc_tui_types.server_workspace_matches ~expected:(Some incomplete) (Ok incomplete))

let test_detail_focus_waits_for_authoritative_roster () =
  let open Masc_tui_types in
  let origin = identity "/workspace/a" in
  let keeper name : keeper = { k_origin = Tui_decode.Persisted_keeper; k_name = name;
    k_paused = false; k_identity = Error "not needed for navigation"; k_activity = None } in
  let suspended () =
    let state = create_state ~workspace:"local" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
    state.workspace_identity <- Workspace_identity_match;
    state.server_identity <- Some origin;
    state.local_workspace <- Local_workspace_read;
    state.local_keepers <- Local_workspace_read;
    state.keepers <- [keeper "other"; keeper "focused"];
    state.keeper_cursor <- 1;
    state.view <- Keepers Keeper_detail;
    state.detail_tab <- Detail_instructions;
    remember_keeper_detail_focus state;
    state.keepers <- [];
    state.keeper_cursor <- 0;
    state.server_identity <- None;
    state.workspace_identity <- Workspace_identity_unread;
    state.local_workspace <- Local_workspace_unread;
    state.local_keepers <- Local_workspace_unread;
    state
  in
  let ready state keepers =
    state.server_identity <- Some origin;
    state.workspace_identity <- Workspace_identity_match;
    state.local_workspace <- Local_workspace_read;
    state.local_keepers <- Local_workspace_read;
    state.keepers <- keepers;
    (* Model the loader's list fallback after untrusted rows were cleared. *)
    state.view <- Keepers Keeper_list
  in
  let state = suspended () in
  reconcile_detail_intent_origins state (Ok {origin with sid_masc_root=""});
  Alcotest.(check bool) "incomplete identity cannot restore" false (restore_keeper_detail_focus state);
  Alcotest.(check int) "navigation retains no untrusted rows" 0 (List.length state.keepers);
  ready state [keeper "focused";keeper "other"];
  state.keepers_error <- Some "roster unavailable";
  Alcotest.(check bool) "failed roster cannot restore" false (restore_keeper_detail_focus state);
  state.keepers_error <- None;
  Alcotest.(check bool) "matching complete roster restores focus" true (restore_keeper_detail_focus state);
  Alcotest.(check bool) "name and tab survive reorder" true
    (state.view=Keepers Keeper_detail && state.keeper_cursor=0 && state.detail_tab=Detail_instructions);
  Alcotest.(check bool) "restoration is consumed once" false (restore_keeper_detail_focus state);
  let left = suspended () in
  ready left [keeper "focused"];
  left.view <- Overview;
  Alcotest.(check bool) "leaving fallback list prevents recovery navigation" false
    (restore_keeper_detail_focus left);
  Alcotest.(check bool) "explicit exit retires focus" true (left.detail_focus_recovery=None);
  let missing = suspended () in
  ready missing [keeper "other"];
  Alcotest.(check bool) "missing name cannot reopen another Keeper" false (restore_keeper_detail_focus missing);
  Alcotest.(check bool) "trusted absence retires intent" true (missing.detail_focus_recovery=None);
  let foreign = suspended () in
  reconcile_detail_intent_origins foreign (Ok {origin with sid_masc_root="/workspace/a/foreign"});
  ready foreign [keeper "focused"];
  Alcotest.(check bool) "foreign store retires intent even after returning" false (restore_keeper_detail_focus foreign)

(* A read that cannot name the server's workspace does not say it serves
   another one. After a match it keeps that match, unconfirmed; only a read
   that names a different workspace changes it. *)
let test_unread_after_a_match_keeps_it_unconfirmed () =
  let local = "/workspace/local" in
  let next previous reading =
    Masc_tui_types.next_workspace_identity ~previous ~local_base_path:local reading
  in
  let label = function
    | Masc_tui_types.Workspace_identity_unread -> "unread"
    | Workspace_identity_match -> "match"
    | Workspace_identity_match_unconfirmed reason -> "unconfirmed: " ^ reason
    | Workspace_identity_mismatch { server_base_path; _ } ->
      "mismatch: " ^ server_base_path
  in
  let check name expected previous reading =
    Alcotest.(check string) name expected (label (next previous reading))
  in
  let booting = { (identity local) with sid_state_ready = Some false } in
  check "a failed read after a match keeps it" "unconfirmed: one failed tick"
    Workspace_identity_match (Error "one failed tick");
  check "a booting server after a match keeps it" "unconfirmed: the server is starting"
    Workspace_identity_match (Ok booting);
  check "another failed read stays unconfirmed" "unconfirmed: still down"
    (Workspace_identity_match_unconfirmed "one failed tick") (Error "still down");
  check "the same workspace confirms it again" "match"
    (Workspace_identity_match_unconfirmed "one failed tick") (Ok (identity local));
  check "a different workspace is still a mismatch" "mismatch: /workspace/other"
    (Workspace_identity_match_unconfirmed "one failed tick")
    (Ok (identity "/workspace/other"));
  check "a failed read with no match before is unread" "unread"
    Workspace_identity_unread (Error "boot");
  check "a failed read after a mismatch is unread" "unread"
    (Workspace_identity_mismatch
       { local_base_path = local; server_base_path = "/workspace/other" })
    (Error "one failed tick");
  (* A booting server's paths name its workspace even though it cannot
     serve yet: another workspace withdraws the match. *)
  check "a booting server of another workspace withdraws the match" "unread"
    Workspace_identity_match
    (Ok { (identity "/workspace/other") with sid_state_ready = Some false })

(* A write goes out only while the authority it was launched under is current
   and the server identity is confirmed. *)
let test_writes_wait_for_a_confirmed_identity () =
  let state = Masc_tui_types.create_state ~workspace:"a"
    ~local_base_path:"/workspace/a" ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  let authority = state.workspace_authority in
  let refusal () = Masc_tui_types.write_authority_refusal state authority in
  Alcotest.(check (option string)) "a confirmed match sends" None (refusal ());
  state.workspace_identity <-
    Masc_tui_types.Workspace_identity_match_unconfirmed "one failed tick";
  Alcotest.(check (option string)) "an unconfirmed match waits"
    (Some "Workspace identity is unconfirmed") (refusal ());
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  let (Masc_tui_types.Workspace_authority generation) = state.workspace_authority in
  state.workspace_authority <- Masc_tui_types.Workspace_authority (generation + 1);
  Alcotest.(check (option string)) "a moved authority refuses"
    (Some "Workspace authority withdrawn") (refusal ())

let test_partial_identity_keeps_definite_mismatches () =
  let local = "/workspace/a" in
  let original = identity local in
  let different_partial_paths =
    [ { original with sid_base_path = "/workspace/b"; sid_masc_root = "" }
    ; { original with sid_base_path = ""; sid_masc_root = "/workspace/b/.masc" } ] in
  List.iter (fun observed ->
    List.iter (fun previous ->
      match Masc_tui_types.next_workspace_identity ~previous ~local_base_path:local (Ok observed) with
      | Masc_tui_types.Workspace_identity_mismatch _ -> ()
      | Workspace_identity_unread | Workspace_identity_match
      | Workspace_identity_match_unconfirmed _ ->
        Alcotest.fail "one missing path hid the other path's definite mismatch")
      [ Masc_tui_types.Workspace_identity_match
      ; Workspace_identity_match_unconfirmed "health failed" ])
    different_partial_paths;
  List.iter (fun observed ->
    match Masc_tui_types.next_workspace_identity
        ~previous:Workspace_identity_match ~local_base_path:local
        (Ok { observed with sid_state_ready = Some false }) with
    | Masc_tui_types.Workspace_identity_unread -> ()
    | Workspace_identity_match | Workspace_identity_mismatch _
    | Workspace_identity_match_unconfirmed _ ->
      Alcotest.fail "a booting replacement must withdraw the retained match")
    different_partial_paths;
  List.iter (fun observed ->
    match Masc_tui_types.next_workspace_identity
        ~previous:Workspace_identity_match ~local_base_path:local (Ok observed) with
    | Masc_tui_types.Workspace_identity_match_unconfirmed _ -> ()
    | Workspace_identity_unread | Workspace_identity_match | Workspace_identity_mismatch _ ->
      Alcotest.fail "a missing path without contradictory evidence must stay unconfirmed")
    [ { original with sid_base_path = "" }; { original with sid_masc_root = "" } ]

let test_deletion_inventory_waits_for_reconfirmed_workspace () =
  let open Masc_tui_types in
  let module Deletions = Masc_tui_keeper_control in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let record keeper_name : Deletions.deletion_row =
    { operation = Deletions.Configuration_removal
        { Masc.Keeper_configuration_removal.operation_id = Masc.Keeper_shutdown_types.Operation_id.generate ()
        ; keeper_name; actor = "test"; source_sha256 = ""; source_path = ""
        ; requested_at = ""; updated_at = ""
        ; state = Masc.Keeper_configuration_removal.Cleanup_required "pending cleanup"
        ; last_error = None }
    ; completed = false; can_retry = true }
  in
  let first = record "workspace-a-first" in
  let selected = record "workspace-a-selected" in
  let a : Deletions.deletion_inventory = { operations = [ first; selected ]; errors = [] } in
  let b : Deletions.deletion_inventory = { operations = [ record "workspace-b" ]; errors = [] } in
  let begin_read () = match begin_keeper_deletions_read state with
    | Some generation -> generation
    | None -> Alcotest.fail "confirmed workspace should admit inventory read" in
  apply_keeper_deletions_read state ~generation:(begin_read ()) (Ok a);
  state.keeper_deletions_cursor <- 1;
  let before_failure = begin_read () in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Error "health unavailable");
  (* The identity transition retires only the request, not its cached rows. *)
  suspend_keeper_deletions_read state;
  let check_preserved label =
    Alcotest.(check bool) (label ^ ": A inventory remains visible") true
      (state.keeper_deletions = Some (Ok a));
    Alcotest.(check int) (label ^ ": selected row stays selected") 1 state.keeper_deletions_cursor in
  apply_keeper_deletions_read state ~generation:before_failure (Ok b);
  check_preserved "B responds during uncertainty";
  Alcotest.(check (option int)) "D/r does not launch an unconfirmed read" None
    (begin_keeper_deletions_read state);
  (* Completion checks identity itself as well as generation. *)
  apply_keeper_deletions_read state ~generation:state.keeper_deletions_generation (Ok b);
  check_preserved "matching generation cannot replace unconfirmed rows";
  apply_keeper_deletions_read state ~generation:state.keeper_deletions_generation (Error "HTTP 503");
  check_preserved "failed unconfirmed read";
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Ok (identity "/workspace/a"));
  apply_keeper_deletions_read state ~generation:before_failure (Ok b);
  check_preserved "late response remains stale after A reconfirms";
  let refreshed = { a with operations = [ selected; first ] } in
  apply_keeper_deletions_read state ~generation:(begin_read ()) (Ok refreshed);
  Alcotest.(check bool) "a new confirmed read replaces the inventory" true
    (state.keeper_deletions = Some (Ok refreshed));
  Alcotest.(check int) "selection follows its operation after reorder" 0 state.keeper_deletions_cursor

(* An Info refresh queued behind an in-flight Keeper lanes read belongs to
   that read's authority. Suspension retires the read; the replacement read
   launched after reconfirmation leaves later than the queued request, so it
   satisfies it. A flag left behind would start a second, redundant read
   when the replacement answers, and that read's failure would overwrite the
   recovered reading with a stale error. *)
let test_suspension_folds_queued_lanes_reread_into_resume () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.keeper_lanes_inflight <- true;
  state.keeper_lanes_reread_pending <- true;
  suspend_workspace_readings state;
  Alcotest.(check bool) "in-flight read released" false state.keeper_lanes_inflight;
  Alcotest.(check bool) "queued reread retired with its authority" false
    state.keeper_lanes_reread_pending;
  Alcotest.(check bool) "replacement read still requested" true state.keeper_lanes_resume;
  (* A queued reread whose read was already released (not run) still asks
     for a replacement after reconfirmation. *)
  state.keeper_lanes_resume <- false;
  state.keeper_lanes_reread_pending <- true;
  suspend_workspace_readings state;
  Alcotest.(check bool) "queued reread retired without an in-flight read" false
    state.keeper_lanes_reread_pending;
  Alcotest.(check bool) "its demand carried into resume" true state.keeper_lanes_resume

let test_uncertain_identity_retires_reads_not_admitted_operations () =
  let open Masc_tui_types in
  let module Detail = Masc_tui_board_detail in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let post body : board_post =
    { bp_id = "same-id"; bp_author = "author"; bp_title = "Thread";
      bp_body = body; bp_votes = 0; bp_comment_count = 0;
      bp_created_at = "2026-10-07"; bp_created_at_unix = None; bp_updated_at = None;
      bp_hearth = None; bp_kind = None; bp_closed = None; bp_attachments = [] } in
  let a = post "A's retained post" and b = post "B's delayed post" in
  let begin_read () = match Detail.start state.board_detail ~post_id:a.bp_id with
    | Detail.Started (next, request) -> state.board_detail <- next; request
    | Detail.Already_loading -> Alcotest.fail "retired Board read still owns its slot" in
  let initial = begin_read () in
  state.board_detail <- Detail.complete state.board_detail initial (Ok (a, [], None));
  let delayed = begin_read () in
  let authority = state.workspace_authority in
  let reading = Some state.workspace_read_authority in
  let admitted kind = workspace_reply_admitted state ~authority ~reading ~kind in
  let cancelled_write = ref false and cancelled_observation = ref false in
  state.workspace_cancellations <- [ref (), (fun () -> cancelled_write := true)];
  state.workspace_observation_cancellations <- [ref (), (fun () -> cancelled_observation := true)];
  Masc_tui_message_input.insert state.msg_input "unsent draft";
  state.keeper_yolo_names <- ["A-keeper"];
  state.keeper_turns_inflight <- true;
  let browser = Browser_lane_view.create () in
  state.browser_lane <- Some {browser with load=Browser_lane_view.Loading (1, Read)};
  state.keeper_queue_inflight <- ["reading"; "writing"];
  state.keeper_queue_readings <- ["reading"];
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Error "health failed");
  suspend_workspace_readings state;
  Alcotest.(check bool) "old Board/mode read is inadmissible during uncertainty" false
    (admitted Workspace_observation);
  Alcotest.(check bool) "admitted write and chat receipt keep their authority" true
    (admitted Workspace_operation_outcome);
  Alcotest.(check bool) "observation stream is cancelled" true !cancelled_observation;
  Alcotest.(check bool) "admitted operation is not cancelled" false !cancelled_write;
  Alcotest.(check bool) "read-only in-flight slot is released" false state.keeper_turns_inflight;
  Alcotest.(check string) "draft is preserved" "unsent draft"
    (Masc_tui_message_input.contents state.msg_input);
  Alcotest.(check (list string)) "retained mode rows are preserved" ["A-keeper"] state.keeper_yolo_names;

  Alcotest.(check (list string)) "queue observation releases only its own slot" ["writing"]
    state.keeper_queue_inflight;
  (match state.browser_lane with
   | Some {load=Browser_lane_view.Idle; _} -> ()
   | _ -> Alcotest.fail "browser read stayed pending");
  state.browser_lane <- Some {browser with load=Browser_lane_view.Loading (2, Goto "https://example.test")};
  suspend_workspace_readings state;
  (match state.browser_lane with
   | Some {load=Browser_lane_view.Loading (2, Goto _); _} -> ()
   | _ -> Alcotest.fail "admitted browser navigation lost its receipt owner");
  state.board_detail <- Detail.complete state.board_detail delayed (Ok (b, [], None));
  (match Detail.view_for state.board_detail ~post_id:a.bp_id with
   | Detail.Ready (shown, _, _) -> Alcotest.(check string) "A stays on screen" a.bp_body shown.bp_body
   | Detail.Absent | Detail.Loading | Detail.Failed _ -> Alcotest.fail "retirement erased A's detail");
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Ok (identity "/workspace/a"));
  Alcotest.(check bool) "reconfirming A cannot revive B's old read stamp" false
    (admitted Workspace_observation);
  Alcotest.(check bool) "a read dispatched during uncertainty cannot enter on reconfirmation" false
    (workspace_reply_admitted state ~authority ~reading:None ~kind:Workspace_observation);
  let refreshed = begin_read () in
  Alcotest.(check bool) "reconfirmed reads get a fresh Board request" false
    (Detail.same_request delayed refreshed);
  Alcotest.(check bool) "new confirmed read is admitted" true
    (workspace_reply_admitted state ~authority ~reading:(Some state.workspace_read_authority)
      ~kind:Workspace_observation);
  state.board_detail <- Detail.complete state.board_detail refreshed (Ok (a, [], None))

let test_operation_receipt_outlives_queued_followup_read () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let reading = Some state.workspace_read_authority in
  (* The POST has completed; its later GET has produced B's snapshot and
     the combined result is already queued, before health failure applies. *)
  let queued = ("saved-A-revision", Ok "B's follow-up snapshot") in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Error "health failed");
  suspend_workspace_readings state;
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path (Ok (identity "/workspace/a"));
  let receipt, observation = workspace_operation_reply state ~authority ~reading queued in
  Alcotest.(check string) "POST revision receipt survives reconfirmation" "saved-A-revision" receipt;
  Alcotest.(check bool) "queued GET snapshot stays retired after A returns" true (Result.is_error observation);
  let fresh_receipt, fresh_observation = workspace_operation_reply state ~authority
      ~reading:(Some state.workspace_read_authority) ("next-receipt", Ok "A's current snapshot") in
  Alcotest.(check string) "fresh receipt retained" "next-receipt" fresh_receipt;
  Alcotest.(check (result string string)) "new epoch can observe A" (Ok "A's current snapshot") fresh_observation;
  let module Login = Masc_tui_account_login in
  let view = Login.create "test" in
  view.phase <- Login.Finished {saved=Login.Saved_verified;
    activation=Login.Active {exact_output_available=true}; refresh_failed=false};
  suspend_account_login_read view;
  (match view.phase with
   | Login.Finished {saved=Login.Saved_verified; activation=Login.Active _; refresh_failed=true} -> ()
   | _ -> Alcotest.fail "retired account inventory lost the save/activation receipt")

let test_unknown_voice_save_read_retirement () =
  let open Masc_tui_types in
  let module Wizard = Masc_tui_voice_wizard_session in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  let opened = Wizard.voice_wizard_open ~section:Voice_setup.Tts
      ~provider:Voice_wizard.Elevenlabs ~revision:"before-save" in
  let sending = Wizard.voice_wizard_sending opened ~request:7 in
  state.voice_wizard <- Some sending;
  suspend_workspace_readings state;
  (match state.voice_wizard with
   | Some {vws_save=Wizard.Save_sending 7; _} -> ()
   | _ -> Alcotest.fail "admitted voice save lost its receipt owner");
  let unanswered = match Wizard.voice_wizard_after_save sending ~request:7
      (Wizard.Save_unanswered_reply "connection lost") with
    | Some session -> session | None -> Alcotest.fail "save receipt lost" in
  let check_retired () = match state.voice_wizard with
    | Some {vws_save=Wizard.Save_needs_reopen _; vws_revision; vws_draft; _} ->
        Alcotest.(check string) "original revision retained" "before-save" vws_revision;
        Alcotest.(check bool) "voice draft retained" true (vws_draft = opened.vws_draft)
    | _ -> Alcotest.fail "unanswered save still waits for a retired reread" in
  state.voice_wizard <- Some unanswered;
  suspend_workspace_readings state;
  check_retired ();
  (* The receipt can first arrive after retirement; refused read admission
     must settle only its observation owner, leaving the save unknown. *)
  state.voice_wizard <- Some unanswered;
  suspend_voice_wizard_read state;
  check_retired ()

let test_nested_read_owners_retire_without_losing_selection () =
  let open Masc_tui_types in
  let module Wizard = Masc_tui_voice_wizard_session in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  let opened = Wizard.voice_wizard_open ~section:Voice_setup.Tts
      ~provider:Voice_wizard.Elevenlabs ~revision:"saved" in
  state.voice_wizard <- Some {opened with vws_save=Wizard.Save_probing 7};
  state.runtime_catalog_reading <- Runtime_catalog_loading;
  let order,owner = Local_read_order.start ~intent:Snapshot_read.Poll state.runtime_catalog_order in
  state.runtime_catalog_order <- order;
  let owner = match owner with Some (owner,_) -> owner | None -> Alcotest.fail "catalogue owner did not start" in
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some "alpha";
  state.context_inspector_loading <- true;
  state.schedule_detail_id <- Some "schedule-a";
  state.schedule_wake_history_inflight <- Some "schedule-a";
  state.patch_modal_open <- true;
  state.patch_modal_path <- Some "lib/example.ml";
  state.resource_pending_uri <- Some "masc://selected/resource";
  state.prompts_librarian_input_requested <- Some "librarian-input";
  state.prompts_librarian_input_loading <- true;
  suspend_workspace_readings state;
  Alcotest.(check (option string)) "resource URI survives retirement" (Some "masc://selected/resource") state.resource_pending_uri;
  Alcotest.(check (option string)) "Librarian target survives retirement" (Some "librarian-input") state.prompts_librarian_input_requested;
  Alcotest.(check bool) "catalog owner can be restarted" true
    (state.runtime_catalog_reading = Runtime_catalog_unread);
  Alcotest.(check bool) "catalog request retired" true
    (Option.is_none (Local_read_order.settle state.runtime_catalog_order owner ~observed:true));
  Alcotest.(check bool) "context owner released" false state.context_inspector_loading;
  Alcotest.(check (option string)) "context selection retained" (Some "alpha") state.context_inspector_keeper;
  Alcotest.(check (option string)) "schedule owner released" None state.schedule_wake_history_inflight;
  Alcotest.(check (option string)) "schedule selection retained" (Some "schedule-a") state.schedule_detail_id;
  Alcotest.(check (option string)) "patch selection retained" (Some "lib/example.ml") state.patch_modal_path;
  (match state.voice_wizard with
   | Some ({vws_save=Wizard.Save_settled; _} as session) ->
       Alcotest.(check bool) "retired probe cannot populate the wizard" true
         (Option.is_none (Wizard.voice_wizard_after_probe session ~request:7 (Ok ["foreign endpoint"])));
       Alcotest.(check bool) "saved draft is preserved" true (session.vws_draft = opened.vws_draft)
   | _ -> Alcotest.fail "probe still owns the saved wizard")

let test_discarded_bundle_retires_readings_before_reconfirming_a () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let reading = Some state.workspace_read_authority in
  Masc_tui_message_input.insert state.msg_input "retained draft";
  (* The refresh crossed B, but its final probe already sees A again. *)
  let latest = retire_refused_workspace_readings state ~detail:"mixed workspace bundle"
      (Some (Ok (identity "/workspace/a"))) in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
      ~local_base_path:state.local_base_path latest;
  Alcotest.(check bool) "A is confirmed again" true (server_authority_ready state);
  Alcotest.(check bool) "independent B response cannot enter the reconfirmed A screen" false
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation);
  Alcotest.(check bool) "A's admitted operation receipt is retained" true
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_operation_outcome);
  Alcotest.(check string) "draft survives discarded bundle" "retained draft"
    (Masc_tui_message_input.contents state.msg_input)

let test_preset_selection_waits_without_owning_an_unconfirmed_read () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- next_workspace_identity ~previous:Workspace_identity_match
      ~local_base_path:state.local_base_path (Error "health unavailable");
  Alcotest.(check bool) "unconfirmed selection does not start a read" true
    (Option.is_none (begin_preset_detail_read state ~name:"selected-preset"));
  Alcotest.(check bool) "no stuck Loading owner is created" true
    (Option.is_none (Masc_tui_fetched.current_request state.preset_detail));
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "same preset can load once A is confirmed" true
    (Option.is_some (begin_preset_detail_read state ~name:"selected-preset"));
  Alcotest.(check bool) "an admitted read is still deduplicated" true
    (Option.is_none (begin_preset_detail_read state ~name:"selected-preset"))

let test_pending_nested_reader_intents_survive_repeated_suspension () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.msg_target_keeper_name <- Some "alpha";
  state.msg_older_cursor <- Some "server-cursor-42";
  state.msg_older_loading <- true;
  let loading, _ = match Masc_tui_fetched.start ~equal:String.equal state.code_file ~key:"src/a.ml" with
    | Started (reading, request) -> reading, request
    | Already_loading -> Alcotest.fail "unexpected initial file owner" in
  state.code_file <- loading;
  let installer = Masc_tui_lane_installer.browse () in
  let installer = Result.get_ok (Masc_tui_lane_installer.begin_catalog ~request_id:7 ~directory:(Some "packages") installer) in
  state.lane_addons <- Some {state.lane_addons_cached with generation=7; loading=true; installer=Some installer};
  state.lane_addons_reading <- Some 7;
  suspend_workspace_readings state;
  suspend_workspace_readings state;
  Alcotest.(check (option (pair string (option string)))) "older page cursor survives" (Some ("alpha",Some "server-cursor-42")) state.msg_older_resume;
  Alcotest.(check (option string)) "pending file key survives" (Some "src/a.ml") (Masc_tui_fetched.current_key state.code_file);
  Alcotest.(check bool) "package catalog parameters survive" true
    (state.lane_installer_read_resume = Some (7, Masc_tui_lane_installer.Read_catalog (Some "packages")))

let test_task_receipts_wait_for_identity_and_roster () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  let origin = identity "/workspace/a" in
  state.server_identity <- Some origin;
  state.workspace_identity <- Workspace_identity_match_unconfirmed "health timed out";
  let handoff = Task_handoff {keeper="alpha"; task_id="task-9"; title="accepted"; body="body"} in
  let cancelled = Task_cancel_refresh "task-8" in
  remember_task_followup state ~expected_workspace:origin handoff;
  remember_task_followup state ~expected_workspace:origin cancelled;
  let run, withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  Alcotest.(check bool) "no sends or foreign-workspace claims while unconfirmed" true
    (run = [] && withdrawn = [] && List.length state.pending_task_followups = 2);
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  let run, withdrawn = take_task_followups state ~ready:(function
    | Task_handoff _ -> false | Task_cancel_refresh _ -> true) in
  Alcotest.(check bool) "cancel refresh resumes while handoff waits for roster" true
    (run = [cancelled] && withdrawn = [] && List.length state.pending_task_followups = 1);
  let run, withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  Alcotest.(check bool) "same workspace resumes the original handoff" true
    (run = [handoff] && withdrawn = []);
  Alcotest.(check bool) "later refresh cannot send it twice" true
    (take_task_followups state ~ready:(fun _ -> true) = ([], []));
  remember_task_followup state ~expected_workspace:origin handoff;
  state.server_identity <- Some {origin with sid_masc_root="/workspace/other/.masc";
    sid_state_ready=Some false};
  state.workspace_identity <- Workspace_identity_unread;
  let run, withdrawn = take_task_followups state ~ready:(fun _ -> true) in
  Alcotest.(check bool) "booting foreign root withdraws handoff" true
    (run = [] && withdrawn = [handoff]);
  state.server_identity <- Some origin;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "return to A never resurrects withdrawn task" true
    (take_task_followups state ~ready:(fun _ -> true) = ([], []));
  remember_task_followup state ~expected_workspace:origin handoff;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "A-B-A with unchanged final paths still retires original authority" true
    (take_task_followups state ~ready:(fun _ -> true) = ([], [handoff]))

let test_account_read_intents_survive_repeated_suspension () =
  let open Masc_tui_types in
  let module Login = Masc_tui_account_login in
  let provider : Login.provider = {id="codex"; label="Codex"; client=Login.Codex;
    origin=Login.Configured; enabled=true; setup_supported=true} in
  List.iter (fun action ->
    let state = create_state ~workspace:"a" ~port:0 ~refresh_interval:0. () in
    let view = Login.create "codex" in
    view.generation <- 7;
    view.account_ref <- Some "selected-account";
    view.login_id <- Some "selected-session";
    view.provider <- Some provider;
    state.account_login <- Some view;
    state.account_login_readings <- [view, 7, action];
    suspend_workspace_readings state;
    suspend_workspace_readings state;
    Alcotest.(check bool) "exact read survives repeated retirement" true
      (match state.account_login_read_resume with
       | [(pending, generation, saved_action)] ->
           pending == view && generation = 7 && saved_action = action
       | _ -> false);
    Alcotest.(check (option string)) "selected account is preserved"
      (Some "selected-account") view.account_ref;
    Alcotest.(check bool) "selected provider is preserved" true
      (view.provider = Some provider);
    let saving = Login.create "codex" in
    saving.generation <- 8;
    saving.phase <- Login.Saving;
    state.account_login_readings <- [saving, 7, Login.Inventory];
    suspend_workspace_readings state;
    Alcotest.(check bool) "superseded read cannot retire newer mutation" true
      (saving.phase = Login.Saving && saving.generation = 8);
    Alcotest.(check int) "superseded read is not queued" 1
      (List.length state.account_login_read_resume))
    [Login.Inventory; Discover; Recover;
     Preview_removal {provider; refused=Some "retained refusal"}]

let test_unsent_resource_and_log_intents_survive_reconfirmation () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match_unconfirmed "health failed";
  state.resource_content <- Some ("masc://old", []);
  state.resource_scroll <- 12;
  retain_resource_read state ~uri:"masc://new";
  retain_sandbox_log_read state ~keeper_name:"selected-keeper";
  Alcotest.(check bool) "intent does not authorize network reads" false
    (server_authority_ready state);
  Alcotest.(check bool) "new selection cannot display old resource" true
    (state.resource_content = None && state.resource_scroll = 0);
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check (option string)) "resource recovery selects the unsent URI"
    (Some "masc://new") state.resource_pending_uri;
  Alcotest.(check (option string)) "first log open survives without a previous result"
    (Some "selected-keeper") state.keeper_sandbox_logs_requested;
  Alcotest.(check bool) "unsent logs retain their originating workspace" true
    (state.keeper_sandbox_logs_origin = Some (identity "/workspace/a"));
  reconcile_detail_intent_origins state (Ok (identity "/workspace/b"));
  Alcotest.(check (option string)) "foreign workspace cannot inherit unsent logs"
    None state.keeper_sandbox_logs_requested

let test_effect_observations_resume_without_repeating_effects () =
  let open Masc_tui_types in
  let module Browser = Browser_lane_view in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match_unconfirmed "health failed";
  let initial = Browser.create () in
  let prior = {initial with selected_tab=Some 7} in
  state.browser_lane_generation <- 3;
  state.browser_lane <- Some {prior with load=Browser.Failed "observation retired"};
  let gestures = [Browser.Scene_scroll {tab_id=7; document_id="doc";
      expected_url="https://example.test"; scene_view=Browser_lane.Content; scope=None; delta_y=100};
    Browser.Scene_click {tab_id=7; document_id="doc"; node_id="node";
      expected_url="https://example.test"; scope=None}] in
  List.iter (fun gesture ->
    let read = match Browser.observation_after_effect gesture with
      | Some read -> read | None -> Alcotest.fail "effect lost its observation intent" in
    Alcotest.(check bool) "the retry is a read, never the gesture" true
      (Browser.operation_is_read read);
    Alcotest.(check bool) "settled matching effect retains its observation" true
      (retain_operation_observation state (Browser_scene_observation (3, prior, read)));
    suspend_workspace_readings state;
    Alcotest.(check bool) "repeated uncertainty preserves selected scene read" true
      (match state.browser_lane_read_resume with
       | Some (3, _, Browser.Scene_refresh {tab_id=7; _}) -> true | _ -> false)) gestures;
  state.browser_lane_generation <- 4;
  Alcotest.(check bool) "late receipt cannot replace a newer selection" false
    (retain_operation_observation state (Browser_scene_observation (3, prior, Browser.Scene_read 7)));
  let panel = Masc_tui_lane_subscriptions.initial ~keepers:[] ~targets:[] in
  let saved = {Masc_tui_lane_addons.initial with generation=9; loading=false;
    subscription_panel=Some panel} in
  state.lane_addons <- Some saved;
  Alcotest.(check bool) "settled save retains only subscription inspection" true
    (retain_operation_observation state (Lane_subscriptions_observation 9));
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "late save recovery targets open subscriptions panel" true
    (state.lane_nested_read_resume = Some (9, Lane_subscriptions_read));
  state.lane_addons <- Some {saved with generation=10};
  Alcotest.(check bool) "old save cannot replace newer panel read" false
    (retain_operation_observation state (Lane_subscriptions_observation 9))

let test_child_read_epoch_retains_running_audit () =
  let open Masc_tui_types in
  let state=create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority=state.workspace_authority in
  let original_reading=Some state.workspace_read_authority in
  let cached=["alpha",Masc_tui_child_content.empty] in
  state.msg_child_content <- cached;
  state.msg_child_content_inflight <-
    ["alpha",Masc_tui_child_content.Audit;"beta",Masc_tui_child_content.Poll];
  state.msg_child_content_audit_pending <- ["alpha";"gamma"];
  suspend_workspace_readings state;
  Alcotest.(check bool) "all retired Child slots released" true
    (state.msg_child_content_inflight=[]);
  Alcotest.(check bool) "Child snapshots retain physical cache identity" true
    (state.msg_child_content==cached);
  Alcotest.(check (list string)) "running audit coalesces with queued audit; poll is not promoted"
    ["alpha";"gamma"] state.msg_child_content_audit_pending;
  state.workspace_identity <- Workspace_identity_match_unconfirmed "temporary identity failure";
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "repeated suspension retains exact audit intent"
    ["alpha";"gamma"] state.msg_child_content_audit_pending;
  state.workspace_identity <- Workspace_identity_match;
  state.msg_child_content_inflight <- ["alpha",Masc_tui_child_content.Audit];
  Alcotest.(check bool) "retired Child completion cannot own the successor slot" false
    (workspace_reply_admitted state ~authority ~reading:original_reading ~kind:Workspace_observation);
  Alcotest.(check bool) "successor observation is admitted" true
    (workspace_reply_admitted state ~authority ~reading:(Some state.workspace_read_authority)
      ~kind:Workspace_observation);
  state.msg_child_content_audit_pending <- [];
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "a started audit without queued intent is restored"
    ["alpha"] state.msg_child_content_audit_pending

let test_native_task_read_epoch_retirement () =
  let open Masc_tui_types in
  let state=create_state ~workspace:"a" ~local_base_path:"/workspace/a"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity "/workspace/a");
  state.workspace_identity <- Workspace_identity_match;
  let authority=state.workspace_authority in
  let reading=Some state.workspace_read_authority in
  Alcotest.(check bool) "current read completion is admitted" true
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation);
  let cached=["alpha",Masc_tui_native_tasks.empty] in
  state.msg_native_tasks <- cached;
  state.msg_native_tasks_inflight <- ["alpha",Masc_tui_native_tasks.Audit];
  state.msg_native_tasks_audit_pending <- [];
  suspend_workspace_readings state;
  Alcotest.(check bool) "retired native slot releases" true (state.msg_native_tasks_inflight=[]);
  Alcotest.(check bool) "cached task evidence survives" true (state.msg_native_tasks==cached);
  Alcotest.(check (list string)) "manual audit intent survives same workspace suspension"
    ["alpha"] state.msg_native_tasks_audit_pending;
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "repeated retirement retains restored audit"
    ["alpha"] state.msg_native_tasks_audit_pending;
  state.msg_native_tasks_inflight <- ["beta",Masc_tui_native_tasks.Poll];
  suspend_workspace_readings state;
  Alcotest.(check (list string)) "poll is never promoted to audit"
    ["alpha"] state.msg_native_tasks_audit_pending;
  state.msg_native_tasks_inflight <- ["alpha",Masc_tui_native_tasks.Audit];
  Alcotest.(check bool) "old completion cannot release successor slot" false
    (workspace_reply_admitted state ~authority ~reading ~kind:Workspace_observation);
  Alcotest.(check bool) "successor read is admitted" true
    (workspace_reply_admitted state ~authority
       ~reading:(Some state.workspace_read_authority) ~kind:Workspace_observation)

let overview_snapshot health : Masc_tui_types.overview_snapshot =
  { ov_workspace_health = health
  ; ov_keepers = 0
  ; ov_keeper_listing = Masc.Keeper_snapshot_unread.Not_listed
  ; ov_keeper_liveness =
      { klc_active = 0; klc_offline = 0; klc_idle = 0; klc_paused = 0; klc_unreadable = 0 }
  ; ov_mcp_agents = 0
  ; ov_attention_items = []
  ; ov_generated_at = "fixture"
  }

let overview_preview_fixture () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"preview" ~local_base_path:"/workspace/preview"
      ~port:0 ~refresh_interval:0. () in
  let confirmed = overview_snapshot Workspace_health_warning in
  state.overview <- Some confirmed;
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let preview =
    { op_ticket = ticket; op_authority = state.workspace_authority
    ; op_identity = identity state.local_base_path
    ; op_snapshot = overview_snapshot Workspace_health_ok } in
  state, confirmed, preview

let test_overview_preview_rejects_superseded_reading () =
  let open Masc_tui_types in
  let state, _, old = overview_preview_fixture () in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:1L;
  accept_overview_preview state old;
  Alcotest.(check bool) "superseded result leaves the new refresh unread" true
    (state.overview_preview = None);
  let current = { old with op_ticket = ticket } in
  accept_overview_preview state current;
  accept_overview_preview state old;
  Alcotest.(check bool) "late old result cannot replace a current preview" true
    (state.overview_preview = Some current)

let test_overview_preview_preserves_confirmed_state_and_authority () =
  let open Masc_tui_types in
  let state, confirmed, preview = overview_preview_fixture () in
  let authority = state.workspace_authority in
  let identity = state.server_identity and workspace = state.workspace_identity in
  accept_overview_preview state preview;
  Alcotest.(check bool) "current observation is retained" true
    (state.overview_preview = Some preview);
  Alcotest.(check bool) "readonly reading selects the preview data" true
    (overview_refresh_reading state = (None, Some preview.op_snapshot));
  Alcotest.(check bool) "confirmed overview is unchanged" true
    (state.overview = Some confirmed && state.overview_error = None);
  Alcotest.(check bool) "preview grants no workspace or server authority" true
    (state.workspace_authority = authority && state.server_identity = identity
     && state.workspace_identity = workspace)

let test_overview_refresh_finish_retires_preview_and_late_delivery () =
  let open Masc_tui_types in
  let state, confirmed, preview = overview_preview_fixture () in
  accept_overview_preview state preview;
  finish_http_refresh_state state;
  Alcotest.(check bool) "completion retires progress and its observation" true
    (state.http_refresh_started_ns = None && state.overview_preview = None);
  Alcotest.(check bool) "readonly reading returns confirmed data after completion" true
    (overview_refresh_reading state = (None, Some confirmed));
  accept_overview_preview state preview;
  Alcotest.(check bool) "late result cannot revive a completed refresh" true
    (state.overview_preview = None)

let test_overview_preview_refuses_foreign_or_retired_authority () =
  let open Masc_tui_types in
  let state, confirmed, preview = overview_preview_fixture () in
  accept_overview_preview state
    { preview with op_identity = identity "/workspace/foreign" };
  Alcotest.(check bool) "foreign reading cannot enter the preview" true
    (state.overview_preview = None);
  accept_overview_preview state preview;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "retired authority cannot select cached preview data" true
    (overview_refresh_reading state = (None, Some confirmed));
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:1L;
  accept_overview_preview state { preview with op_ticket = ticket };
  Alcotest.(check bool) "current ticket cannot spend retired workspace authority" true
    (state.overview_preview = None)

let early_asks_fixture () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"asks" ~local_base_path:"/workspace/asks"
      ~port:0 ~refresh_interval:0. () in
  state.server_identity <- Some (identity state.local_base_path);
  state.workspace_identity <- Workspace_identity_match;
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let request = match begin_asks_read state with
    | Some request -> request
    | None -> Alcotest.fail "initial question read was refused" in
  let snapshot : Masc.Tui_decode_asks.asks_snapshot =
    { asn_keeper = None; asn_open_count = 1
    ; asn_rows =
        [{ ar_keeper = "alpha"; ar_id = "ask-1"; ar_asked_at = 1.; ar_source_turn_ref = None; ar_context = None
         ; ar_questions =
             [{ aq_id = "q1"; aq_header = "Choice"; aq_prompt = "Continue?"
              ; aq_mode = Masc.Tui_decode_asks.Ask_single
              ; aq_free_text = Masc.Tui_decode_asks.Ask_choices_only
              ; aq_choices = [{ac_id = "yes"; ac_label = "Yes"; ac_description = None}] }]
         ; ar_resolution = Masc.Tui_decode_asks.Ask_open }] } in
  state,
    { ea_ticket = ticket; ea_authority = state.workspace_authority
    ; ea_identity = identity state.local_base_path
    ; ea_observation = { asks_request = request; asks_result = Ok snapshot } }

let test_initial_probe_requires_current_cold_workspace () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  state.server_identity <- None;
  let needs={nothing with needs_board=true} in
  let reads,original=Surface_read_order.dispatch ~kind:Surface_read_order.Full
    ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let planned=board_query state in
  let context=Surface_read_context.capture ~needs ~board_query:planned original in
  state.board_sort <- Board_updated;state.board_hearth <- Some "later-controls";
  let admitted identity = can_admit_initial_http_identity state
      ~ticket:early.ea_ticket ~authority:early.ea_authority identity in
  Alcotest.(check bool) "ready current matching cold probe can hand off" true
    (admitted early.ea_identity);
  Alcotest.(check bool) "offering a probe does not grant workspace authority" true
    (state.workspace_identity = Workspace_identity_unread
     && state.server_identity = None
     && state.workspace_authority = early.ea_authority
     && Snapshot_read.in_flight state.asks_read
     && Surface_read_context.planned_board_query context=Some planned
     && Surface_read_context.current context==original);
  List.iter (fun candidate ->
    Alcotest.(check bool) "foreign incomplete or booting probes cannot hand off" false
      (admitted candidate))
    [ identity "/workspace/foreign"
    ; {early.ea_identity with sid_masc_root = "/workspace/foreign/.masc"}
    ; {early.ea_identity with sid_masc_root = ""}
    ; {early.ea_identity with sid_base_path = ""}
    ; {early.ea_identity with sid_state_ready = Some false}
    ; {early.ea_identity with sid_state_ready = None} ];
  List.iter (fun workspace ->
    state.workspace_identity <- workspace;
    Alcotest.(check bool) "warm suspended and foreign states retain their existing path" false
      (admitted early.ea_identity))
    [Workspace_identity_match; Workspace_identity_match_unconfirmed "unavailable";
     Workspace_identity_mismatch
       {local_base_path=state.local_base_path; server_base_path="/workspace/foreign"}];
  state.workspace_identity <- Workspace_identity_unread;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "old authority cannot confirm a replacement workspace" false
    (admitted early.ea_identity);
  Alcotest.(check bool) "retained context does not grant authority or replace original query with controls" true
    (Surface_read_context.planned_board_query context=Some planned
     && not (board_query_equal planned (board_query state))
     && Surface_read_context.origin context==original)

let test_initial_probe_rejects_retired_refresh () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  let current = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket:current ~started_ns:10L;
  let admitted ticket = can_admit_initial_http_identity state
      ~ticket ~authority:state.workspace_authority early.ea_identity in
  Alcotest.(check bool) "superseded pass cannot hand off" false
    (admitted early.ea_ticket);
  Alcotest.(check bool) "current cold pass remains eligible" true (admitted current);
  finish_http_refresh_state ~finished_ns:20L state;
  Alcotest.(check bool) "finished pass cannot reopen through a delayed probe" false
    (admitted current)

let test_early_asks_apply_once_without_granting_authority () =
  let open Masc_tui_types in
  List.iter (fun result ->
    let state, early = early_asks_fixture () in
    let early = {early with ea_observation =
      {early.ea_observation with asks_result = result early.ea_observation.asks_result}} in
    let authority = state.workspace_authority and server = state.server_identity in
    accept_http_progress state {hp_ticket=early.ea_ticket;hp_authority=authority;
      hp_event=Http_refresh_progress.Started (Surface_data Surface_read_source.Planning,1L)};
    Alcotest.(check bool) "matching early result settles while unrelated data is pending" true
      (take_early_asks_observation state early = Some early.ea_observation.asks_result);
    Alcotest.(check bool) "terminal copy cannot be applied a second time" true
      (take_asks_observation state early.ea_observation = None);
    Alcotest.(check bool) "question result grants no authority and ends only its own request" true
      (state.workspace_authority = authority && state.server_identity = server
       && state.workspace_identity = Workspace_identity_match
       && not (Snapshot_read.in_flight state.asks_read)
       && state.http_refresh_started_ns = Some 0L))
    [Fun.id; (fun _ -> Error "question store unavailable")]

let test_unadmitted_cold_asks_defer_without_consuming_the_read () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  state.server_identity <- None;
  Alcotest.(check bool) "cold start cannot admit early questions" true
    (take_early_asks_observation state early = None);
  finish_http_refresh_state state;
  Alcotest.(check bool) "terminal bundle still owns the unconsumed question read" true
    (take_asks_observation state early.ea_observation = Some early.ea_observation.asks_result)

let test_early_asks_reject_foreign_stale_and_retired_authority () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  let wrong_root = { early.ea_identity with sid_masc_root = "/workspace/foreign/.masc" } in
  Alcotest.(check bool) "same endpoint with a foreign root is refused" true
    (take_early_asks_observation state {early with ea_identity = wrong_root} = None);
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  state.http_refresh_order <- ticket;
  Alcotest.(check bool) "superseded full response cannot admit questions" true
    (take_early_asks_observation state early = None);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "current ticket cannot spend retired workspace authority" true
    (take_early_asks_observation state {early with ea_ticket = ticket} = None);
  let current = {early with ea_ticket = ticket; ea_authority = state.workspace_authority} in
  finish_http_refresh_state state;
  Alcotest.(check bool) "completed full refresh cannot admit late questions" true
    (take_early_asks_observation state current = None)

let test_question_answer_retires_pre_answer_reads () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  begin_ask_submission_state state;
  Alcotest.(check bool) "a pending answer does not start another listing" true
    (begin_asks_read state = None);
  state.ask_submit_inflight <- false;
  let answered : Masc.Tui_decode_asks.asks_snapshot =
    { asn_keeper = None; asn_open_count = 0; asn_rows = [] } in
  state.asks_snapshot <- Some answered;
  Alcotest.(check bool) "delayed early read cannot reopen the answered question" true
    (take_early_asks_observation state early = None);
  let failed = {early with ea_observation =
    {early.ea_observation with asks_result=Error "pre-answer request failed late"}} in
  Alcotest.(check bool) "delayed pre-answer failure cannot settle the post-answer state" true
    (take_early_asks_observation state failed = None);
  Alcotest.(check bool) "terminal bundle cannot replay the pre-answer snapshot" true
    (take_asks_observation state early.ea_observation = None
     && state.asks_snapshot = Some answered);
  let request = match begin_asks_read state with
    | Some request -> request | None -> Alcotest.fail "post-answer read did not resume" in
  Alcotest.(check bool) "a newly dispatched post-answer listing is admitted" true
    (take_asks_observation state {asks_request = request; asks_result = Ok answered}
     = Some (Ok answered))

let test_question_read_supersession_and_workspace_suspension () =
  let open Masc_tui_types in
  let state, early = early_asks_fixture () in
  let request = match begin_asks_read state with
    | Some request -> request | None -> Alcotest.fail "successor listing did not start" in
  Alcotest.(check bool) "newer scoped listing supersedes the full listing" true
    (take_asks_observation state early.ea_observation = None);
  let current = {early.ea_observation with asks_request = request} in
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace suspension retires the current question listing" true
    (take_asks_observation state current = None)

let test_refresh_progress_tracks_independent_sources_and_interruption () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let state = create_state ~workspace:"progress" ~local_base_path:"/workspace/progress"
      ~port:0 ~refresh_interval:0. () in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  let authority = state.workspace_authority in
  let original_identity = state.workspace_identity in
  let needs = {nothing with needs_planning=true; needs_overview_goals=true} in
  let reads, _ = Surface_read_order.dispatch ~kind:Surface_read_order.Full
      ~needs ~started_ns:10_000_000L state.http_surface_reads in
  state.http_surface_reads <- reads;
  begin_http_refresh_state state ~ticket ~started_ns:10_000_000L;
  let deliver hp_event = accept_http_progress state
    { hp_ticket = ticket; hp_authority = authority; hp_event } in
  let progress () = match state.http_refresh_progress with
    | Some (_, progress) -> progress
    | None -> Alcotest.fail "refresh lost its observation" in
  deliver (Progress.Started (Progress.Questions, 20_000_000L));
  deliver (Progress.Started (Progress.Keepers, 30_000_000L));
  let work = Progress.Surface_data Surface_read_order.Planning in
  let goals = Progress.Surface_data Surface_read_order.Overview_goals in
  deliver (Progress.Started (work, 40_000_000L));
  deliver (Progress.Started (goals, 45_000_000L));
  deliver (Progress.Completed (Progress.Questions, 60_000_000L, Progress.Received));
  deliver (Progress.Completed (Progress.Keepers, 70_000_000L, Progress.Received));
  deliver (Progress.Completed (work, 75_000_000L, Progress.Failed));
  Alcotest.(check bool) "a pending Goal read does not hide the failed Work read" true
    (Progress.counts (progress ()) = Progress.{pending=1;received=2;partial=0;failed=1;interrupted=0}
     && Progress.pending_sources (progress ()) = [goals]
     && Progress.settled_sources ~completion:Progress.Failed_read (progress ()) = [work]);
  let settled = state.http_refresh_progress in
  deliver (Progress.Completed (Progress.Questions, 80_000_000L, Progress.Failed));
  deliver (Progress.Completed (work, 80_000_000L, Progress.Received));
  deliver (Progress.Completed (Progress.Overview, 80_000_000L, Progress.Received));
  Alcotest.(check bool) "duplicate and undispatched settlements preserve the actual observation" true
    (state.http_refresh_progress = settled);
  Alcotest.(check bool) "diagnostics never confirm workspace identity or publish data" true
    (state.workspace_identity = original_identity && state.workspace_authority = authority
     && state.overview = None && state.asks_snapshot = None
     && Surface_read_order.pending ~needs state.http_surface_reads
          = [Surface_read_order.Planning;Surface_read_order.Overview_goals]
     && Surface_read_order.pending_scoped ~needs state.http_surface_reads = []);
  finish_http_refresh_state ~finished_ns:100_000_000L state;
  Alcotest.(check bool) "a stopped refresh records its remaining read as interrupted" true
    (Progress.counts (progress ()) = Progress.{pending=0;received=2;partial=0;failed=1;interrupted=1}
     && Progress.settled_sources ~completion:Progress.Interrupted_read (progress ()) = [goals]);
  Alcotest.(check (float 0.)) "total duration uses the same monotonic interval" 90.
    Yojson.Safe.Util.(Progress.to_json (progress ()) |> member "elapsed_ms" |> to_number);
  let finished = state.http_refresh_progress in
  deliver (Progress.Started (Progress.Identity_after, 110_000_000L));
  Alcotest.(check bool) "late diagnostics cannot reopen a completed refresh" true
    (state.http_refresh_progress = finished)

let test_refresh_progress_retains_partial_runtime_receipt () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let state = create_state ~workspace:"partial" ~local_base_path:"/workspace/partial"
      ~port:0 ~refresh_interval:0. () in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  let authority = state.workspace_authority and identity = state.workspace_identity in
  let needs = {nothing with needs_runtime_quota=true} in
  let reads,_ = Surface_read_order.dispatch ~kind:Surface_read_order.Full ~needs
    ~started_ns:10_000_000L state.http_surface_reads in
  state.http_surface_reads <- reads;
  begin_http_refresh_state state ~ticket ~started_ns:10_000_000L;
  let deliver hp_event = accept_http_progress state {hp_ticket=ticket;hp_authority=authority;hp_event} in
  let progress () = match state.http_refresh_progress with
    | Some (_,progress) -> progress | None -> Alcotest.fail "partial receipt was lost" in
  let runtime = Progress.Surface_data Surface_read_order.Runtime_quota in
  let board = Progress.Surface_data Surface_read_order.Board in
  deliver (Progress.Started (runtime,20_000_000L));
  deliver (Progress.Started (board,21_000_000L));
  let partial = Progress.of_runtime_quota (Ok [],Error "usage unavailable") in
  deliver (Progress.Completed (runtime,30_000_000L,partial));
  Alcotest.(check bool) "partial reader is neither full success nor total failure" true
    (Progress.counts (progress ())=Progress.{pending=1;received=0;partial=1;failed=0;interrupted=0}
     && Progress.settled_sources ~completion:Progress.Partial (progress ())=[runtime]);
  (match Progress.partial_readings (progress ()) with
   | [(_,parts)] -> Alcotest.(check bool) "both actual component outcomes remain joined" true
       (Progress.components parts=[Progress.Runtime_catalogue,Progress.Part_received;
                                  Progress.Provider_windows,Progress.Part_failed])
   | readings -> Alcotest.failf "expected one partial reader, got %d" (List.length readings));
  let json = Progress.to_json (progress ()) in
  let runtime_json = List.hd Yojson.Safe.Util.(json |> member "sources" |> to_list) in
  Alcotest.(check string) "diagnostic protocol retains partial completion" "partial"
    Yojson.Safe.Util.(runtime_json |> member "status" |> to_string);
  let components = Yojson.Safe.Util.(runtime_json |> member "components" |> to_list) in
  let component_status component =
    let name = Progress.component_name component in
    List.find_map (fun fields -> if Yojson.Safe.Util.member "component" fields=`String name
      then Some (Yojson.Safe.Util.member "status" fields) else None) components in
  Alcotest.(check bool) "serialized component receipts retain which result succeeded and failed" true
    (component_status Progress.Runtime_catalogue=Some (`String "received")
     && component_status Progress.Provider_windows=Some (`String "failed"));
  Alcotest.(check bool) "component receipts do not invent separate completion clocks" true
    (List.for_all (fun component -> Yojson.Safe.Util.member "elapsed_ms" component=`Null) components);
  Alcotest.(check bool) "diagnostics do not authorize a workspace or settle dataset ownership" true
    (state.workspace_identity=identity && state.runtime_catalog=[]
     && Surface_read_order.pending ~needs state.http_surface_reads=[Surface_read_order.Runtime_quota]);
  let original = state.http_refresh_progress in
  deliver (Progress.Completed (runtime,35_000_000L,Progress.Received));
  Alcotest.(check bool) "a duplicate receipt cannot replace observed partial evidence" true
    (state.http_refresh_progress=original);
  finish_http_refresh_state ~finished_ns:40_000_000L state;
  Alcotest.(check bool) "unfinished sibling is interrupted while the partial receipt survives" true
    (Progress.counts (progress ())=Progress.{pending=0;received=0;partial=1;failed=0;interrupted=1}
     && Progress.settled_sources ~completion:Progress.Interrupted_read (progress ())=[board])

let test_composed_refresh_receipts_preserve_all_availability_cases () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let runtime = Progress.Surface_data Surface_read_order.Runtime_quota
  and board = Progress.Surface_data Surface_read_order.Board in
  let cases =
    [runtime,Progress.of_runtime_quota (Ok (),Ok ()),Progress.Complete;
     runtime,Progress.of_runtime_quota (Ok (),Error "usage"),Progress.Partial;
     runtime,Progress.of_runtime_quota (Error "catalogue",Ok ()),Progress.Partial;
     runtime,Progress.of_runtime_quota (Error "catalogue",Error "usage"),Progress.Failed_read;
     board,Progress.of_board (Ok (),Ok ()),Progress.Complete;
     board,Progress.of_board (Ok (),Error "hearths"),Progress.Partial;
     board,Progress.of_board (Error "posts",Ok ()),Progress.Partial;
     board,Progress.of_board (Error "posts",Error "hearths"),Progress.Failed_read;
     Progress.Keepers,Progress.of_keeper_roster (Ok ((),Ok ())),Progress.Complete;
     Progress.Keepers,Progress.of_keeper_roster (Ok ((),Error "Candle")),Progress.Partial;
     Progress.Keepers,Progress.of_keeper_roster (Error "roster unavailable"),Progress.Failed_read] in
  List.iter (fun (source,outcome,expected) ->
    let reading = Progress.start ~started_ns:1L
      |> fun state -> Progress.observe state (Progress.Started (source,2L))
      |> fun state -> Progress.observe state (Progress.Completed (source,3L,outcome))
      |> Progress.finish ~finished_ns:4L in
    Alcotest.(check bool) "logical reader preserves the composed availability verdict" true
      (Progress.settled_sources ~completion:expected reading=[source]);
    Alcotest.(check bool) "component evidence exists only when the producer returned those results" true
      (match outcome with
       | Progress.Composed parts -> List.length (Progress.components parts)=2
       | Progress.Failed -> source=Progress.Keepers
       | Progress.Received | Progress.Interrupted -> false)) cases

let test_board_child_receipts_survive_parent_interruption () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let state = create_state ~workspace:"board-progress" ~local_base_path:"/workspace/board-progress"
      ~port:0 ~refresh_interval:0. () in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  let authority=state.workspace_authority and identity=state.workspace_identity in
  let needs={nothing with needs_board=true} in
  let reads,_=Surface_read_order.dispatch ~kind:Surface_read_order.Full ~needs
      ~started_ns:1_000_000L state.http_surface_reads in
  state.http_surface_reads <- reads;
  begin_http_refresh_state state ~ticket ~started_ns:1_000_000L;
  let inbox=state.http_refresh_progress_events in
  let publish hp_event=publish_http_progress inbox {hp_ticket=ticket;hp_authority=authority;hp_event} in
  let progress ()=match state.http_refresh_progress with
    | Some (_,progress) -> progress | None -> Alcotest.fail "missing Board observation" in
  let board=Progress.Surface_data Surface_read_source.Board in
  publish (Progress.Started (board,2_000_000L));
  publish (Progress.Component_started (Progress.Board_posts,3_000_000L));
  publish (Progress.Component_started (Progress.Board_hearths,4_000_000L));
  publish (Progress.Component_completed (Progress.Board_posts,8_000_000L,
    Progress.Component_returned Progress.Part_received));
  Alcotest.(check bool) "producer publication does not mutate UI state" true
    ((progress ()).readings=[]);
  ignore (drain_http_progress state);
  let parts=Progress.unreturned_component_reads (progress ()) in
  Alcotest.(check bool) "completed child is observable while sibling and parent are pending" true
    (List.map (fun part -> part.Progress.cr_component,part.cr_status) parts=
      [Progress.Board_posts,Progress.Component_settled (8_000_000L,
         Progress.Component_returned Progress.Part_received);
       Progress.Board_hearths,Progress.Component_pending]
     && Progress.pending_sources (progress ())=[board]);
  publish (Progress.Component_completed (Progress.Board_posts,9_000_000L,Progress.Component_exception));
  publish (Progress.Component_started (Progress.Board_posts,9_000_000L));
  (* Terminal application must recover pending receipts before interrupting the
     remaining child, even when no ordinary mailbox notification was delivered. *)
  finish_http_refresh_state ~finished_ns:12_000_000L state;
  let reading=List.hd (progress ()).readings in
  Alcotest.(check bool) "interrupted parent retains original success without inventing sibling cancellation" true
    (reading.status=Progress.Settled {finished_ns=12_000_000L;outcome=Progress.Interrupted}
     && List.map (fun part -> part.Progress.cr_status) reading.component_reads=
       [Progress.Component_settled (8_000_000L,Progress.Component_returned Progress.Part_received);
        Progress.Component_settled (12_000_000L,Progress.Component_unfinished)]
     && Progress.counts (progress ())=Progress.{pending=0;received=0;partial=0;failed=0;interrupted=1});
  let source=List.hd Yojson.Safe.Util.(Progress.to_json (progress ()) |> member "sources" |> to_list) in
  let components=Yojson.Safe.Util.(source |> member "components" |> to_list) in
  Alcotest.(check bool) "child protocol retains receipt interval and unfinished observation boundary" true
    (List.map (fun part -> Yojson.Safe.Util.member "status" part) components=
       [`String "received";`String "unfinished"]
     && List.map (fun part -> Yojson.Safe.Util.member "elapsed_ms" part) components=
       [`Float 5.;`Float 8.]);
  Alcotest.(check bool) "child evidence does not settle Board data or workspace identity" true
    (state.workspace_identity=identity && state.workspace_authority=authority
     && Surface_read_order.pending ~needs state.http_surface_reads=[Surface_read_order.Board]);
  let ended=state.http_refresh_progress in
  publish (Progress.Component_completed (Progress.Board_hearths,13_000_000L,
    Progress.Component_returned Progress.Part_received));
  ignore (drain_http_progress state);
  Alcotest.(check bool) "late child cannot reopen finished refresh" true (state.http_refresh_progress=ended)

let test_board_component_receipts_keep_parent_category () =
  let open Masc_tui_types in
  let module Progress=Http_refresh_progress in
  let board=Progress.Surface_data Surface_read_source.Board in
  List.iter (fun (posts,hearths) ->
    let progress=Progress.start ~started_ns:0L in
    let progress=List.fold_left Progress.observe progress
      [Progress.Started (board,1L);
       Progress.Component_completed (Progress.Board_posts,2L,Progress.Component_exception);
       Progress.Component_started (Progress.Runtime_catalogue,2L);
       Progress.Component_started (Progress.Board_posts,3L);
       Progress.Component_started (Progress.Board_hearths,4L);
       Progress.Component_completed (Progress.Board_hearths,6L,
         Progress.Component_returned (Progress.part_of_result hearths));
       Progress.Component_completed (Progress.Board_posts,8L,
         Progress.Component_returned (Progress.part_of_result posts));
       Progress.Completed (board,10L,Progress.of_board (posts,hearths))] in
    let reading=List.hd progress.readings in
    Alcotest.(check bool) "child evidence preserves all parent availability decisions" true
      (reading.status=Progress.Settled {finished_ns=10L;outcome=Progress.of_board (posts,hearths)}
       && List.map (fun part -> part.Progress.cr_component,part.cr_status) reading.component_reads=
         [Progress.Board_posts,Progress.Component_settled (8L,
            Progress.Component_returned (Progress.part_of_result posts));
          Progress.Board_hearths,Progress.Component_settled (6L,
            Progress.Component_returned (Progress.part_of_result hearths))]
       && Progress.unreturned_component_reads progress=[]))
    [Ok (),Ok ();Ok (),Error "hearths";Error "posts",Ok ();Error "posts",Error "hearths"];
  let interrupted=List.fold_left Progress.observe (Progress.start ~started_ns:0L)
    [Progress.Started (board,1L);
     Progress.Component_started (Progress.Board_posts,2L);
     Progress.Component_started (Progress.Board_hearths,3L);
     Progress.Component_completed (Progress.Board_posts,4L,Progress.Component_exception);
     Progress.Component_completed (Progress.Board_hearths,5L,Progress.Component_interrupted);
     Progress.Completed (board,6L,Progress.Failed)] in
  Alcotest.(check bool) "actual child failure and cancellation survive a failed parent" true
    (List.map (fun part -> part.Progress.cr_status) (List.hd interrupted.readings).component_reads=
      [Progress.Component_settled (4L,Progress.Component_exception);
       Progress.Component_settled (5L,Progress.Component_interrupted)])

let test_progress_inbox_cannot_cross_refresh_or_workspace () =
  let open Masc_tui_types in
  let module Progress=Http_refresh_progress in
  let state=create_state ~workspace:"inbox" ~local_base_path:"/workspace/inbox"
    ~port:0 ~refresh_interval:0. () in
  let first=Http_refresh_order.dispatch state.http_refresh_order in
  let authority=state.workspace_authority in
  begin_http_refresh_state state ~ticket:first ~started_ns:0L;
  let retired=state.http_refresh_progress_events in
  let next=Http_refresh_order.dispatch first in
  begin_http_refresh_state state ~ticket:next ~started_ns:10L;
  let original=state.http_refresh_progress in
  let board=Progress.Surface_data Surface_read_source.Board in
  publish_http_progress retired {hp_ticket=first;hp_authority=authority;
    hp_event=Progress.Started (board,11L)};
  publish_http_progress state.http_refresh_progress_events {hp_ticket=first;hp_authority=authority;
    hp_event=Progress.Component_started (Progress.Board_posts,12L)};
  ignore (drain_http_progress state);
  Alcotest.(check bool) "retired inbox and stale ticket cannot spend successor request" true
    (state.http_refresh_progress=original && Atomic.get state.http_refresh_progress_events=[]);
  publish_http_progress state.http_refresh_progress_events {hp_ticket=next;hp_authority=authority;
    hp_event=Progress.Started (board,13L)};
  let Workspace_authority generation=authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  ignore (drain_http_progress state);
  Alcotest.(check bool) "queued event cannot acquire replacement workspace authority" true
    (state.http_refresh_progress=original)

let test_refresh_progress_rejects_old_request_and_workspace () =
  let open Masc_tui_types in
  let module Progress = Http_refresh_progress in
  let state = create_state ~workspace:"progress" ~local_base_path:"/workspace/progress"
      ~port:0 ~refresh_interval:0. () in
  let old_ticket = Http_refresh_order.dispatch state.http_refresh_order in
  let authority = state.workspace_authority in
  begin_http_refresh_state state ~ticket:old_ticket ~started_ns:0L;
  let ticket = Http_refresh_order.dispatch old_ticket in
  begin_http_refresh_state state ~ticket ~started_ns:10L;
  let untouched = state.http_refresh_progress in
  accept_http_progress state { hp_ticket = old_ticket; hp_authority = authority;
    hp_event = Progress.Started (Progress.Questions, 20L) };
  Alcotest.(check bool) "superseded request cannot add a source" true
    (state.http_refresh_progress = untouched);
  let Workspace_authority generation = authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  accept_http_progress state { hp_ticket = ticket; hp_authority = authority;
    hp_event = Progress.Started (Progress.Questions, 30L) };
  accept_http_progress state { hp_ticket = ticket; hp_authority = state.workspace_authority;
    hp_event = Progress.Started (Progress.Questions, 40L) };
  Alcotest.(check bool) "neither retired nor replacement authority can spend the old read" true
    (state.http_refresh_progress = untouched)

let early_roster_fixture () =
  let open Masc_tui_types in
  let base = "/workspace/early-roster" in
  let state = create_state ~workspace:"early-roster" ~local_base_path:base
      ~port:0 ~refresh_interval:0. () in
  let server = identity base in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some server;
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let request = match begin_keeper_roster_read state with
    | Some request -> request | None -> Alcotest.fail "roster read did not start" in
  state,
  { er_ticket=ticket; er_authority=state.workspace_authority; er_identity=server;
    er_observation={roster_request=request;
      roster_result=Ok (Masc_tui_keeper_control.Roster_complete [],Error "Candle unavailable")} }

let test_early_roster_settles_before_slow_siblings_once () =
  let open Masc_tui_types in
  let state,early = early_roster_fixture () in
  let authority=state.workspace_authority and server=state.server_identity in
  accept_http_progress state {hp_ticket=early.er_ticket;hp_authority=authority;
    hp_event=Http_refresh_progress.Started (Surface_data Surface_read_source.Planning,1L)};
  Alcotest.(check bool) "verified roster is usable while another reader is pending" true
    (take_early_keeper_roster_observation state early = Some early.er_observation.roster_result);
  Alcotest.(check bool) "early delivery neither ends refresh nor confirms new authority" true
    (state.http_refresh_started_ns=Some 0L && state.workspace_authority=authority
     && state.server_identity=server);
  Alcotest.(check bool) "terminal copy cannot replay roster or dependent refresh" true
    (take_keeper_roster_observation state early.er_observation=None);
  let state,early = early_roster_fixture () in
  state.workspace_identity <- Workspace_identity_unread;
  state.server_identity <- None;
  Alcotest.(check bool) "cold start retains final identity admission" true
    (take_early_keeper_roster_observation state early=None);
  finish_http_refresh_state state;
  Alcotest.(check bool) "cold start's terminal bundle still owns its read" true
    (take_keeper_roster_observation state early.er_observation=Some early.er_observation.roster_result)

let test_early_roster_preserves_read_ownership () =
  let open Masc_tui_types in
  let state,early = early_roster_fixture () in
  let foreign={early.er_identity with sid_masc_root="/workspace/foreign/.masc"} in
  Alcotest.(check bool) "foreign endpoint cannot admit roster" true
    (take_early_keeper_roster_observation state {early with er_identity=foreign}=None);
  let failure={early.er_observation with
    roster_result=Error (Masc_tui_keeper_control.Roster_unreachable "unreachable")} in
  Alcotest.(check bool) "a foreign failure cannot retire the current roster" true
    (take_early_keeper_roster_observation state
       {early with er_identity=foreign;er_observation=failure}=None
     && Snapshot_read.in_flight state.keeper_roster_read);
  Alcotest.(check bool) "owned failure settles without waiting for the full refresh" true
    (take_early_keeper_roster_observation state {early with er_observation=failure}
       =Some failure.roster_result
     && not (Snapshot_read.in_flight state.keeper_roster_read)
     && state.http_refresh_started_ns=Some 0L);
  Alcotest.(check bool) "terminal failure no longer owns a roster reading" true
    (take_keeper_roster_observation state failure=None);
  let successor=match begin_keeper_roster_read state with
    | Some request -> request | None -> Alcotest.fail "successor roster did not start" in
  Alcotest.(check bool) "newer scoped roster supersedes the old full copy" true
    (take_early_keeper_roster_observation state early=None
     && take_early_keeper_roster_observation state {early with er_observation=failure}=None
     && take_keeper_roster_observation state early.er_observation=None
     && Snapshot_read.in_flight state.keeper_roster_read);
  let newer={early.er_observation with roster_request=successor} in
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace suspension retires the successor too" true
    (take_keeper_roster_observation state newer=None);
  let state,early = early_roster_fixture () in
  state.http_refresh_order <- Http_refresh_order.dispatch state.http_refresh_order;
  Alcotest.(check bool) "superseded full refresh cannot publish a roster" true
    (take_early_keeper_roster_observation state early=None);
  let state,early = early_roster_fixture () in
  let Workspace_authority generation=state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  Alcotest.(check bool) "retired workspace cannot publish a roster" true
    (take_early_keeper_roster_observation state early=None)

let local_workspace_request_exn state source at =
  match Masc_tui_types.begin_local_workspace_read state ~intent:Masc_tui_types.Snapshot_read.Poll ~source
          ~base_path:state.Masc_tui_types.local_base_path ~started_ns:at with
  | Some request -> request
  | None -> Alcotest.fail "local workspace read did not start"

let test_local_read_and_http_sources_progress_independently () =
  let open Masc_tui_types in
  let state, early = early_roster_fixture () in
  let request = local_workspace_request_exn state Local_work 5L in
  Alcotest.(check bool) "cadence cannot duplicate the local worker" true
    (begin_local_workspace_read state ~intent:Snapshot_read.Poll ~source:Local_work ~base_path:state.local_base_path ~started_ns:6L = None);
  Alcotest.(check bool) "local pending does not gate HTTP source admission" true
    (Option.is_some (take_early_keeper_roster_observation state early)
     && Local_read_order.in_flight state.local_workspace_read_order);
  let reading : Masc_tui_loader.local_reading =
    { lr_agents = []; lr_rows = Masc_tui_overview_tasks.Rows_read []
    ; lr_tasks_domain = []; lr_tasks_error = None; lr_task_flow = None
    ; lr_operator_stalled = Masc_tui_agenda.Read []; lr_goal_task_links = Goal_links_not_read
    ; lr_goals_to_confirm = Masc_tui_agenda.Read [] } in
  (match take_local_workspace_read state ~source:Local_work request (Ok reading) with
   | Some (Ok observed) -> Masc_tui_loader.apply_local_workspace state observed
   | Some (Error _) | None -> Alcotest.fail "current local result was not admitted");
  Alcotest.(check bool) "local observation lands before enclosing collector completes" true
    (state.local_workspace = Local_workspace_read && state.http_refresh_started_ns = Some 0L);
  Alcotest.(check bool) "duplicate completion cannot apply again" true
    (take_local_workspace_read state ~source:Local_work request (Ok reading) = None)

let test_local_read_refuses_retired_epoch_and_wrong_path () =
  let open Masc_tui_types in
  let state, _ = early_roster_fixture () in
  let old = local_workspace_request_exn state Local_work 5L in
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  let current = local_workspace_request_exn state Local_work 7L in
  Alcotest.(check bool) "same path after suspension cannot accept the old epoch" true
    (take_local_workspace_read state ~source:Local_work old (Error "old failure") = None
     && Local_read_order.in_flight state.local_workspace_read_order
     && state.local_workspace = Local_workspace_unread);
  let wrong_path = { current with lwr_base_path = "/workspace/foreign" } in
  Alcotest.(check bool) "foreign path cannot settle the successor slot" true
    (take_local_workspace_read state ~source:Local_work wrong_path (Ok ()) = None);
  let Workspace_authority generation = state.workspace_authority in
  let wrong_epoch = { current with lwr_authority = Workspace_authority (generation + 1) } in
  Alcotest.(check bool) "foreign authority cannot spend a matching path and request" true
    (take_local_workspace_read state ~source:Local_work wrong_epoch (Ok ()) = None);
  Alcotest.(check bool) "only the successor can settle" true
    (take_local_workspace_read state ~source:Local_work current (Ok ()) = Some (Ok ()))

let test_local_read_failure_settles_and_can_be_retried () =
  let open Masc_tui_types in
  let state, _ = early_roster_fixture () in
  let request = local_workspace_request_exn state Local_work 5L in
  Alcotest.(check bool) "owned failure is observed" true
    (take_local_workspace_read state ~source:Local_work request (Error "directory unavailable") = Some (Error "directory unavailable"));
  Alcotest.(check bool) "failure is distinct from unread or empty and releases its slot" true
    (state.local_workspace = Local_workspace_failed "directory unavailable"
     && not (Local_read_order.in_flight state.local_workspace_read_order)
     && local_rows_page state ~error:None = Page_failed);
  let retry = local_workspace_request_exn state Local_work 7L in
  Alcotest.(check bool) "late failed attempt cannot release the retry" true
    (take_local_workspace_read state ~source:Local_work request (Error "late failure") = None
     && Local_read_order.in_flight state.local_workspace_read_order);
  Alcotest.(check bool) "fresh retry can settle" true
    (take_local_workspace_read state ~source:Local_work retry (Ok ()) = Some (Ok ()))

let local_keeper_source_fixture () =
  let state, _ = early_roster_fixture () in
  let keeper : Masc_tui_types.keeper =
    { k_origin = Masc.Tui_decode.Persisted_keeper; k_name = "alpha"; k_paused = false
    ; k_identity = Ok { k_trace_id = "local-keeper-source"; k_created_at = "fixture"; k_updated_at = "fixture" }
    ; k_activity = None } in
  let metadata : Masc_tui_loader.local_keeper_reading =
    { lkr_keepers = [ keeper ]; lkr_error = None } in
  state, keeper, metadata

let apply_metadata_observation state request metadata =
  match Masc_tui_types.take_local_workspace_read state ~source:Local_keepers request (Ok metadata) with
  | Some (Ok observed) -> Masc_tui_loader.apply_local_keepers state observed
  | Some (Error _) | None -> Alcotest.fail "metadata observation was not admitted"

let request_local_refresh state source at =
  Masc_tui_types.begin_local_workspace_read state ~intent:Masc_tui_types.Snapshot_read.Refresh
    ~source ~base_path:state.Masc_tui_types.local_base_path ~started_ns:at

let test_local_refresh_burst_keeps_active_read_and_one_followup () =
  let open Masc_tui_types in
  let state, _, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  let active = local_workspace_request_exn state Local_keepers 1L in
  let work = local_workspace_request_exn state Local_work 2L in
  let old_token = ref () and new_token = ref () in
  let cancelled = ref 0 in
  supersede_local_source_read state Local_keepers (Some (old_token, fun () -> incr cancelled));
  List.iter (fun at -> Alcotest.(check bool) "refresh burst shares the active read" true
      (request_local_refresh state Local_keepers at = None)) [3L; 4L; 5L];
  let required = Local_read_order.demanded_revision state.local_keeper_read_order in
  Alcotest.(check int) "coalescing did not cancel active work" 0 !cancelled;
  apply_metadata_observation state active metadata;
  Alcotest.(check bool) "completion publishes observation but does not consume newer demand" true
    (Local_read_order.has_followup state.local_keeper_read_order
     && not (Local_read_order.covers state.local_keeper_read_order required));
  finish_local_source_read state Local_keepers old_token;
  let followup = local_workspace_request_exn state Local_keepers 6L in
  Alcotest.(check bool) "one followup carries refresh provenance" true
    (followup.lwr_intent = Snapshot_read.Refresh
     && not (Local_read_order.has_followup state.local_keeper_read_order));
  supersede_local_source_read state Local_keepers (Some (new_token, fun () -> incr cancelled));
  finish_local_source_read state Local_keepers old_token;
  Alcotest.(check bool) "old cleanup cannot clear followup cancellation owner" true
    (match local_source_cancellation state Local_keepers with
     | Some (held, _) -> held == new_token
     | None -> false);
  Alcotest.(check bool) "duplicate earlier result cannot settle the followup" true
    (take_local_workspace_read state ~source:Local_keepers active (Error "duplicate") = None
     && Local_read_order.in_flight state.local_keeper_read_order);
  apply_metadata_observation state followup metadata;
  Alcotest.(check bool) "followup covers the accumulated burst" true
    (Local_read_order.covers state.local_keeper_read_order required
     && not (Local_read_order.has_followup state.local_keeper_read_order));
  Alcotest.(check bool) "optional Work kept its own active request" true
    (take_local_workspace_read state ~source:Local_work work (Ok ()) = Some (Ok ()))

let test_created_keeper_waits_for_owned_metadata_without_work () =
  let open Masc_tui_types in
  List.iter (fun include_created ->
  let state, keeper, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  let created = {keeper with k_name = "created"} in
  state.view <- Keepers Keeper_message;
  state.msg_target_keeper_name <- Some created.k_name;
  Masc_tui_message_input.insert state.msg_input "draft entered after creation";
  let work = local_workspace_request_exn state Local_work 1L in
  let before_creation = local_workspace_request_exn state Local_keepers 2L in
  ignore (request_local_refresh state Local_keepers 3L);
  wait_for_created_keeper_metadata state created.k_name;
  (* Even an older read that happens to observe the new name does not prove
     that the creation's requested refresh has completed. *)
  apply_metadata_observation state before_creation
    (if include_created then {metadata with lkr_keepers = [keeper; created]} else metadata);
  Alcotest.(check bool) "older metadata cannot admit creation input" false
    (keeper_available_for_new_message state created.k_name);
  Alcotest.(check bool) "older absence cannot close the pending created chat" true
    (state.view = Keepers Keeper_message && state.msg_target_keeper_name = Some created.k_name);
  let after_creation = local_workspace_request_exn state Local_keepers 4L in
  apply_metadata_observation state after_creation {metadata with lkr_keepers = [keeper; created]};
  Alcotest.(check bool) "created Keeper is available without optional Work" true
    (keeper_available_for_new_message state created.k_name
     && Local_read_order.in_flight state.local_workspace_read_order);
  Alcotest.(check string) "creation refresh retained draft"
    "draft entered after creation" (Masc_tui_message_input.contents state.msg_input);
  ignore (take_local_workspace_read state ~source:Local_work work (Error "optional work unavailable"));
  Alcotest.(check bool) "Work failure cannot revoke creation coverage" true
    (keeper_available_for_new_message state created.k_name)) [false; true]

let test_deleted_keeper_reconciles_after_fresh_metadata () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  let survivor = {keeper with k_name = "survivor"} in
  Masc_tui_loader.apply_local_keepers state {metadata with lkr_keepers = [keeper; survivor]};
  state.view <- Keepers Keeper_detail;
  state.keeper_cursor <- 0;
  Masc_tui_message_input.insert state.msg_input "retained draft";
  let old = local_workspace_request_exn state Local_keepers 1L in
  ignore (request_local_refresh state Local_keepers 2L);
  apply_metadata_observation state old {metadata with lkr_keepers = [keeper; survivor]};
  let fresh = local_workspace_request_exn state Local_keepers 3L in
  apply_metadata_observation state fresh {metadata with lkr_keepers = [survivor]};
  Alcotest.(check bool) "confirmed deletion leaves removed detail without retargeting it" true
    (state.view = Keepers Keeper_list && state.keepers = [survivor]
     && not (keeper_available_for_new_message state keeper.k_name));
  Alcotest.(check bool) "late older rows cannot restore deleted Keeper" true
    (take_local_workspace_read state ~source:Local_keepers old (Ok metadata) = None);
  Alcotest.(check string) "reconciliation retains draft"
    "retained draft" (Masc_tui_message_input.contents state.msg_input)

let test_concurrent_created_keepers_retain_individual_refresh_coverage () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  let first = {keeper with k_name = "first"} and second = {keeper with k_name = "second"} in
  let first_read = match request_local_refresh state Local_keepers 1L with
    | Some request -> request
    | None -> Alcotest.fail "first creation refresh did not start" in
  wait_for_created_keeper_metadata state first.k_name;
  ignore (request_local_refresh state Local_keepers 2L);
  wait_for_created_keeper_metadata state second.k_name;
  let observed = {metadata with lkr_keepers = [keeper; first; second]} in
  apply_metadata_observation state first_read observed;
  Alcotest.(check bool) "first creation can proceed on its completed refresh" true
    (keeper_available_for_new_message state first.k_name);
  Alcotest.(check bool) "second creation retains its own later barrier" false
    (keeper_available_for_new_message state second.k_name);
  let followup = local_workspace_request_exn state Local_keepers 3L in
  apply_metadata_observation state followup observed;
  Alcotest.(check bool) "one followup covers both creation waiters" true
    (keeper_available_for_new_message state first.k_name
     && keeper_available_for_new_message state second.k_name)

let test_failed_read_keeps_followup_and_withdrawal_retires_it () =
  let open Masc_tui_types in
  let state, _, _ = local_keeper_source_fixture () in
  let active = local_workspace_request_exn state Local_work 1L in
  ignore (request_local_refresh state Local_work 2L);
  ignore (take_local_workspace_read state ~source:Local_work active (Error "read failed"));
  Alcotest.(check bool) "owned failure leaves accumulated demand eligible" true
    (state.local_workspace = Local_workspace_failed "read failed"
     && Local_read_order.has_followup state.local_workspace_read_order);
  let followup = local_workspace_request_exn state Local_work 3L in
  ignore (request_local_refresh state Local_work 4L);
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "withdrawal retires active read and queued demand" true
    (not (Local_read_order.has_followup state.local_workspace_read_order)
     && take_local_workspace_read state ~source:Local_work followup (Ok ()) = None);
  let resumed = local_workspace_request_exn state Local_work 5L in
  Alcotest.(check bool) "reconfirmed workspace can observe a new source read" true
    (take_local_workspace_read state ~source:Local_work resumed (Ok ()) = Some (Ok ()))

let test_archive_cache_does_not_cross_equal_stat_files () =
  let first = Filename.temp_file "tui-archive-source-a-" ".json" in
  let second = Filename.temp_file "tui-archive-source-b-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove first; Sys.remove second) (fun () ->
    let write path contents =
      let channel = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out_noerr channel)
        (fun () -> output_string channel contents) in
    let first_json = "{\"tasks\":[0]}" and second_json = "{\"tasks\":[]}" in
    write first first_json;
    write second (second_json ^ String.make (String.length first_json - String.length second_json) ' ');
    let stamp = (Unix.stat first).Unix.st_mtime in
    Unix.utimes first stamp stamp;
    Unix.utimes second stamp stamp;
    Alcotest.(check bool) "distinct archive files have equal cache stat keys" true
      ((Unix.stat first).Unix.st_size = (Unix.stat second).Unix.st_size
       && Float.equal (Unix.stat first).Unix.st_mtime (Unix.stat second).Unix.st_mtime);
    let undecoded path = match Masc_tui_loader.read_archived_tasks path with
      | Ok (_, undecoded) -> undecoded
      | Error detail -> Alcotest.fail detail in
    Alcotest.(check int) "first archive retains invalid-row evidence" 1 (undecoded first);
    Alcotest.(check int) "second path cannot reuse first archive evidence" 0 (undecoded second))

let test_local_cache_cancel_releases_source_for_followup () =
  let exception Read_replaced in
  Eio_main.run (fun _env ->
    let mutex = Eio.Mutex.create () in
    let entered, signal_entered = Eio.Promise.create () in
    let finished, signal_finished = Eio.Promise.create () in
    let blocked, _unblock = Eio.Promise.create () in
    let cancellation = ref None and propagated = ref false in
    Eio.Switch.run (fun sw ->
      Eio.Fiber.fork ~sw (fun () ->
        (try Eio.Cancel.sub (fun context ->
           cancellation := Some context;
           Masc_tui_loader.with_local_read_mutex mutex (fun () ->
             Eio.Promise.resolve signal_entered ();
             Eio.Promise.await blocked))
         with Eio.Cancel.Cancelled Read_replaced -> propagated := true);
        Eio.Promise.resolve signal_finished ());
      Eio.Promise.await entered;
      (match !cancellation with
       | None -> Alcotest.fail "reader never owned a cancellation scope"
       | Some context -> Eio.Cancel.cancel context Read_replaced);
      Eio.Promise.await finished;
      Alcotest.(check bool) "original cancellation propagated" true !propagated;
      let seen_failure =
        try
          Masc_tui_loader.with_local_read_mutex mutex
            (fun () -> (raise (Sys_error "source failure") : unit));
          false
        with Sys_error _ -> true in
      Alcotest.(check bool) "read failure is still observable" true seen_failure;
      let next = Masc_tui_loader.with_local_read_mutex mutex (fun () -> 42) in
      Alcotest.(check int) "later source reader can use the released cache resource" 42 next))

let start_live_context_exn state keeper =
  match Masc_tui_context_state.start state.Masc_tui_types.live_context
          ~key:(Masc_tui_types.live_context_key state keeper) with
  | Masc_tui_context_state.Started (next, request) -> state.live_context <- next; request
  | Masc_tui_context_state.Already_loading -> Alcotest.fail "context request already pending"

let live_context_fixture () =
  let state, keeper, metadata = local_keeper_source_fixture () in
  Masc_tui_loader.apply_local_keepers state metadata;
  state.view <- Masc_tui_types.Keepers Keeper_detail;
  state.keeper_cursor <- 0;
  state, keeper

let test_live_context_refuses_changed_trace_before_reconciliation () =
  let open Masc_tui_types in
  let state, keeper = live_context_fixture () in
  let old = start_live_context_exn state keeper in
  let current = { keeper with k_identity =
      Result.map (fun (identity : Tui_decode.keeper_identity) ->
        { identity with k_trace_id = "successor-trace" }) keeper.k_identity } in
  state.keepers <- [ current ];
  Alcotest.(check bool) "queued old trace cannot land before reconciliation" false
    (take_live_context_observation state old (Error "previous trace"));
  Alcotest.(check bool) "discarded completion also retires its pending owner" true
    (Masc_tui_context_state.current_key state.live_context = None);
  (* A return to the original identity before the next reconciliation must
     start a new worker, rather than coalesce onto the discarded result. *)
  state.keepers <- [ keeper ];
  let returned = start_live_context_exn state keeper in
  Alcotest.(check bool) "return to the original key can settle afresh" true
    (take_live_context_observation state returned (Error "returned key"));
  state.keepers <- [ current ];
  let fresh = start_live_context_exn state current in
  Alcotest.(check bool) "late old result cannot settle the successor" true
    (not (take_live_context_observation state old (Error "late result"))
     && Masc_tui_context_state.is_current state.live_context fresh);
  Alcotest.(check bool) "current failure is admitted exactly once" true
    (take_live_context_observation state fresh (Error "current store failure")
     && not (take_live_context_observation state fresh (Error "duplicate")))

let test_live_context_chat_target_is_independent_of_roster_cursor () =
  let open Masc_tui_types in
  let state, keeper = live_context_fixture () in
  let other = { keeper with k_name = "beta" } in
  state.keepers <- [ keeper; other ];
  state.view <- Keepers Keeper_message;
  state.msg_target_keeper_name <- Some keeper.k_name;
  state.keeper_cursor <- 1;
  Alcotest.(check bool) "chat target owns the source, rather than the roster cursor" true
    (live_context_keeper state = Some keeper);
  let request = start_live_context_exn state keeper in
  Alcotest.(check bool) "moving the roster does not steal the chat source" true
    (take_live_context_observation state request (Error "target context unavailable"));
  state.msg_target_keeper_name <- Some "missing";
  Alcotest.(check bool) "missing chat target cannot fall back to a roster row" true
    (live_context_keeper state = None);
  state.view <- Overview;
  Alcotest.(check bool) "unrelated surface does not request a Keeper context" true
    (live_context_keeper state = None)

let test_live_context_suspension_cancels_and_retires_same_path_read () =
  let open Masc_tui_types in
  let state, keeper = live_context_fixture () in
  let request = start_live_context_exn state keeper in
  let cancelled = ref 0 in
  supersede_live_context_read state (Some (fun () -> incr cancelled));
  suspend_workspace_readings state;
  state.workspace_identity <- Workspace_identity_match;
  state.local_keepers <- Local_workspace_read;
  Alcotest.(check int) "workspace suspension requested source cancellation" 1 !cancelled;
  Alcotest.(check bool) "same path after reconfirmation cannot revive old scope" false
    (take_live_context_observation state request (Error "old scope"));
  let current = start_live_context_exn state keeper in
  Alcotest.(check bool) "new scope owns its observation" true
    (take_live_context_observation state current (Error "current scope"))

let test_keeper_metadata_admits_input_before_work_completes () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  let work = local_workspace_request_exn state Local_work 5L in
  let required = local_workspace_request_exn state Local_keepers 6L in
  Alcotest.(check bool) "unread metadata cannot authorize input" false
    (keeper_available_for_new_message state keeper.k_name);
  apply_metadata_observation state required metadata;
  Alcotest.(check bool) "input is ready while work and HTTP collection are unfinished" true
    (keeper_available_for_new_message state keeper.k_name
     && state.local_workspace = Local_workspace_unread
     && Local_read_order.in_flight state.local_workspace_read_order
     && state.http_refresh_started_ns = Some 0L);
  let work_reading : Masc_tui_loader.local_reading =
    { lr_agents = []; lr_rows = Masc_tui_overview_tasks.Rows_read []
    ; lr_tasks_domain = []; lr_tasks_error = None; lr_task_flow = None
    ; lr_operator_stalled = Masc_tui_agenda.Read []; lr_goal_task_links = Goal_links_not_read
    ; lr_goals_to_confirm = Masc_tui_agenda.Read [] } in
  (match take_local_workspace_read state ~source:Local_work work (Ok work_reading) with
   | Some (Ok observed) -> Masc_tui_loader.apply_local_workspace state observed
   | Some (Error _) | None -> Alcotest.fail "work result was not admitted");
  Alcotest.(check bool) "later work cannot replace metadata or revoke input" true
    (state.keepers = [ keeper ] && state.local_keepers = Local_workspace_read
     && keeper_available_for_new_message state keeper.k_name)

let test_local_source_failures_are_independent () =
  let open Masc_tui_types in
  let state, keeper, metadata = local_keeper_source_fixture () in
  let work = local_workspace_request_exn state Local_work 5L in
  let required = local_workspace_request_exn state Local_keepers 6L in
  ignore (take_local_workspace_read state ~source:Local_work work (Error "archive unavailable"));
  Alcotest.(check bool) "work failure leaves metadata pending and unmodified" true
    (state.local_workspace = Local_workspace_failed "archive unavailable"
     && state.local_keepers = Local_workspace_unread
     && Local_read_order.in_flight state.local_keeper_read_order);
  apply_metadata_observation state required metadata;
  Alcotest.(check bool) "work failure does not prevent metadata-authorized input" true
    (keeper_available_for_new_message state keeper.k_name);
  let retry = local_workspace_request_exn state Local_keepers 7L in
  ignore (take_local_workspace_read state ~source:Local_keepers retry (Error "metadata unavailable"));
  Alcotest.(check bool) "metadata failure withdraws input without rewriting work state" true
    (not (keeper_available_for_new_message state keeper.k_name)
     && state.local_workspace = Local_workspace_failed "archive unavailable"
     && state.local_keepers = Local_workspace_failed "metadata unavailable")

let test_local_source_tickets_cannot_cross_or_survive_suspension () =
  let open Masc_tui_types in
  let state, _, _ = local_keeper_source_fixture () in
  let work = local_workspace_request_exn state Local_work 5L in
  let required = local_workspace_request_exn state Local_keepers 6L in
  Alcotest.(check int) "source counters may legitimately coincide"
    (Local_read_order.request_id work.lwr_request) (Local_read_order.request_id required.lwr_request);
  Alcotest.(check bool) "matching numeric ticket cannot spend the other source owner" true
    (take_local_workspace_read state ~source:Local_keepers work (Ok ()) = None
     && take_local_workspace_read state ~source:Local_work required (Ok ()) = None
     && Local_read_order.in_flight state.local_keeper_read_order
     && Local_read_order.in_flight state.local_workspace_read_order);
  suspend_workspace_readings state;
  let new_work = local_workspace_request_exn state Local_work 7L in
  let new_required = local_workspace_request_exn state Local_keepers 8L in
  Alcotest.(check bool) "same-path late results cannot retire either successor" true
    (take_local_workspace_read state ~source:Local_work work (Error "old work") = None
     && take_local_workspace_read state ~source:Local_keepers required (Error "old metadata") = None
     && Local_read_order.in_flight state.local_keeper_read_order
     && Local_read_order.in_flight state.local_workspace_read_order);
  Alcotest.(check bool) "each current source still settles independently" true
    (take_local_workspace_read state ~source:Local_work new_work (Ok ()) = Some (Ok ())
     && take_local_workspace_read state ~source:Local_keepers new_required (Ok ()) = Some (Ok ()))

let test_question_origin_survives_answer_and_workspace_change () =
  let open Masc_tui_types in
  let module Ask = Masc_tui_ask_projection in
  let state,early = early_asks_fixture () in
  let original_ref = Ids.Turn_ref.make ~trace_id:"original-question-source" ~absolute_turn:17 in
  let snapshot = match early.ea_observation.asks_result with
    | Ok snapshot -> snapshot | Error error -> Alcotest.fail error in
  let original = match snapshot.asn_rows with
    | [row] -> {row with ar_source_turn_ref=Some original_ref}
    | _ -> Alcotest.fail "one original question" in
  let origin = Ask.origin_of_row original in
  toggle_ask_origin state origin;
  let submission : ask_submission =
    {as_request=ref ();as_started_ns=0L;as_receipt=Ask_answer_receipt.create ();
     as_completion=Ask_answer_completion.create ();as_reading=Some state.workspace_read_authority;as_authority=state.workspace_authority;
     as_keeper_name=original.ar_keeper;as_ask_id=original.ar_id;as_answered_label="private choice";
     as_source_turn_ref=original.ar_source_turn_ref} in
  begin_ask_submission_state ~submission state;
  let later = {original with ar_id="later-question";
      ar_source_turn_ref=Some (Ids.Turn_ref.make ~trace_id:"later-source" ~absolute_turn:900)} in
  state.asks_snapshot <- Some {snapshot with asn_rows=[later]};
  state.asks_error <- Some "reread unavailable";
  let feedback = retain_ask_answer_feedback state submission
      (Ok (Masc.Tui_decode_asks.Ask_answer_recorded Masc.Tui_decode_asks.Ask_wake_stored))
      |> Option.get in
  Alcotest.(check (option string)) "receipt preserves the transmitted question's source"
    (Some "original-question-source#17") (Option.map Ids.Turn_ref.to_string feedback.af_source_turn_ref);
  Alcotest.(check bool) "a later selected question does not replace opened original diagnostics" true
    (Option.exists (Ask.same_origin origin) (current_ask_origin state));
  let json = Ask.origin_to_json (Ask.origin_of_feedback feedback) in
  Alcotest.(check string) "source telemetry belongs to the original question"
    original.ar_id Yojson.Safe.Util.(json |> member "ask_id" |> to_string);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  Alcotest.(check bool) "previous workspace cannot retain visible source diagnostics" true
    (current_ask_origin state=None);
  Alcotest.(check bool) "previous receipt cannot supply a new workspace source" true
    (current_ask_answer_feedback state=None);
  let unknown = Ask.origin_of_row {later with ar_source_turn_ref=None} in
  state.workspace_identity <- Workspace_identity_unread;
  toggle_ask_origin state unknown;
  Alcotest.(check bool) "unconfirmed workspace cannot open source from an old row" true
    (current_ask_origin state=None);
  state.workspace_identity <- Workspace_identity_match;
  toggle_ask_origin state unknown;
  let unknown = current_ask_origin state |> Option.get |> Ask.origin_to_json in
  Alcotest.(check bool) "unknown source is never filled from earlier diagnostics" true
    Yojson.Safe.Util.((unknown |> member "source_turn_ref") = `Null)

let test_answer_receipt_has_one_original_submission_owner () =
  let open Masc_tui_types in
  let module Decode = Masc.Tui_decode_asks in
  let module O = Ask_answer_observation in
  let state = create_state ~workspace:"a" ~local_base_path:"/workspace/a"
    ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity "/workspace/a");
  let submission ask_id : ask_submission =
    { as_request = ref (); as_started_ns = 10L; as_receipt=Ask_answer_receipt.create ();
      as_completion=Ask_answer_completion.create ();as_reading=Some state.workspace_read_authority; as_authority = state.workspace_authority;
      as_keeper_name = "reader"; as_ask_id = ask_id; as_source_turn_ref = None; as_answered_label = "reader: choice" } in
  let first = submission "first" in
  begin_ask_submission_state ~submission:first state;
  let receipt = Ok (Decode.Ask_answer_recorded Decode.Ask_wake_stored) in
  let feedback = match retain_ask_answer_feedback state first receipt with
    | Some feedback -> feedback
    | None -> Alcotest.fail "current original receipt was not retained" in
  state.asks_error <- Some "reread failed";
  state.asks_snapshot <- None;
  finish_http_refresh_state state;
  Alcotest.(check bool) "ordinary refresh and failed reread preserve the receipt" true
    (current_ask_answer_feedback state = Some feedback);
  Alcotest.(check bool) "terminal duplicate cannot replace the earlier POST receipt" true
    (Option.is_none (retain_ask_answer_feedback state first (Error "later observation failed")));
  let failed_reread = match observe_ask_reread_completion state first ~at_ns:20L (Error "reread failed") with
    | Some observation -> observation
    | None -> Alcotest.fail "early POST receipt suppressed canonical reread completion" in
  Alcotest.(check bool) "failed reread keeps the original request and its independent outcome" true
    (failed_reread.submission.as_request == first.as_request
     && failed_reread.submission.as_started_ns=10L && failed_reread.at_ns=20L
     && failed_reread.event=O.Reread_admitted O.Returned_error);
  Alcotest.(check bool) "lifecycle observation cannot settle submission or overwrite its receipt" true
    (state.ask_submit_inflight && current_ask_answer_feedback state=Some feedback);
  state.ask_submit_inflight <- false;
  Alcotest.(check bool) "settled submission cannot emit another reread admission" true
    (Option.is_none (observe_ask_reread_completion state first ~at_ns:21L (Error "duplicate")));
  let second = submission "second" in
  begin_ask_submission_state ~submission:second state;
  let next = match retain_ask_answer_feedback state second (Error "recording unknown") with
    | Some next -> next | None -> Alcotest.fail "new original submission must own its receipt" in
  Alcotest.(check bool) "an older request cannot overwrite the newer receipt" true
    (Option.is_none (retain_ask_answer_feedback state first receipt));
  let empty : Decode.asks_snapshot = {asn_keeper=None;asn_open_count=0;asn_rows=[]} in
  Alcotest.(check bool) "old reread cannot borrow a newer submission's ownership" true
    (Option.is_none (observe_ask_reread_completion state first ~at_ns:30L (Ok empty)));
  Alcotest.(check bool) "successful empty reread does not confirm an unknown answer write" true
    (match observe_ask_reread_completion state second ~at_ns:31L (Ok empty) with
     | Some observation -> observation.event=O.Reread_admitted O.Returned
         && current_ask_answer_feedback state=Some next
     | None -> false);
  Alcotest.(check bool) "newer unconfirmed result remains unconfirmed" true
    (current_ask_answer_feedback state = Some next);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation + 1);
  Alcotest.(check bool) "old workspace receipt is hidden" true
    (Option.is_none (current_ask_answer_feedback state));
  Alcotest.(check bool) "old submission cannot enter a replacement workspace" true
    (Option.is_none (retain_ask_answer_feedback state second receipt));
  Alcotest.(check bool) "old workspace reread grants no lifecycle admission" true
    (Option.is_none (observe_ask_reread_completion state second ~at_ns:40L (Ok empty)));
  let unread = submission "unread" in
  begin_ask_submission_state ~submission:unread state;
  state.workspace_identity <- Workspace_identity_unread;
  Alcotest.(check bool) "unconfirmed workspace grants no receipt admission" true
    (Option.is_none (retain_ask_answer_feedback state unread receipt));
  Alcotest.(check bool) "unconfirmed workspace grants no reread admission" true
    (Option.is_none (observe_ask_reread_completion state unread ~at_ns:41L (Ok empty)))

let test_answer_receipt_survives_full_mailbox_and_worker_cancellation () =
  Eio_main.run @@ fun _ ->
  Eio.Switch.run @@ fun sw ->
  let open Masc_tui_types in
  let module R = Ask_answer_receipt in
  let module C = Ask_answer_completion in
  let module P = Masc_tui_async_protocol in
  let module Decode = Masc.Tui_decode_asks in
  let state = create_state ~workspace:"receipt" ~local_base_path:"/workspace/receipt"
      ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity state.local_base_path);
  let source = Ids.Turn_ref.make ~trace_id:"question-before-cancellation" ~absolute_turn:17 in
  let submission name : ask_submission =
    {as_request=ref ();as_started_ns=10L;as_receipt=R.create ();
     as_completion=C.create ();as_reading=Some state.workspace_read_authority;
     as_authority=state.workspace_authority;as_keeper_name="reader";as_ask_id=name;
     as_answered_label="original choice";as_source_turn_ref=Some source} in
  let original = submission "original" in
  begin_ask_submission_state ~submission:original state;
  let mailbox = Eio.Stream.create 1 in
  Eio.Stream.add mailbox ();
  let entered, enter = Eio.Promise.create () and cancellation, set_cancellation = Eio.Promise.create () in
  let receipt = Ok (Decode.Ask_answer_recorded Decode.Ask_wake_stored) in
  let reread = Ok {Decode.asn_keeper=None;asn_open_count=0;asn_rows=[]} in
  let worker = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun context ->
      Eio.Promise.resolve set_cancellation context;
      Fun.protect ~finally:(fun () -> close_ask_submission original) (fun () ->
        (* The production publication primitive has no mailbox dependency.
           This fixture then advances downstream and waits on notification. *)
        Alcotest.(check bool) "first actual result is published" true
          (R.publish original.as_receipt ~observed_ns:20L receipt);
        Alcotest.(check bool) "final pair is stored before the fixture notification" true
          (C.publish original.as_completion ~observed_ns:30L ~receipt ~asks:reread);
        Eio.Promise.resolve enter ();
        Eio.Stream.add mailbox ()))) in
  Eio.Promise.await entered;
  Alcotest.(check int) "downstream fixture step was reached without consuming the full mailbox" 1
    (Eio.Stream.length mailbox);
  Eio.Cancel.cancel (Eio.Promise.await cancellation) Exit;
  (match Eio.Promise.await worker with
   | Error (Eio.Cancel.Cancelled _) -> ()
   | Error error -> Alcotest.fail (Printexc.to_string error)
   | Ok () -> Alcotest.fail "final notification unexpectedly entered the full mailbox");
  Alcotest.(check bool) "worker cleanup cannot overwrite the actual result" false
    (R.publish original.as_receipt ~observed_ns:21L (Error "late cancellation"));
  Alcotest.(check bool) "publication grants no feedback or final action settlement" true
    (state.ask_submit_inflight && Option.is_none state.ask_answer_feedback);
  let final_owner, final_fact = match List.nth_opt (take_pending_ask_answer_completions state) 0 with
    | Some fact -> fact | None -> Alcotest.fail "cancellation lost the completed reread" in
  Alcotest.(check bool) "raw final result is coherent and cannot be overwritten by worker closure" true
    (final_owner==original && final_fact.receipt=receipt && final_fact.asks=reread
     && final_fact.observed_ns=30L
     && not (C.publish original.as_completion ~observed_ns:31L ~receipt:(Error "late failure")
       ~asks:(Error "late failure")));
  let final_message = P.ask_answer_completion_message final_owner final_fact in
  state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
    ~local_base_path:state.local_base_path (Error "identity temporarily unavailable");
  suspend_workspace_readings state;
  (match final_message with
   | P.Workspace_scoped (authority, reading, inner) ->
     Alcotest.(check bool) "completion carries its dispatch scope and remains an operation outcome" true
       (authority=original.as_authority
        && (match reading,original.as_reading with
            | Some carried,Some captured -> carried==captured && carried!=state.workspace_read_authority
            | None,None -> true | (Some _ | None),(Some _ | None) -> false)
        && P.workspace_message_admitted state ~authority ~reading inner);
     (match P.project_workspace_operation_reply state ~authority ~reading inner with
      | P.Ask_answer_done (owner, saved, observed) ->
        Alcotest.(check bool) "retired GET is refused without discarding confirmed POST receipt" true
          (owner.as_request==original.as_request && saved=receipt && Result.is_error observed
           && ask_submission_inflight state owner)
      | _ -> Alcotest.fail "completion did not use canonical operation projection")
   | _ -> Alcotest.fail "completion borrowed a current unscoped transport");
  Alcotest.(check bool) "raw facts and terminal transport are distinct, each retained once" true
    ((take_pending_ask_answer_completions state=[])
     && match C.read original.as_completion with C.Returned fact -> fact.asks=reread
        | C.Waiting | C.Closed_without_result -> false);
  state.ask_submit_inflight <- false;
  Alcotest.(check bool) "duplicate terminal delivery cannot settle the same submission again" false
    (ask_submission_inflight state original);
  state.workspace_identity <- Workspace_identity_match;
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  state.ask_submission_current <- None;
  state.ask_submit_inflight <- false;
  (match final_message with
   | P.Workspace_scoped (authority, reading, inner) ->
     Alcotest.(check bool) "foreign authority cannot replay recovered completion into a replacement workspace" false
       (P.workspace_message_admitted state ~authority ~reading inner)
   | _ -> Alcotest.fail "original completion lost its scope");
  let pending, observed = match List.nth_opt (pending_ask_answer_receipts state) 0 with
    | Some pending -> pending | None -> Alcotest.fail "withdrawal lost the published receipt" in
  Alcotest.(check bool) "pending receipt keeps original result, timestamp and source" true
    (pending.as_request==original.as_request && observed.result=receipt && observed.observed_ns=20L
     && pending.as_source_turn_ref=Some source);
  let impostor = {original with as_receipt=R.create ()} in
  ignore (R.publish impostor.as_receipt ~observed_ns:99L (Error "unrelated result"));
  let owner, observed = match take_ask_answer_receipt state impostor with
    | Some observed -> observed | None -> Alcotest.fail "registered original receipt was not recoverable" in
  Alcotest.(check bool) "drain reads the registered owner's cell, never a replacement payload" true
    (owner==original && observed.result=receipt);
  Alcotest.(check bool) "foreign workspace receipt gains no current feedback" true
    (Option.is_none (retain_ask_answer_feedback state owner observed.result));
  Alcotest.(check bool) "a recovered receipt is consumed once but its fact remains session-owned" true
    (Option.is_none (take_ask_answer_receipt state original)
     && List.exists (fun held -> held==original) state.ask_answer_submissions
     && match R.read original.as_receipt with R.Returned kept -> kept.result=receipt | R.Waiting | R.Closed_without_result -> false);
  let abandoned = submission "no-observed-result" in
  begin_ask_submission_state ~submission:abandoned state;
  close_ask_submission abandoned;
  Alcotest.(check bool) "worker closure invents neither an answer result nor pending notification" true
    ((pending_ask_answer_receipts state=[])
     && (take_pending_ask_answer_completions state=[])
     && match R.read abandoned.as_receipt,C.read abandoned.as_completion with
       | R.Closed_without_result,C.Closed_without_result -> true
       | (R.Waiting | R.Returned _ | R.Closed_without_result),(C.Waiting | C.Returned _ | C.Closed_without_result) -> false);
  let post_only = submission "cancelled-before-reread-result" in
  begin_ask_submission_state ~submission:post_only state;
  ignore (R.publish post_only.as_receipt ~observed_ns:35L receipt);
  close_ask_submission post_only;
  Alcotest.(check bool) "a known POST with no reread result does not settle the submission" true
    (state.ask_submit_inflight && (take_pending_ask_answer_completions state=[])
     && match take_ask_answer_receipt state post_only with
        | Some (_, fact) -> fact.result=receipt | None -> false);
  let replacement = submission "replacement" in
  begin_ask_submission_state ~submission:replacement state;
  let unknown = Error "response unavailable" in
  ignore (R.publish replacement.as_receipt ~observed_ns:30L unknown);
  let owner, observed = match take_ask_answer_receipt state replacement with
    | Some observed -> observed | None -> Alcotest.fail "replacement lost its own receipt" in
  Alcotest.(check bool) "replacement retains only its own unconfirmed answer observation" true
    (Option.is_some (retain_ask_answer_feedback state owner observed.result)
     && observed.result=unknown && owner.as_request==replacement.as_request);
  close_ask_submission replacement;
  let unconfirmed = {(submission "original-unconfirmed-read") with as_reading=None} in
  begin_ask_submission_state ~submission:unconfirmed state;
  ignore (C.publish unconfirmed.as_completion ~observed_ns:40L ~receipt ~asks:reread);
  let owner, fact = match List.nth_opt (take_pending_ask_answer_completions state) 0 with
    | Some fact -> fact | None -> Alcotest.fail "original unconfirmed scope lost its completion fact" in
  (match P.ask_answer_completion_message owner fact with
   | P.Workspace_scoped (authority,None,inner) ->
     (match P.project_workspace_operation_reply state ~authority ~reading:None inner with
      | P.Ask_answer_done (_,saved,observed) ->
        Alcotest.(check bool) "original unconfirmed reading cannot borrow a later confirmed scope" true
          (saved=receipt && Result.is_error observed)
      | _ -> Alcotest.fail "unconfirmed scope did not use operation projection")
   | _ -> Alcotest.fail "completion rebuilt original read scope from current UI state")

let original_answer_followup_identity ?(at=200.) ?(stimulus="original-source") () =
  let module Decode = Masc.Tui_decode_asks in
  let json = `Assoc ["workspace",`Assoc ["base_path",`String "/workspace/followup";
      "masc_root",`String "/workspace/followup/.masc"];
    "state_ready",`Bool true;"keeper",`String "alpha";"answer_progress_for",`String "original";
    "answer_progress",`Assoc ["state",`String "started";"answered_at",`Float at;
      "stimulus_id",`String stimulus]] in
  match Decode.decode_ask_followup_event ~expected_base_path:"/workspace/followup"
      ~expected_masc_root:"/workspace/followup/.masc" ~keeper_name:"alpha" ~ask_id:"original" json with
  | Ok (Decode.Ask_followup_started identity) -> identity
  | Ok (Ask_followup_source _ | Ask_followup_completed _) -> Alcotest.fail "expected canonical stream start"
  | Error detail -> Alcotest.fail detail

let answer_followup_state () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"followup" ~local_base_path:"/workspace/followup"
      ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity state.local_base_path);
  let submission name : ask_submission = {as_request=ref ();as_started_ns=0L;as_receipt=Ask_answer_receipt.create ();
      as_completion=Ask_answer_completion.create ();as_reading=Some state.workspace_read_authority;as_authority=state.workspace_authority;
      as_keeper_name="alpha";as_ask_id=name;as_source_turn_ref=None;as_answered_label="choice"} in
  let first = submission "original" in
  begin_ask_submission_state ~submission:first state;
  ignore (retain_ask_answer_feedback state first
    (Ok (Masc.Tui_decode_asks.Ask_answer_recorded Ask_wake_stored)));
  state, submission

let test_answer_followup_retains_current_source_observations () =
  let open Masc_tui_types in
  let module Decode = Masc.Tui_decode_asks in
  let module Projection = Masc_tui_ask_projection in
  let state, _ = answer_followup_state () in
  let original = original_answer_followup_identity () in
  let begin_read () = match begin_ask_followup_read state with
    | Some value -> value | None -> Alcotest.fail "confirmed original answer did not own a read" in
  let admit request owner event = match take_ask_followup_event state request owner event with
    | Some (Ok _) -> () | Some (Error detail) -> Alcotest.fail detail
    | None -> Alcotest.fail "current source was not admitted" in
  let source request owner value = admit request owner (Decode.Ask_followup_source (original,value)) in
  let view () = match current_ask_followup state with
    | Some reading -> Projection.followup_view reading | None -> Alcotest.fail "follow-up observation missing" in
  let reactions = Decode.Ask_reactions_observed {ar_turn_started_at=Some 201.;ar_turn_finished_at=None;
      ar_queue_settled_at=None;ar_queue_cancelled_at=None;ar_evidence_complete=true;ar_evidence_current=true}
  and tools = Decode.Ask_tools_observed {at_count=1;at_first_recorded_at=Some 202.;at_latest=Some
      {ata_execution_id="logical-one";ata_physical_execution_id="physical-one";ata_trace_id="original-trace";
       ata_keeper_turn_id=17;ata_tool="Read";ata_recorded_at=202.};at_evidence_current=true} in
  let task status = Decode.Ask_task_observed {akt_task_id="task-original";akt_location=Ask_task_backlog;
      akt_status=status;akt_observed_at=203.;akt_evidence_current=true} in
  let round task_value tools_value reactions_value =
    let request, owner = begin_read () in
    admit request owner (Decode.Ask_followup_started original);
    List.iter (source request owner) [Decode.Ask_followup_task task_value;
      Ask_followup_tools tools_value;Ask_followup_reactions reactions_value];
    admit request owner (Decode.Ask_followup_completed original);
    Alcotest.(check bool) "all sources and terminal frame settle only the read" true
      (finish_ask_followup_read state request owner (Ok ())=Some (Ok ()) && state.ask_submit_inflight)
  in
  let request, owner = begin_read () in
  let pending = view () in
  Alcotest.(check bool) "poll shares the in-flight read and never fabricates empty peer evidence" true
    (Option.is_none (begin_ask_followup_read state)
      && pending.fv_reactions.fo_value=None && pending.fv_tools.fo_value=None
      && pending.fv_task.fo_value=None
      && pending.fv_tools.fo_state=Projection.Followup_pending);
  admit request owner (Decode.Ask_followup_started original);
  source request owner (Decode.Ask_followup_task (task Masc_domain.Todo));
  let early = view () in
  Alcotest.(check bool) "original Task is admitted while wake and Tool reads remain pending" true
    (early.fv_task.fo_value=Some (task Masc_domain.Todo)
      && early.fv_task.fo_state=Projection.Followup_received
      && early.fv_tools.fo_state=Projection.Followup_pending
      && early.fv_reactions.fo_state=Projection.Followup_pending
      && Snapshot_read.in_flight state.ask_followup_read);
  source request owner (Decode.Ask_followup_tools tools);
  source request owner (Decode.Ask_followup_reactions reactions);
  admit request owner (Decode.Ask_followup_completed original);
  ignore (finish_ask_followup_read state request owner (Ok ()));
  Alcotest.(check bool) "late source cannot reopen a completed reader" true
    (Option.is_none (take_ask_followup_event state request owner (Decode.Ask_followup_started original)));
  let request, owner = begin_read () in
  admit request owner (Decode.Ask_followup_started original);
  source request owner (Decode.Ask_followup_tools Decode.Ask_tools_unavailable);
  let working = task (Masc_domain.InProgress {assignee="original-worker";started_at="2026-10-17T00:00:00Z"}) in
  source request owner (Decode.Ask_followup_task working);
  ignore (finish_ask_followup_read state request owner (Error "connection interrupted"));
  let partial = view () in
  Alcotest.(check bool) "transport failure preserves fresh Task and marks only unfinished wake unconfirmed" true
    (partial.fv_task.fo_value=Some working
      && partial.fv_task.fo_state=Projection.Followup_received
      && partial.fv_tools.fo_state=Projection.Followup_received
      && partial.fv_reactions.fo_state=Projection.Followup_unconfirmed
      && (match partial.fv_tools.fo_value with
          | Some (Decode.Ask_tools_observed {at_count=1;at_evidence_current=false;_}) -> true
          | Some (Ask_tools_observed _ | Ask_tools_unavailable) | None -> false)
      && (match partial.fv_reactions.fo_value with
          | Some (Decode.Ask_reactions_observed {ar_turn_started_at=Some 201.;ar_evidence_current=false;_}) -> true
          | Some (Ask_reactions_observed _ | Ask_reactions_unavailable) | None -> false));
  let absent_reactions = Decode.Ask_reactions_observed {ar_turn_started_at=None;ar_turn_finished_at=None;
      ar_queue_settled_at=None;ar_queue_cancelled_at=None;ar_evidence_complete=false;ar_evidence_current=true} in
  round (Decode.Ask_task_missing "task-original")
    (Decode.Ask_tools_observed {at_count=0;at_first_recorded_at=None;at_latest=None;at_evidence_current=true})
    absent_reactions;
  let retained = view () in
  Alcotest.(check bool) "missing Task, regressed Tool count and incomplete clocks retain prior evidence" true
    ((match retained.fv_task.fo_value with
      | Some (Decode.Ask_task_observed {akt_status=Masc_domain.InProgress _;akt_evidence_current=false;_}) -> true
      | Some (Ask_task_observed _ | Ask_task_unlinked | Ask_task_missing _ | Ask_task_unavailable _) | None -> false)
    && (match retained.fv_tools.fo_value with
      | Some (Decode.Ask_tools_observed {at_count=1;at_evidence_current=false;_}) -> true
      | Some (Ask_tools_observed _ | Ask_tools_unavailable) | None -> false)
    && (match retained.fv_reactions.fo_value with
      | Some (Decode.Ask_reactions_observed {ar_turn_started_at=Some 201.;_}) -> true
      | Some (Ask_reactions_observed _ | Ask_reactions_unavailable) | None -> false));
  List.iter (fun identity ->
    let request, owner = begin_read () in
    Alcotest.(check bool) "changed canonical answer is refused across refreshes" true
      (match take_ask_followup_event state request owner (Decode.Ask_followup_started identity) with
       | Some (Error _) -> true | Some (Ok _) | None -> false);
    ignore (finish_ask_followup_read state request owner (Ok ())))
    [original_answer_followup_identity ~at:300. ();original_answer_followup_identity ~stimulus:"foreign" ()];
  List.iter (fun foreign ->
    let request, owner = begin_read () in
    admit request owner (Decode.Ask_followup_started original);
    Alcotest.(check bool) "another or unlinked Task cannot replace the original Task" true
      (match take_ask_followup_event state request owner (Decode.Ask_followup_source (original,Ask_followup_task foreign)) with
       | Some (Error _) -> true | Some (Ok _) | None -> false);
    ignore (finish_ask_followup_read state request owner (Ok ())))
    [Decode.Ask_task_missing "task-other";Ask_task_unlinked];
  round (task (Masc_domain.Done {assignee="worker";completed_at="2026-10-17T00:00:00Z";notes=None})) tools reactions;
  round (task Masc_domain.Todo) tools reactions;
  Alcotest.(check bool) "fresh canonical Task phase may move back without a fabricated monotonic gate" true
    ((view ()).fv_task.fo_value=Some (task Masc_domain.Todo) && Option.is_none state.ask_followup_error)

let test_answer_followup_withdraws_reader_without_borrowing_successor () =
  let open Masc_tui_types in
  let module Decode = Masc.Tui_decode_asks in
  let state, submission = answer_followup_state () in
  let begin_read () = match begin_ask_followup_read state with
    | Some value -> value | None -> Alcotest.fail "expected current follow-up reader" in
  let original = original_answer_followup_identity () in
  let retired, old_owner = begin_read () in
  let old_cancelled = ref None in
  supersede_ask_followup_worker state (Some (retired, fun detail -> old_cancelled:=Some detail)) ~detail:"superseded";
  let second = submission "new-answer" in
  begin_ask_submission_state ~submission:second state;
  Alcotest.(check bool) "new answer cancels original worker and awaits its own canonical receipt" true
    (Option.is_some !old_cancelled && Option.is_none (begin_ask_followup_read state));
  ignore (retain_ask_answer_feedback state second (Ok (Decode.Ask_answer_recorded Ask_wake_stored)));
  let current, owner = begin_read () in
  let successor_cancelled = ref None in
  supersede_ask_followup_worker state (Some (current, fun detail -> successor_cancelled:=Some detail)) ~detail:"superseded";
  finish_ask_followup_worker state retired;
  Alcotest.(check bool) "old worker cleanup and late frames cannot consume successor ownership" true
    (Option.is_none (take_ask_followup_event state retired old_owner (Decode.Ask_followup_started original))
      && Option.is_none (finish_ask_followup_read state retired old_owner (Error "old transport"))
      && Snapshot_read.is_current state.ask_followup_read current
      && Option.exists (fun (request,_) -> Snapshot_read.request_id request=Snapshot_read.request_id current)
          state.ask_followup_cancel);
  state.workspace_identity <- Workspace_identity_match_unconfirmed "probe unavailable";
  suspend_workspace_readings state;
  Alcotest.(check bool) "read-authority withdrawal cancels the worker and rejects queued events" true
    (Option.is_some !successor_cancelled && not (Snapshot_read.in_flight state.ask_followup_read)
      && Option.is_none state.ask_followup_cancel
      && Option.is_none (take_ask_followup_event state current owner (Decode.Ask_followup_started original))
      && Option.is_none (finish_ask_followup_read state current owner (Ok ()))
      && Option.is_none (current_ask_followup state))

let test_datasets_settle_independently_under_original_request () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"datasets" ~local_base_path:"/workspace/datasets"
      ~port:0 ~refresh_interval:0. () in
  let observed = identity "/workspace/datasets" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let needs = {nothing with needs_board=true;needs_planning=true;needs_system_logs=true} in
  let reads, original = Surface_read_order.dispatch ~kind:Surface_read_order.Full
      ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let take request dataset = take_early_surface_dataset state ~ticket ~authority
      ~identity:observed ~request ~dataset in
  Alcotest.(check bool) "ready Planning settles while Board and logs remain pending" true
    (take original Surface_read_order.Planning_data
     && Surface_read_order.pending ~needs state.http_surface_reads
        = [Surface_read_order.Board;Surface_read_order.System_logs]
     && state.http_refresh_started_ns = Some 0L);
  Alcotest.(check bool) "a second result cannot replace that settlement" false
    (take original Surface_read_order.Planning_data);
  let navigation_needs = {nothing with needs_board=true} in
  let reads, navigation = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs:navigation_needs ~started_ns:1L state.http_surface_reads in
  state.http_surface_reads <- reads;
  Alcotest.(check bool) "navigation owns Board without retiring the original logs" true
    (not (take original Surface_read_order.Board_posts)
     && take navigation Surface_read_order.Board_posts
     && take navigation Surface_read_order.Board_hearths
     && Surface_read_order.navigation_active state.http_surface_reads navigation
     && Surface_read_order.pending ~needs state.http_surface_reads = [Surface_read_order.System_logs]);
  (* Error is an owned settlement too: a later success cannot overwrite it.
     Payload application retains the existing dataset-specific error policy. *)
  Alcotest.(check bool) "the original failed logs read settles once" true
    (take original Surface_read_order.System_logs_data
     && not (take original Surface_read_order.System_logs_data));
  let reads, remaining = Surface_read_order.take state.http_surface_reads original in
  state.http_surface_reads <- reads;
  Alcotest.(check bool) "final bundle has no dataset left to apply again" true
    (remaining=[] && Surface_read_order.navigation_active state.http_surface_reads navigation);
  state.http_surface_reads <- Surface_read_order.finish state.http_surface_reads navigation;
  Alcotest.(check bool) "only its own collector completion releases navigation" false
    (Surface_read_order.navigation_in_flight state.http_surface_reads)

let board_dataset_fixture kind =
  let open Masc_tui_types in
  let state=create_state ~workspace:"board-delivery" ~local_base_path:"/workspace/board-delivery"
    ~port:0 ~refresh_interval:0. () in
  let observed=identity "/workspace/board-delivery" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let ticket=Http_refresh_order.dispatch state.http_refresh_order in
  (match kind with
   | Surface_read_order.Full -> begin_http_refresh_state state ~ticket ~started_ns:0L
   | Surface_read_order.Navigation | Surface_read_order.Independent -> state.http_refresh_order <- ticket);
  let needs={nothing with needs_board=true;needs_planning=true} in
  let reads,request=Surface_read_order.dispatch ~kind ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  state,observed,ticket,state.workspace_authority,needs,request

let test_board_delivery_retains_sibling_and_terminal_remainder () =
  let open Masc_tui_types in
  List.iter (fun kind -> List.iter (fun (first,second) ->
    let state,observed,ticket,authority,needs,request=board_dataset_fixture kind in
    let take dataset=take_early_surface_dataset state ~ticket ~authority ~identity:observed ~request ~dataset in
    Alcotest.(check bool) "first Board dataset is admitted without its sibling" true (take first);
    Alcotest.(check bool) "one received dataset does not finish logical Board or Planning" true
      (Surface_read_order.pending ~needs state.http_surface_reads=
        [Surface_read_order.Board;Surface_read_order.Planning]);
    Alcotest.(check bool) "duplicate early delivery cannot replace an admitted result" false (take first);
    let reads,remaining=Surface_read_order.take state.http_surface_reads request in
    state.http_surface_reads <- reads;
    Alcotest.(check bool) "terminal bundle applies only the missing Board dataset and other owned data" true
      (List.filter (fun dataset -> Surface_read_order.dataset_source dataset=Surface_read_order.Board)
         remaining=[second]
       && not (List.mem first remaining) && List.mem Surface_read_order.Planning_data remaining
       && Surface_read_order.pending ~needs reads=[]);
    Alcotest.(check bool) "terminal fallback cannot be replayed as late early delivery" false (take second);
    (match kind with
     | Surface_read_order.Navigation -> Alcotest.(check bool) "data application does not finish navigation collector" true
         (Surface_read_order.navigation_active reads request)
     | Surface_read_order.Full | Surface_read_order.Independent -> ());
    state.http_surface_reads <- Surface_read_order.finish reads request;
    Alcotest.(check bool) "matching terminal cleanup retires only its collector" false
      (Surface_read_order.navigation_active state.http_surface_reads request))
    [Surface_read_order.Board_posts,Surface_read_order.Board_hearths;
     Surface_read_order.Board_hearths,Surface_read_order.Board_posts])
    [Surface_read_order.Full;Surface_read_order.Navigation]

let test_board_delivery_supersedes_both_parts_without_replaying_early_data () =
  let open Masc_tui_types in
  let state,observed,ticket,authority,needs,original=board_dataset_fixture Surface_read_order.Full in
  let take request dataset=take_early_surface_dataset state ~ticket ~authority ~identity:observed ~request ~dataset in
  Alcotest.(check bool) "original posts can arrive before a navigation" true
    (take original Surface_read_order.Board_posts);
  let reads,current=Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
    ~needs:{nothing with needs_board=true} ~started_ns:1L state.http_surface_reads in
  state.http_surface_reads <- reads;
  Alcotest.(check bool) "old census cannot populate the successor's Board" false
    (take original Surface_read_order.Board_hearths);
  let reads,remaining=Surface_read_order.take state.http_surface_reads original in
  state.http_surface_reads <- Surface_read_order.finish reads original;
  Alcotest.(check bool) "old terminal and cleanup preserve both successor dataset owners" true
    (remaining=[Surface_read_order.Planning_data]
     && Surface_read_order.navigation_active state.http_surface_reads current
     && take current Surface_read_order.Board_posts
     && not (take current Surface_read_order.Board_posts)
     && Surface_read_order.pending ~needs state.http_surface_reads=[Surface_read_order.Board]
     && take current Surface_read_order.Board_hearths
     && not (take current Surface_read_order.Board_hearths)
     && Surface_read_order.pending ~needs state.http_surface_reads=[]);
  let reads,remaining=Surface_read_order.take state.http_surface_reads current in
  Alcotest.(check bool) "two early receipts leave no Board terminal replay" true (remaining=[]);
  state.http_surface_reads <- Surface_read_order.finish reads current;
  Alcotest.(check bool) "only successor completion ends its navigation" false
    (Surface_read_order.navigation_in_flight state.http_surface_reads)

let test_board_delivery_preserves_workspace_and_refresh_guards () =
  let open Masc_tui_types in
  let withdrawals=[
    (fun state -> state.http_refresh_order <- Http_refresh_order.dispatch state.http_refresh_order);
    (fun state -> state.workspace_identity <- Workspace_identity_match_unconfirmed "identity unavailable");
    (fun state -> suspend_workspace_readings state)] in
  List.iter (fun withdraw ->
    let state,observed,ticket,authority,needs,request=board_dataset_fixture Surface_read_order.Navigation in
    let take identity dataset=take_early_surface_dataset state ~ticket ~authority ~identity ~request ~dataset in
    Alcotest.(check bool) "foreign response cannot consume either Board dataset" true
      (not (take (identity "/workspace/foreign") Surface_read_order.Board_posts)
       && Surface_read_order.pending ~needs state.http_surface_reads=
         [Surface_read_order.Board;Surface_read_order.Planning]);
    Alcotest.(check bool) "matching owned posts are admitted once" true
      (take observed Surface_read_order.Board_posts);
    withdraw state;
    let withdrawn=state.http_surface_reads in
    Alcotest.(check bool) "remaining census cannot borrow withdrawn workspace or refresh authority" true
      (not (take observed Surface_read_order.Board_hearths)
       && state.http_surface_reads==withdrawn)) withdrawals

let test_board_census_distinguishes_unread_loading_empty_and_failure () =
  let open Masc_tui_types in
  let unread=create_state ~workspace:"census" ~local_base_path:"/workspace/census"
    ~port:0 ~refresh_interval:0. () in
  Alcotest.(check bool) "unread census has no observed zero or total" true
    (board_census_reading unread=(Masc_tui_fetched.Absent,false)
     && board_census_holding unread ~hearth:unread.board_hearth=None);
  List.iter (fun result ->
    let state,observed,ticket,authority,needs,request=board_dataset_fixture Surface_read_order.Navigation in
    Alcotest.(check bool) "initial owned census is loading without an invented empty result" true
      (board_census_reading state=(Masc_tui_fetched.Loading,true)
       && board_census_holding state ~hearth:state.board_hearth=None);
    if not (take_early_surface_dataset state ~ticket ~authority ~identity:observed
      ~request ~dataset:Surface_read_order.Board_hearths) then Alcotest.fail "census admission failed";
    apply_board_census_load state result;
    Alcotest.(check bool) "census settlement leaves posts and Planning pending" true
      (Surface_read_order.pending ~needs state.http_surface_reads=
        [Surface_read_order.Board;Surface_read_order.Planning]);
    (match result with
     | Ok census -> Alcotest.(check bool) "received empty is a known zero without a pending census" true
         (board_census_reading state=(Masc_tui_fetched.Ready census,false)
          && board_census_holding state ~hearth:state.board_hearth=Some 0)
     | Error detail -> Alcotest.(check bool) "first failure remains unavailable instead of empty" true
         (board_census_reading state=(Masc_tui_fetched.Failed detail,false)
          && board_census_holding state ~hearth:state.board_hearth=None))) [Ok [];Error "census endpoint unavailable"]

let test_board_census_retains_values_through_retry_failure_and_missing_result () =
  let open Masc_tui_types in
  let state,observed,ticket,authority,_,initial=board_dataset_fixture Surface_read_order.Full in
  let take request dataset=take_early_surface_dataset state ~ticket ~authority ~identity:observed ~request ~dataset in
  let census=["alpha",4;"beta",2] in
  if not (take initial Surface_read_order.Board_hearths) then Alcotest.fail "initial census not owned";
  apply_board_census_load state (Ok census);
  state.board_hearth <- Some "beta";
  Alcotest.(check bool) "received census supplies matching hearth total" true
    (board_census_holding state ~hearth:state.board_hearth=Some 2);
  let dispatch ()=
    let reads,request=Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs:{nothing with needs_board=true} ~started_ns:1L state.http_surface_reads in
    state.http_surface_reads <- reads;request in
  let retry=dispatch () in
  Alcotest.(check bool) "reread keeps navigation candidates but does not lend an old total" true
    (board_census_reading state=(Masc_tui_fetched.Ready census,true)
     && board_census_values state=census && board_census_holding state ~hearth:state.board_hearth=None);
  if not (take retry Surface_read_order.Board_hearths) then Alcotest.fail "retry census not owned";
  apply_board_census_load state (Error "census read failed");
  Alcotest.(check bool) "failure retains the actual census and diagnostic" true
    (board_census_reading state=(Masc_tui_fetched.Stale (census,"census read failed"),false)
     && board_census_values state=census && board_census_holding state ~hearth:state.board_hearth=None
     && state.board_hearth=Some "beta");
  let missing=dispatch () in
  Alcotest.(check bool) "retry does not erase the previous failure or retained value" true
    (board_census_reading state=(Masc_tui_fetched.Stale (census,"census read failed"),true));
  if not (take missing Surface_read_order.Board_posts) then Alcotest.fail "independent posts not owned";
  finish_http_surface_read state missing;
  Alcotest.(check bool) "collector exit without census records unavailability and keeps candidates" true
    ((match board_census_reading state with
      | Masc_tui_fetched.Stale (retained,_),false -> retained=census
      | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> false)
     && board_census_values state=census && board_census_holding state ~hearth:state.board_hearth=None
     && not (Surface_read_order.navigation_active state.http_surface_reads missing));
  let terminal=dispatch () in
  let datasets=take_http_surface_datasets state terminal in
  Alcotest.(check bool) "terminal ownership reservation cannot turn an unapplied census into fresh data" true
    (List.mem Surface_read_order.Board_hearths datasets
     && (match board_census_reading state with
         | Masc_tui_fetched.Stale (retained,_),false -> retained=census
         | (Absent | Loading | Ready _ | Stale _ | Failed _),_ -> false));
  apply_board_census_load state (Ok ["beta",5]);
  finish_http_surface_read state terminal;
  Alcotest.(check bool) "actual admitted terminal result restores received census availability" true
    (board_census_reading state=(Masc_tui_fetched.Ready ["beta",5],false)
     && board_census_holding state ~hearth:state.board_hearth=Some 5)

let test_board_census_old_cleanup_and_workspace_withdrawal () =
  let open Masc_tui_types in
  let state,observed,ticket,authority,_,initial=board_dataset_fixture Surface_read_order.Full in
  let take request=take_early_surface_dataset state ~ticket ~authority ~identity:observed
    ~request ~dataset:Surface_read_order.Board_hearths in
  if not (take initial) then Alcotest.fail "initial census not owned";
  apply_board_census_load state (Ok ["old",3]);
  let dispatch ()=
    let reads,request=Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs:{nothing with needs_board=true} ~started_ns:1L state.http_surface_reads in
    state.http_surface_reads <- reads;request in
  let retired=dispatch () in
  let current=dispatch () in
  finish_http_surface_read state retired;
  Alcotest.(check bool) "old collector cannot invent failure for the current pending census" true
    (board_census_reading state=(Masc_tui_fetched.Ready ["old",3],true)
     && Surface_read_order.navigation_active state.http_surface_reads current);
  if not (take current) then Alcotest.fail "current census not owned";
  apply_board_census_load state (Ok ["current",7]);
  finish_http_surface_read state initial;
  Alcotest.(check bool) "old cleanup cannot downgrade a received successor observation" true
    (board_census_reading state=(Masc_tui_fetched.Ready ["current",7],false)
     && board_census_holding state ~hearth:state.board_hearth=Some 7);
  suspend_workspace_readings state;
  finish_http_surface_read state current;
  Alcotest.(check bool) "workspace withdrawal removes census values and old ownership together" true
    (board_census_reading state=(Masc_tui_fetched.Absent,false)
     && board_census_values state=[] && board_census_holding state ~hearth:state.board_hearth=None && not (take current))

let test_dataset_admission_rejects_retired_workspace_and_refresh () =
  let open Masc_tui_types in
  let state = create_state ~workspace:"datasets" ~local_base_path:"/workspace/datasets"
      ~port:0 ~refresh_interval:0. () in
  let observed = identity "/workspace/datasets" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let ticket = state.http_refresh_order in
  let needs = {nothing with needs_planning=true} in
  let reads, request = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let take identity = take_early_surface_dataset state ~ticket ~authority ~identity
      ~request ~dataset:Surface_read_order.Planning_data in
  Alcotest.(check bool) "foreign response leaves the real source pending" true
    (not (take (identity "/workspace/foreign"))
     && Surface_read_order.pending ~needs state.http_surface_reads=[Surface_read_order.Planning]);
  state.workspace_identity <- Workspace_identity_match_unconfirmed "probe unavailable";
  Alcotest.(check bool) "unconfirmed authority cannot admit data" false (take observed);
  state.workspace_identity <- Workspace_identity_match;
  state.http_refresh_order <- Http_refresh_order.dispatch ticket;
  Alcotest.(check bool) "an older refresh cannot consume a current source" false (take observed);
  state.http_refresh_order <- ticket;
  Alcotest.(check bool) "navigation can settle with no enclosing full refresh" true
    (state.http_refresh_started_ns=None && take observed);
  let reads, successor = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
      ~needs ~started_ns:1L state.http_surface_reads in
  state.http_surface_reads <- reads;
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace retirement rejects the original authority" false
    (take_early_surface_dataset state ~ticket ~authority ~identity:observed
       ~request:successor ~dataset:Surface_read_order.Planning_data)

let with_response_decode_pool f =
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let previous = Domain_pool_ref.get () in
    Eio.Switch.on_release sw (fun () -> match previous with
      | Some pool -> Domain_pool_ref.set pool
      | None -> Domain_pool_ref.clear_for_tests ());
    let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
    Domain_pool_ref.set pool;
    f ()))

let test_response_decode_keeps_cache_and_typed_results () = with_response_decode_pool (fun () ->
  let caller = Domain.self () in
  let off_domain = Atomic.make true and parsed = Atomic.make 0 in
  let document = `Assoc ["version", `String "decode-worker";
    "paths", `Assoc ["effective_base_path", `String "/workspace/decode";
      "effective_masc_root", `String "/workspace/decode/.masc"];
    "startup", `Assoc ["state_ready", `Bool true]] in
  let reads = Masc_tui_kept_reads.create () in
  let read status =
    Alcotest.(check bool) "HTTP and cache callbacks stay on their caller" true (Domain.self ()=caller);
    Masc_tui_kept_reads.read reads ~address:"owned-health"
      ~send:(fun headers ->
        if status=304 then Alcotest.(check (option string)) "conditional read retains its entity tag"
          (Some "health-v1") (List.assoc_opt "If-None-Match" headers);
        Ok {Masc_tui_kept_reads.status; headers=["ETag","health-v1"];
          body=(if status=304 then "" else Yojson.Safe.to_string document)})
      ~decode:(fun response -> Masc_tui_response_decode.run ~name:"test.http.decode_wait" (fun () ->
        Atomic.incr parsed;
        Atomic.set off_domain (Atomic.get off_domain && Domain.self ()<>caller);
        Tui_decode.decode_json_response_body ~allow_empty:false
          ~status_code:response.status ~body:response.body)) in
  let decode = function
    | Error detail -> Alcotest.fail detail
    | Ok json -> Masc_tui_response_decode.run ~name:"test.identity.decode_wait" (fun () ->
        Atomic.set off_domain (Atomic.get off_domain && Domain.self ()<>caller);
        Tui_decode.decode_server_identity json) in
  let first = decode (read 200) in
  let unchanged = decode (read 304) in
  Alcotest.(check bool) "raw and typed interpretation run on the installed CPU worker" true
    (Atomic.get off_domain);
  Alcotest.(check int) "304 reuses parsed JSON without another raw decode" 1 (Atomic.get parsed);
  Alcotest.(check bool) "typed identity survives conditional reuse unchanged" true
    (first=unchanged && match first with
      | Ok value -> value.Tui_decode.sid_base_path="/workspace/decode"
      | Error _ -> false))

let test_decode_completion_cannot_consume_new_navigation () = with_response_decode_pool (fun () ->
  let open Masc_tui_types in
  let state = create_state ~workspace:"decode" ~local_base_path:"/workspace/decode"
      ~port:0 ~refresh_interval:0. () in
  let observed = identity "/workspace/decode" in
  state.server_identity <- Some observed;
  state.workspace_identity <- Workspace_identity_match;
  let authority = state.workspace_authority in
  let ticket = Http_refresh_order.dispatch state.http_refresh_order in
  begin_http_refresh_state state ~ticket ~started_ns:0L;
  let needs = {nothing with needs_overview_goals=true} in
  let reads, original = Surface_read_order.dispatch ~kind:Surface_read_order.Full
      ~needs ~started_ns:0L state.http_surface_reads in
  state.http_surface_reads <- reads;
  let started, start = Eio.Promise.create () and released, release = Eio.Promise.create () in
  let successor = ref None and caller = Domain.self () in
  Eio.Fiber.both
    (fun () ->
      let result = Masc_tui_response_decode.run ~name:"test.goals.decode_wait" (fun () ->
        Eio.Promise.resolve start (Domain.self ()<>caller);
        Eio.Promise.await released;
        Tui_decode.decode_overview_goals (`Assoc ["tree", `List []])) in
      Alcotest.(check bool) "the original immutable response finishes normally" true (result=Ok []);
      Alcotest.(check bool) "late decoding cannot consume a successor's dataset" false
        (take_early_surface_dataset state ~ticket ~authority ~identity:observed
          ~request:original ~dataset:Surface_read_order.Overview_goals_data))
    (fun () ->
      Alcotest.(check bool) "UI can navigate while the actual worker is waiting" true
        (Eio.Promise.await started);
      let reads, request = Surface_read_order.dispatch ~kind:Surface_read_order.Navigation
          ~needs ~started_ns:1L state.http_surface_reads in
      state.http_surface_reads <- reads;
      successor := Some request;
      Eio.Promise.resolve release ());
  let successor = match !successor with Some request -> request
    | None -> Alcotest.fail "navigation was not dispatched" in
  Alcotest.(check bool) "the new dataset retains its original admission authority" true
    (take_early_surface_dataset state ~ticket ~authority ~identity:observed
      ~request:successor ~dataset:Surface_read_order.Overview_goals_data))

exception Response_decode_failed

let test_response_decode_preserves_nested_failures () = with_response_decode_pool (fun () ->
  let malformed = "{" in
  let expected = Tui_decode.decode_json_response_body ~allow_empty:false ~status_code:200 ~body:malformed in
  let actual = Masc_tui_response_decode.run ~name:"test.invalid.decode_wait" (fun () ->
    Tui_decode.decode_json_response_body ~allow_empty:false ~status_code:200 ~body:malformed) in
  Alcotest.(check bool) "malformed JSON keeps its original error" true
    (Result.is_error expected && expected=actual);
  let outer, inner = Masc_tui_response_decode.run ~name:"test.outer.decode_wait" (fun () ->
    let outer = Domain.self () in
    outer, Masc_tui_response_decode.run ~name:"test.inner.decode_wait" Domain.self) in
  Alcotest.(check bool) "nested decoding stays on the original single worker" true (outer=inner);
  let attempts = Atomic.make 0 in
  (match Masc_tui_response_decode.run ~name:"test.raised.decode_wait" (fun () ->
      Atomic.incr attempts; raise Response_decode_failed) with
   | _ -> Alcotest.fail "decoder exception was swallowed"
   | exception Response_decode_failed -> ());
  Alcotest.(check int) "decoder failure is not replayed" 1 (Atomic.get attempts))

let test_response_decode_without_runtime_stays_synchronous () =
  let previous = Domain_pool_ref.get () in
  Fun.protect ~finally:(fun () -> match previous with
    | Some pool -> Domain_pool_ref.set pool | None -> Domain_pool_ref.clear_for_tests ()) (fun () ->
    Domain_pool_ref.clear_for_tests ();
    let caller = Domain.self () in
    Alcotest.(check bool) "no-pool non-Eio callers retain their synchronous API" true
      (Masc_tui_response_decode.run ~name:"test.sync.decode_wait" Domain.self=caller))

let creation_state () =
  let state = Masc_tui_types.create_state ~workspace:"creation"
      ~local_base_path:"/workspace/creation" ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Masc_tui_types.Workspace_identity_match;
  state.server_identity <- Some (identity "/workspace/creation");
  state

let creation_request state name declaration =
  let open Masc_tui_types in
  state.keeper_creation_draft <- Some declaration;
  state.keeper_creation_draft_owner <- ref ();
  match begin_keeper_creation state ~keeper_name:name ~declaration
      ~return_to:Keeper_chat_return_home ~started_ns:0L with
  | Ok request -> request
  | Error detail -> Alcotest.fail detail

let test_creation_interleaving_preserves_new_draft_and_focus () =
  let open Masc_tui_types in
  let state = creation_state () in
  let first = creation_request state "first" "first declaration" in
  Alcotest.(check bool) "one pending mutation per target" true
    (Result.is_error (begin_keeper_creation state ~keeper_name:"first"
       ~declaration:"duplicate" ~return_to:Keeper_chat_return_home ~started_ns:1L));
  let second = creation_request state "second" "second declaration" in
  Alcotest.(check bool) "first POST phase is admitted" true
    (apply_keeper_creation_status state first Creation_posting);
  Alcotest.(check bool) "first receipt is retained" true
    (apply_keeper_creation_status state first (Creation_finished Creation_created));
  Alcotest.(check bool) "earlier success cannot clear a newly edited declaration" false
    (clear_created_keeper_draft state first);
  Alcotest.(check (option string)) "later declaration remains editable"
    (Some "second declaration") state.keeper_creation_draft;
  Alcotest.(check bool) "earlier receipt cannot consume successor focus" false
    (take_keeper_creation_focus state first);
  Alcotest.(check bool) "late progress cannot reopen completed creation" false
    (apply_keeper_creation_status state first Creation_posting);
  Alcotest.(check bool) "successor receipt is admitted" true
    (apply_keeper_creation_status state second (Creation_finished Creation_created));
  Alcotest.(check bool) "successor owns its focus" true
    (take_keeper_creation_focus state second);
  Alcotest.(check bool) "confirmed successor clears only its own draft" true
    (clear_created_keeper_draft state second);
  Alcotest.(check bool) "duplicate receipt cannot apply twice" false
    (apply_keeper_creation_status state second (Creation_finished Creation_created))

let test_creation_receipt_retains_original_scope_after_withdrawal () =
  let open Masc_tui_types in
  let state = creation_state () in
  let original = creation_request state "same-name" "original declaration" in
  ignore (apply_keeper_creation_status state original Creation_posting);
  suspend_workspace_readings state;
  Alcotest.(check bool) "read retirement does not consume the operation receipt" true
    (apply_keeper_creation_status state original
       (Creation_finished (Creation_unconfirmed "interrupted after POST began")));
  let Workspace_authority epoch = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (epoch + 1);
  state.server_identity <- Some (identity "/workspace/other");
  let successor = creation_request state "same-name" "other workspace declaration" in
  (* Even an A -> B -> A path match cannot authorize the old request. *)
  state.workspace_authority <- Workspace_authority (epoch + 2);
  state.server_identity <- Some original.kcr_workspace;
  Alcotest.(check bool) "returning to a path does not restore original authority" false
    (keeper_creation_origin_current state original);
  Alcotest.(check bool) "old receipt cannot clear another declaration" false
    (clear_created_keeper_draft state original);
  Alcotest.(check bool) "old receipt cannot consume successor focus" false
    (take_keeper_creation_focus state original);
  Alcotest.(check bool) "successor remains pending under its own ticket" true
    (List.exists (fun attempt -> attempt.kca_request.kcr_token == successor.kcr_token
       && attempt.kca_status = Creation_checking) state.keeper_creations);
  Alcotest.(check bool) "uncertain original retains its declaration and scope" true
    (List.exists (fun attempt -> attempt.kca_request.kcr_token == original.kcr_token
       && attempt.kca_declaration = Some "original declaration"
       && attempt.kca_status = Creation_finished (Creation_unconfirmed "interrupted after POST began"))
       state.keeper_creations)

let test_creation_unknown_requires_explicit_create_only_retry () =
  let open Masc_tui_types in
  let state = creation_state () in
  let unsent = creation_request state "preflight" "unsent declaration" in
  ignore (apply_keeper_creation_status state unsent
    (Creation_finished (Creation_not_sent "identity unavailable")));
  Alcotest.(check bool) "unsent request cannot clear its draft" false
    (clear_created_keeper_draft state unsent);
  let original = creation_request state "retry" "retained declaration" in
  ignore (apply_keeper_creation_status state original Creation_posting);
  state.keeper_creation_focus <- None;
  ignore (apply_keeper_creation_status state original
    (Creation_finished (Creation_unconfirmed "response lost")));
  Alcotest.(check bool) "input detaches late auto-navigation" false
    (take_keeper_creation_focus state original);
  Alcotest.(check (option string)) "unconfirmed declaration can reopen in editor"
    (Some "retained declaration") (keeper_creation_recovery_draft state);
  Alcotest.(check bool) "unconfirmed is not retroactively called successful" false
    (apply_keeper_creation_status state original (Creation_finished Creation_created));
  let retry = creation_request state "retry" "explicitly edited declaration" in
  ignore (apply_keeper_creation_status state retry (Creation_finished Creation_created));
  Alcotest.(check bool) "explicit success releases only resolved target retry bodies" true
    (List.for_all (fun attempt ->
       if String.equal attempt.kca_request.kcr_keeper "retry"
       then Option.is_none attempt.kca_declaration else Option.is_some attempt.kca_declaration)
       state.keeper_creations);
  Alcotest.(check bool) "original uncertainty receipt remains" true
    (List.exists (fun attempt -> attempt.kca_request.kcr_token == original.kcr_token
       && attempt.kca_status = Creation_finished (Creation_unconfirmed "response lost"))
       state.keeper_creations)

let test_creation_receipt_survives_full_notification_queue_cancel () =
  let open Masc_tui_types in
  let exception Creation_test_cancelled in
  Eio_main.run (fun _ -> Eio.Switch.run (fun sw ->
    let state = creation_state () in
    let request = creation_request state "queued" "original declaration" in
    let notifications = Eio.Stream.create 1 in
    Eio.Stream.add notifications ();
    let entered, enter = Eio.Promise.create () in
    let published, publish = Eio.Promise.create () in
    let finished, finish = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      try Eio.Cancel.sub (fun context ->
        Eio.Promise.resolve enter context;
        ignore (publish_keeper_creation_status request ~observed_ns:1L Creation_posting);
        ignore (publish_keeper_creation_status request ~observed_ns:2L
          (Creation_finished Creation_created));
        Eio.Promise.resolve publish ();
        (* Same bounded notification boundary as the creation worker. It must
           remain cancellable after its immutable terminal result is published. *)
        Eio.Stream.add notifications ())
      with Eio.Cancel.Cancelled Creation_test_cancelled -> Eio.Promise.resolve finish ());
    let context = Eio.Promise.await entered in
    Eio.Promise.await published;
    Eio.Cancel.cancel context Creation_test_cancelled;
    Eio.Promise.await finished;
    match List.nth_opt (pending_keeper_creation_receipts state) 0 with
    | None -> Alcotest.fail "cancellation lost the original mutation receipt"
    | Some (owner, status, ready_at_ns) ->
      Alcotest.(check bool) "receipt keeps the original owner" true
        (owner.kcr_token == request.kcr_token);
      Alcotest.(check int64) "receipt uses publication time" 2L ready_at_ns;
      Alcotest.(check bool) "cancellation cannot downgrade a confirmed receipt" false
        (publish_keeper_creation_status request ~observed_ns:3L
          (Creation_finished (Creation_unconfirmed "notification cancelled")));
      Alcotest.(check bool) "UI can admit the original receipt without its notification" true
        (apply_keeper_creation_status state owner status);
      Alcotest.(check bool) "terminal pending slot is retired" true
        ((pending_keeper_creation_receipts state=[]));
      Alcotest.(check bool) "only the confirmed original form is cleared" true
        (clear_created_keeper_draft state owner)))

let keeper_log_fixture () =
  let state, keeper, _ = local_keeper_source_fixture () in
  state.keepers <- [keeper];
  state.view <- Masc_tui_types.Keepers Masc_tui_types.Keeper_logs;
  state, keeper

let keeper_log_request state keeper intent =
  match Masc_tui_types.begin_keeper_log_read state ~intent ~limit:4 ~started_ns:0L keeper with
  | Some request -> request
  | None -> Alcotest.fail "selected Keeper metrics request was not admitted"

let keeper_log_snapshot_fixture ?(partial=false) name count =
  let json = `Assoc [
    "schema", `String Masc.Keeper_metrics_record.schema;
    "record_kind", `String "heartbeat";
    "ts", `String "2026-08-21T12:00:00Z"; "ts_unix", `Float 1787313600.0;
    "channel", `String "heartbeat"; "name", `String name;
    "trace_id", `String "fixture"; "message_count", `Int count ] in
  Masc_tui_metrics_tail.resolve_with ~expected_keeper:name ~limit:4
    ~read_recent:(fun _ -> Ok ([Dated_jsonl.Parsed json] @ if partial then
      [Dated_jsonl.Malformed_json {path="fixture.jsonl"; line_number=Some 2; detail="broken row"}]
      else []))

let test_keeper_log_selection_and_late_cleanup_keep_original_owner () =
  let open Masc_tui_types in
  let state, first = keeper_log_fixture () in
  let second = { first with k_name = "beta" } in
  state.keepers <- [first; second];
  let initial = keeper_log_request state first Snapshot_read.Poll in
  let cancelled = ref 0 in
  supersede_keeper_log_read state (Some (initial.klr_owner, fun () -> incr cancelled));
  state.keeper_cursor <- 1;
  Alcotest.(check bool) "new selection cannot borrow another Keeper's observation" true
    (keeper_logs_view state = Masc_tui_fetched.Absent);
  let successor = keeper_log_request state second Snapshot_read.Poll in
  supersede_keeper_log_read state (Some (successor.klr_owner, fun () -> ()));
  Alcotest.(check int) "selection change cancels the prior read once" 1 !cancelled;
  finish_keeper_log_read state initial;
  Alcotest.(check bool) "old cleanup cannot release successor cancellation ownership" true
    (Option.exists (fun (owner, _) -> owner == successor.klr_owner) state.keeper_log_cancel);
  Alcotest.(check bool) "late first result cannot settle successor" true
    (Option.is_none (take_keeper_log_read state initial
      (Ok (keeper_log_snapshot_fixture first.k_name 1))));
  Alcotest.(check bool) "successor settles its own actual row" true
    (Option.is_some (take_keeper_log_read state successor
      (Ok (keeper_log_snapshot_fixture second.k_name 2))));
  Alcotest.(check (list (option int))) "only selected Keeper data is exposed" [Some 2]
    (List.map (fun (entry : Tui_decode.log_entry) -> entry.le_message_count)
       (keeper_log_snapshot state).entries);
  state.keeper_cursor <- 0;
  let returned = keeper_log_request state first Snapshot_read.Poll in
  Alcotest.(check bool) "returning to a Keeper does not restore the earlier ticket" true
    (Option.is_none (take_keeper_log_read state initial (Error "late original failure")));
  Alcotest.(check bool) "returned Keeper owns a new request" true
    (Masc_tui_fetched.is_current ~equal:keeper_log_equal_key state.keeper_logs returned.klr_request)

let test_keeper_log_refresh_coalesces_and_failed_revalidation_keeps_partial_rows () =
  let open Masc_tui_types in
  let state, keeper = keeper_log_fixture () in
  state.view <- Keepers Keeper_detail;
  state.detail_tab <- Detail_secrets;
  Alcotest.(check bool) "a detail tab without metrics admits no disk request" true
    (Option.is_none (begin_keeper_log_read state ~intent:Snapshot_read.Poll ~limit:4 ~started_ns:0L keeper));
  state.detail_tab <- Detail_info;
  let active = keeper_log_request state keeper Snapshot_read.Poll in
  List.iter (fun intent ->
    Alcotest.(check bool) "same source shares the active read" true
      (Option.is_none (begin_keeper_log_read state ~intent ~limit:4 ~started_ns:1L keeper)))
    [Snapshot_read.Poll; Refresh; Refresh; Poll];
  let partial = keeper_log_snapshot_fixture ~partial:true keeper.k_name 3 in
  let admission = take_keeper_log_read state active (Ok partial) in
  Alcotest.(check bool) "refresh burst requests one followup at settlement" true
    (Option.exists (fun admitted -> admitted.kla_followup) admission);
  Alcotest.(check bool) "settlement consumes queued demand once" false state.keeper_log_refresh_pending;
  let followup = keeper_log_request state keeper Snapshot_read.Poll in
  Alcotest.(check bool) "same-source refresh retains the observed partial snapshot" true
    (List.length (keeper_log_snapshot state).entries = 1
     && Option.is_some (keeper_log_snapshot state).error);
  let failed = take_keeper_log_read state followup (Error "storage is temporarily unreadable") in
  Alcotest.(check bool) "no new demand means no repeated followup" false
    (Option.exists (fun admitted -> admitted.kla_followup) failed);
  (match keeper_logs_view state with
   | Masc_tui_fetched.Stale (snapshot, _) ->
       Alcotest.(check int) "failure preserves observed rows" 1 (List.length snapshot.entries);
       (match snapshot.error with
        | Some (Masc_tui_metrics_tail.Row_errors _) -> ()
        | None | Some (Storage_error _ | Remote_workspace | Workspace_unconfirmed) ->
            Alcotest.fail "partial-row provenance was lost")
   | Absent | Loading | Ready _ | Failed _ -> Alcotest.fail "failed revalidation was called fresh or empty");
  Alcotest.(check bool) "duplicate completion cannot schedule a second followup" true
    (Option.is_none (take_keeper_log_read state followup (Ok partial)))

let test_keeper_log_suspension_preserves_snapshot_without_old_authority () =
  let open Masc_tui_types in
  let state, keeper = keeper_log_fixture () in
  let initial = keeper_log_request state keeper Snapshot_read.Poll in
  ignore (take_keeper_log_read state initial (Ok (keeper_log_snapshot_fixture keeper.k_name 4)));
  let old = keeper_log_request state keeper Snapshot_read.Refresh in
  let cancelled = ref 0 in
  supersede_keeper_log_read state (Some (old.klr_owner, fun () -> incr cancelled));
  state.workspace_identity <- Workspace_identity_match_unconfirmed "probe failed";
  suspend_workspace_readings state;
  Alcotest.(check int) "workspace suspension cancels metrics ownership" 1 !cancelled;
  (match keeper_logs_view state with
   | Masc_tui_fetched.Stale (snapshot, _) -> Alcotest.(check int) "last observation remains" 1 (List.length snapshot.entries)
   | Absent | Loading | Ready _ | Failed _ -> Alcotest.fail "withdrawal lost or promoted the old observation");
  Alcotest.(check bool) "retired read cannot consume its successor epoch" true
    (Option.is_none (take_keeper_log_read state old (Error "old scope failed")));
  state.workspace_identity <- Workspace_identity_match;
  let fresh = keeper_log_request state keeper Snapshot_read.Poll in
  Alcotest.(check bool) "same workspace can revalidate its retained rows" true
    (List.length (keeper_log_snapshot state).entries = 1);
  Alcotest.(check bool) "new read scope admits its own result" true
    (Option.is_some (take_keeper_log_read state fresh (Ok (keeper_log_snapshot_fixture keeper.k_name 5))));
  let Workspace_authority epoch = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (epoch + 1);
  Alcotest.(check bool) "same path in another workspace authority cannot borrow rows" true
    (keeper_logs_view state = Masc_tui_fetched.Absent);
  clear_keeper_logs state;
  state.keepers <- [];
  Alcotest.(check bool) "missing selection admits no filesystem request" true
    (Option.is_none (begin_keeper_log_read state ~intent:Snapshot_read.Poll ~limit:4 ~started_ns:2L keeper))

let keeper_settings_fixture () =
  let open Masc_tui_types in
  let state, keeper = keeper_log_fixture () in
  state.view <- Keepers Keeper_detail;
  state.detail_tab <- Detail_instructions;
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity state.local_base_path);
  state, keeper

let keeper_settings_request state =
  match Masc_tui_types.begin_keeper_settings_editor state ~available:true ~started_ns:10L with
  | Some request -> request | None -> Alcotest.fail "settings preparation did not start"

let keeper_settings_snapshot () : Masc_tui_types.keeper_settings_snapshot =
  let observed = `Assoc [
    "config_revision", `Assoc ["manifest",`Assoc ["state",`String "sha256";"value",`String (String.make 64 'a')];
      "runtime_assignment",`Assoc ["state",`String "runtime_config_missing"]];
    "activation_mode",`String "autonomous";"prompt",`Assoc ["instructions",`String "original"]] in
  {kss_observed=observed;kss_stem=Masc_tui_keeper_config.editor_stem observed}

let test_settings_preparation_hands_off_original_snapshot_once () =
  let open Masc_tui_types in
  let state, keeper = keeper_settings_fixture () in
  let request = keeper_settings_request state in
  let take ~input_pending = take_ready_keeper_settings_editor state ~available:true ~input_pending in
  Alcotest.(check bool) "explicit repeated edit shares the pending read without opening an editor" true
    (Option.is_none (begin_keeper_settings_editor state ~available:true ~started_ns:11L)
      && Option.is_none (take ~input_pending:false));
  let snapshot = keeper_settings_snapshot () in
  finish_keeper_settings_worker state request;
  Alcotest.(check bool) "only the original request admits its frozen source" true
    (take_keeper_settings_editor_read state request (Ok snapshot));
  Alcotest.(check bool) "queued input defers handoff and repeated edit does not restart a ready read" true
    (Option.is_none (take ~input_pending:true)
      && Option.is_none (begin_keeper_settings_editor state ~available:true ~started_ns:12L)
      && Option.exists (fun current -> current.ksr_owner==request.ksr_owner) state.keeper_settings_intent);
  state.keeper_config_view <- Some (keeper.k_name,["later rendered observation"]);
  let original, document = match take ~input_pending:false with
    | Some value -> value | None -> Alcotest.fail "ready source did not reach the same editor intent" in
  Alcotest.(check bool) "handoff consumes exactly one original intent" true
    (original.ksr_owner==request.ksr_owner && document=snapshot
      && Option.is_none state.keeper_settings_intent && Option.is_none (take ~input_pending:false));
  let edited = match Yojson.Safe.from_string document.kss_stem with
    | `Assoc fields -> `Assoc (("instructions",`String "edited")::List.remove_assoc "instructions" fields)
    | _ -> Alcotest.fail "editor source was not an object" in
  let patch = match Masc_tui_keeper_config.patch_of_edit ~before:document.kss_observed ~after:edited with
    | Ok patch -> patch | Error detail -> Alcotest.fail (Masc_tui_keeper_config.edit_refusal_to_string detail) in
  let member = Yojson.Safe.Util.member in
  Alcotest.(check bool) "actual editor patch retains the opening revision and only the changed field" true
    (member "expected_config_revision" patch=member "config_revision" snapshot.kss_observed
      && member "instructions" patch=`String "edited" && member "activation_mode" patch=`Null);
  let failed = keeper_settings_request state in
  Alcotest.(check bool) "read failure cannot reopen the earlier successful document" true
    (take_keeper_settings_editor_read state failed (Error "endpoint unavailable")
      && Option.is_none (take ~input_pending:false));
  let retry = keeper_settings_request state in
  Alcotest.(check bool) "explicit retry owns a fresh read and late prior success cannot complete it" true
    (Masc_tui_fetched.request_id retry.ksr_request > Masc_tui_fetched.request_id failed.ksr_request
      && not (take_keeper_settings_editor_read state failed (Ok snapshot))
      && Option.is_none (take ~input_pending:false));
  Alcotest.(check bool) "fresh retry can hand off after its own result arrives" true
    (take_keeper_settings_editor_read state retry (Ok snapshot)
      && Option.is_some (take ~input_pending:false))

let test_settings_preparation_retires_focus_and_workspace_owners () =
  let open Masc_tui_types in
  let state, keeper = keeper_settings_fixture () in
  let second = {keeper with k_name="beta"} in
  state.keepers <- [keeper;second];
  let original = keeper_settings_request state in
  let original_cancelled = ref 0 in
  supersede_keeper_settings_read state (Some (original.ksr_owner,fun () -> incr original_cancelled));
  state.keeper_cursor <- 1;
  Alcotest.(check bool) "moving selection cancels the original preparation" true
    (reconcile_keeper_settings_editor state ~available:true && !original_cancelled=1);
  let successor = keeper_settings_request state in
  let successor_cancelled = ref 0 in
  supersede_keeper_settings_read state (Some (successor.ksr_owner,fun () -> incr successor_cancelled));
  finish_keeper_settings_worker state original;
  Alcotest.(check bool) "late completion and cleanup cannot consume successor cancellation or its result" true
    (not (take_keeper_settings_editor_read state original (Ok (keeper_settings_snapshot ())))
      && Option.exists (fun (owner,_) -> owner==successor.ksr_owner) state.keeper_settings_cancel
      && Option.exists (fun owner -> owner.ksr_owner==successor.ksr_owner) state.keeper_settings_intent);
  state.workspace_read_authority <- ref ();
  state.workspace_identity <- Workspace_identity_match_unconfirmed "probe unavailable";
  suspend_workspace_readings state;
  Alcotest.(check bool) "workspace read withdrawal cancels the worker and clears private editor data" true
    (!successor_cancelled=1 && Option.is_none state.keeper_settings_intent
      && Option.is_none state.keeper_settings_cancel
      && Option.is_none (Masc_tui_fetched.current state.keeper_settings_editor)
      && not (take_keeper_settings_editor_read state successor (Ok (keeper_settings_snapshot ()))));
  state.workspace_identity <- Workspace_identity_match;
  state.keeper_cursor <- 0;
  let active = keeper_settings_request state in
  ignore (take_keeper_settings_editor_read state active (Ok (keeper_settings_snapshot ())));
  Alcotest.(check bool) "another input owner withdraws a ready editor rather than opening over it" true
    (Option.is_none (take_ready_keeper_settings_editor state ~available:false ~input_pending:false)
      && Option.is_none state.keeper_settings_intent);
  let active = keeper_settings_request state in
  state.detail_tab <- Detail_info;
  Alcotest.(check bool) "tab navigation retires the opening intent" true
    (reconcile_keeper_settings_editor state ~available:true
      && not (take_keeper_settings_editor_read state active (Error "old tab")));
  let active = keeper_settings_request state in
  state.view <- Keepers Keeper_list;
  Alcotest.(check bool) "switching list/detail cannot restore a previous editor request" true
    (reconcile_keeper_settings_editor state ~available:true
      && not (take_keeper_settings_editor_read state active (Ok (keeper_settings_snapshot ()))));
  let active = keeper_settings_request state in
  state.server_identity <- Some {(identity state.local_base_path) with sid_masc_root="/other/.masc"};
  Alcotest.(check bool) "same base path with different runtime root cannot borrow the document" true
    (reconcile_keeper_settings_editor state ~available:true
      && not (take_keeper_settings_editor_read state active (Ok (keeper_settings_snapshot ()))))

let settings_editor_text (request : Masc_tui_types.keeper_settings_save_request) =
  match request.ksv_input with
  | Masc_tui_types.Settings_editor_input draft -> draft.ksd_text
  | Sandbox_shortcut_input _ -> Alcotest.fail "editor input replaced by a shortcut"

let keeper_settings_save_fixture () =
  let open Masc_tui_types in
  let state,keeper = keeper_settings_fixture () in
  let origin = keeper_settings_request state and snapshot = keeper_settings_snapshot () in
  ignore (take_keeper_settings_editor_read state origin (Ok snapshot));
  ignore (take_ready_keeper_settings_editor state ~available:true ~input_pending:false);
  let edited = {|{"instructions":"operator input","max_context_override":1024,"confirm_context_shrink":true}|} in
  let patch = match Masc_tui_keeper_config.patch_of_edit ~before:snapshot.kss_observed
    ~after:(Yojson.Safe.from_string edited) with
    | Ok patch -> patch | Error refusal -> Alcotest.fail (Masc_tui_keeper_config.edit_refusal_to_string refusal) in
  let draft = {ksd_snapshot=snapshot;ksd_text=edited;ksd_patch=patch} in
  let request = match begin_keeper_settings_save state ~origin ~draft ~started_ns:20L with
    | Ok request -> request | Error detail -> Alcotest.fail detail in
  state,keeper,origin,draft,request

let test_settings_save_keeps_receipt_through_withdrawal () =
  let open Masc_tui_types in
  let state,_,origin,draft,request = keeper_settings_save_fixture () in
  Alcotest.(check bool) "repeat edit shares the admitted save" true
    (Option.is_none (begin_keeper_settings_editor state ~available:true ~started_ns:21L));
  Alcotest.(check bool) "duplicate dispatch refused" true
    (Result.is_error (begin_keeper_settings_save state ~origin
      ~draft ~started_ns:22L));
  ignore (publish_keeper_settings_save request ~observed_ns:23L (Settings_posting {ksp_snapshot=draft.ksd_snapshot.kss_observed;ksp_patch=Some draft.ksd_patch}));
  state.view <- Overview;
  state.workspace_read_authority <- ref ();
  let Workspace_authority epoch = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (epoch+1);
  ignore (publish_keeper_settings_save request ~observed_ns:24L
    (Settings_finished (Some {ksp_snapshot=draft.ksd_snapshot.kss_observed;ksp_patch=Some draft.ksd_patch},Settings_unconfirmed "connection ended after possible dispatch")));
  let recovered = match List.nth_opt (pending_keeper_settings_save_receipts state) 0 with
    | Some (owner,status,_) -> owner.ksv_token == request.ksv_token && apply_keeper_settings_save state owner status
    | None -> false in
  Alcotest.(check bool) "receipt survives navigation and read withdrawal without a mailbox" true recovered;
  Alcotest.(check bool) "receipt grants no current workspace authority" false
    (keeper_settings_save_current state request);
  Alcotest.(check string) "original edited bytes retained" draft.ksd_text
    (settings_editor_text (List.hd (Keeper_settings_saves.all state.keeper_settings_saves)).ksa_request);
  Alcotest.(check bool) "terminal outcome cannot restart or be replaced by a late receipt" false
    (publish_keeper_settings_save request ~observed_ns:25L (Settings_posting {ksp_snapshot=draft.ksd_snapshot.kss_observed;ksp_patch=Some draft.ksd_patch}))

let test_settings_save_recovers_changes_on_fresh_revision () =
  let open Masc_tui_types in
  let state,_,_,draft,request = keeper_settings_save_fixture () in
  let outcome = Settings_finished (None,Settings_unconfirmed "write response missing") in
  ignore (publish_keeper_settings_save request ~observed_ns:21L outcome);
  ignore (apply_keeper_settings_save state request outcome);
  let origin = keeper_settings_request state in
  let retained = match keeper_settings_recovery state (Masc_tui_fetched.request_key origin.ksr_request) with
    | Some draft -> draft | None -> Alcotest.fail "retained settings absent" in
  let replace key value = function
    | `Assoc fields -> `Assoc ((key,value) :: List.remove_assoc key fields)
    | _ -> Alcotest.fail "fixture is not an object" in
  let current = retained.ksd_snapshot.kss_observed
    |> replace "activation_mode" (`String "manual")
    |> replace "max_context_override" (`Int 4096)
    |> replace "config_revision" (`Assoc [
       "manifest",`Assoc ["state",`String "sha256";"value",`String (String.make 64 'b')];
       "runtime_assignment",`Assoc ["state",`String "runtime_config_missing"]]) in
  let edited = match Masc_tui_keeper_config.reopen_edit_on_current
    ~before:retained.ksd_snapshot.kss_observed ~edited:retained.ksd_text ~current with
    | Ok text -> text | Error refusal -> Alcotest.fail (Masc_tui_keeper_config.edit_refusal_to_string refusal) in
  let json = Yojson.Safe.from_string edited in
  Alcotest.(check bool) "only operator changes overlay current settings" true
    (Yojson.Safe.Util.member "instructions" json = `String "operator input"
     && Yojson.Safe.Util.member "activation_mode" json = `String "manual");
  Alcotest.(check bool) "fresh context requires a new shrink confirmation" true
    (Yojson.Safe.Util.member "confirm_context_shrink" json = `Null);
  let patch = match Masc_tui_keeper_config.patch_of_edit ~before:current ~after:json with
    | Ok patch -> patch | Error refusal -> Alcotest.fail (Masc_tui_keeper_config.edit_refusal_to_string refusal) in
  Alcotest.(check bool) "new patch uses current composite revision" true
    (Yojson.Safe.Util.member "expected_config_revision" patch = Yojson.Safe.Util.member "config_revision" current);
  let snapshot = {kss_observed=current;kss_stem=Masc_tui_keeper_config.editor_stem current} in
  ignore (take_keeper_settings_editor_read state origin (Ok snapshot));
  ignore (take_ready_keeper_settings_editor state ~available:true ~input_pending:false);
  let successor = match begin_keeper_settings_save state ~origin
    ~draft:{ksd_snapshot=snapshot;ksd_text=edited;ksd_patch=patch} ~started_ns:30L with
    | Ok successor -> successor | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "late original receipt cannot finish the successor" false
    (apply_keeper_settings_save state request (Settings_finished (None,Settings_applied {
      response=`Null;severity="system";message="late"})));
  Alcotest.(check bool) "successor retains its own edited input" true
    ((List.hd (Keeper_settings_saves.all state.keeper_settings_saves)).ksa_request.ksv_token == successor.ksv_token
     && (List.hd (Keeper_settings_saves.all state.keeper_settings_saves)).ksa_status = Settings_checking);
  Alcotest.(check string) "recovery never rewrites original request text" retained.ksd_text draft.ksd_text

let test_settings_save_not_sent_preserves_origin_input () =
  let open Masc_tui_types in
  let state,_,origin,draft,request = keeper_settings_save_fixture () in
  let finished = Settings_finished (None,Settings_not_sent "worker not entered") in
  ignore (apply_keeper_settings_save state request finished);
  state.workspace_read_authority <- ref ();
  Alcotest.(check bool) "withdrawn editor authority cannot dispatch" true
    (Result.is_error (begin_keeper_settings_save state ~origin
      ~draft ~started_ns:30L));
  let retained = List.hd (Keeper_settings_saves.all state.keeper_settings_saves) in
  Alcotest.(check bool) "refused origin keeps a recoverable unposted operation" true
    (retained.ksa_recoverable && match retained.ksa_status with
     | Settings_finished (_,Settings_not_sent _) -> true
     | Settings_checking | Settings_reading | Settings_posting _ | Settings_finished (_, (Settings_applied _
         | Settings_unchanged | Settings_refused _ | Settings_observation_required _ | Settings_unconfirmed _)) -> false);
  Alcotest.(check string) "exact refused input survives" draft.ksd_text (settings_editor_text retained.ksa_request)

let sandbox_save_snapshot profile =
  let observed = (keeper_settings_snapshot ()).Masc_tui_types.kss_observed in
  match observed with
  | `Assoc fields -> `Assoc (("sandbox_profile",`String (Keeper_sandbox_config.sandbox_profile_to_string profile)) :: fields)
  | _ -> Alcotest.fail "invalid settings fixture"

let test_sandbox_shortcut_uses_observed_revision () =
  let snapshot = sandbox_save_snapshot Keeper_sandbox_config.Docker in
  let patch = match Masc_tui_keeper_config.sandbox_patch ~profile:Keeper_sandbox_config.Remote_ssh snapshot with
    | Ok (Some patch) -> patch | Ok None -> Alcotest.fail "profile change disappeared"
    | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "shortcut sends only the selected profile and observed revision" true
    (match patch with
     | `Assoc fields -> List.length fields=2
         && List.assoc_opt "sandbox_profile" fields = Some (`String "remote_ssh")
         && List.assoc_opt "expected_config_revision" fields = Some (Yojson.Safe.Util.member "config_revision" snapshot)
     | _ -> false);
  Alcotest.(check bool) "already selected profile needs no write" true
    (Masc_tui_keeper_config.sandbox_patch ~profile:Keeper_sandbox_config.Docker snapshot = Ok None);
  let invalid = match snapshot with
    | `Assoc fields -> `Assoc (("config_revision",`Assoc ["state",`String "unavailable";"detail",`String "unread"])
        :: List.remove_assoc "config_revision" fields)
    | _ -> Alcotest.fail "invalid fixture" in
  Alcotest.(check bool) "no-change success cannot hide missing revision authority" true
    (Result.is_error (Masc_tui_keeper_config.sandbox_patch ~profile:Keeper_sandbox_config.Docker invalid))

let test_sandbox_and_editor_saves_share_pending_ownership () =
  let open Masc_tui_types in
  let state,_,_,draft,editor = keeper_settings_save_fixture () in
  state.detail_tab <- Detail_sandbox;
  Alcotest.(check bool) "shortcut cannot race the same Keeper's editor save" true
    (Result.is_error (begin_keeper_sandbox_save state ~profile:Keeper_sandbox_config.Remote_ssh ~started_ns:21L));
  let refused = Settings_finished (None,Settings_not_sent "editor write not entered") in
  ignore (publish_keeper_settings_save editor ~observed_ns:22L refused);
  ignore (apply_keeper_settings_save state editor refused);
  let shortcut = match begin_keeper_sandbox_save state ~profile:Keeper_sandbox_config.Remote_ssh ~started_ns:23L with
    | Ok request -> request | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "another backend key cannot rewrite pending absolute intent" true
    (Result.is_error (begin_keeper_sandbox_save state ~profile:Keeper_sandbox_config.Micro_vm ~started_ns:24L)
     && shortcut.ksv_input = Sandbox_shortcut_input Keeper_sandbox_config.Remote_ssh);
  Alcotest.(check bool) "shortcut does not discard unrelated retained editor changes" true
    (Option.map (fun draft -> draft.ksd_text) (keeper_settings_recovery state shortcut.ksv_key) = Some draft.ksd_text);
  let observed = sandbox_save_snapshot Keeper_sandbox_config.Remote_ssh in
  let prepared = {ksp_snapshot=observed;ksp_patch=None} in
  ignore (publish_keeper_settings_save shortcut ~observed_ns:25L Settings_reading);
  let unchanged = Settings_finished (Some prepared,Settings_unchanged) in
  ignore (publish_keeper_settings_save shortcut ~observed_ns:26L unchanged);
  ignore (apply_keeper_settings_save state shortcut unchanged);
  Alcotest.(check bool) "read-only outcome retains its exact observation without a patch" true
    (match (List.hd (Keeper_settings_saves.all state.keeper_settings_saves)).ksa_status with
     | Settings_finished (Some frozen,Settings_unchanged) -> frozen.ksp_snapshot == observed && frozen.ksp_patch=None
     | Settings_checking | Settings_reading | Settings_posting _ | Settings_finished _ -> false);
  Alcotest.(check bool) "completed shortcut still cannot erase editor recovery" true
    (Option.is_some (keeper_settings_recovery state shortcut.ksv_key))

let test_sandbox_receipt_keeps_frozen_source_after_withdrawal () =
  let open Masc_tui_types in
  let state,_ = keeper_settings_fixture () in
  state.detail_tab <- Detail_sandbox;
  let request = match begin_keeper_sandbox_save state ~profile:Keeper_sandbox_config.Micro_vm ~started_ns:20L with
    | Ok request -> request | Error detail -> Alcotest.fail detail in
  let observed = sandbox_save_snapshot Keeper_sandbox_config.Docker in
  let patch = match Masc_tui_keeper_config.sandbox_patch ~profile:Keeper_sandbox_config.Micro_vm observed with
    | Ok (Some patch) -> patch | Ok None -> Alcotest.fail "missing change" | Error detail -> Alcotest.fail detail in
  let prepared = {ksp_snapshot=observed;ksp_patch=Some patch} in
  ignore (publish_keeper_settings_save request ~observed_ns:21L Settings_reading);
  ignore (publish_keeper_settings_save request ~observed_ns:22L (Settings_posting prepared));
  state.workspace_read_authority <- ref ();
  let outcome = Settings_finished (Some prepared,Settings_unconfirmed "connection ended") in
  ignore (publish_keeper_settings_save request ~observed_ns:23L outcome);
  let retained = match List.nth_opt (pending_keeper_settings_save_receipts state) 0 with
    | Some (owner,status,_) -> apply_keeper_settings_save state owner status
    | None -> false in
  Alcotest.(check bool) "withdrawal cannot lose an admitted shortcut receipt" true retained;
  Alcotest.(check bool) "receipt cannot authorize a current surface refresh" false (keeper_settings_save_current state request);
  Alcotest.(check bool) "original profile, snapshot and CAS patch stay joined" true
    (request.ksv_input = Sandbox_shortcut_input Keeper_sandbox_config.Micro_vm
     && match (List.hd (Keeper_settings_saves.all state.keeper_settings_saves)).ksa_status with
        | Settings_finished (Some frozen,Settings_unconfirmed _) -> frozen == prepared
        | Settings_checking | Settings_reading | Settings_posting _ | Settings_finished _ -> false);
  Alcotest.(check bool) "terminal shortcut cannot dispatch again automatically" false
    (publish_keeper_settings_save request ~observed_ns:24L (Settings_posting prepared))

let runtime_assignment_request state keeper runtime_id started_ns =
  match Masc_tui_types.begin_runtime_assignment_save state ~keeper_name:keeper ~runtime_id ~started_ns with
  | Ok request -> request | Error detail -> Alcotest.fail detail

let test_assignment_receipt_keeps_original_choice_after_withdrawal () =
  let open Masc_tui_types in
  let state,keeper = keeper_settings_fixture () in
  state.view <- Keepers Keeper_runtime_pick;
  state.runtime_pick_keeper <- Some keeper.k_name;
  let request = runtime_assignment_request state keeper.k_name (Some "codex.example") 30L in
  let observed = (keeper_settings_snapshot ()).kss_observed in
  let revision = match Masc_tui_keeper_config.expected_runtime_assignment_revision observed with
    | Ok revision -> revision | Error detail -> Alcotest.fail detail in
  let prepared = {rap_snapshot=observed;rap_expected_revision=revision} in
  ignore (publish_runtime_assignment request ~observed_ns:31L Assignment_reading);
  ignore (publish_runtime_assignment request ~observed_ns:32L (Assignment_posting prepared));
  state.view <- Overview;
  state.runtime_pick_keeper <- None;
  Alcotest.(check bool) "navigation alone cannot retire the admitted operation" true
    (runtime_assignment_current state request);
  let Workspace_authority generation = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (generation+1);
  state.workspace_read_authority <- ref ();
  state.workspace_identity <- Workspace_identity_match_unconfirmed "server disconnected";
  let finished = Assignment_finished (Some prepared,Assignment_unconfirmed "interrupted after dispatch") in
  ignore (publish_runtime_assignment request ~observed_ns:33L finished);
  let retained = match List.nth_opt (pending_runtime_assignment_receipts state) 0 with
    | Some (owner,status,observed_ns) ->
        owner.ras_token==request.ras_token && observed_ns=33L && apply_runtime_assignment state owner status
    | None -> false in
  Alcotest.(check bool) "atomic receipt survives authority withdrawal without scoped mailbox admission" true retained;
  Alcotest.(check bool) "old operation cannot authorize a current surface refresh" false
    (runtime_assignment_current state request);
  Alcotest.(check bool) "original Keeper, explicit runtime, snapshot and CAS revision stay joined" true
    (request.ras_key.ksk_keeper=keeper.k_name && request.ras_runtime_id=Some "codex.example"
     && match (List.hd (Runtime_assignment_saves.all state.runtime_assignment_saves)).raa_status with
        | Assignment_finished (Some frozen,Assignment_unconfirmed _) ->
            frozen==prepared && frozen.rap_snapshot=observed && frozen.rap_expected_revision=revision
        | Assignment_checking | Assignment_reading | Assignment_posting _ | Assignment_finished _ -> false);
  Alcotest.(check bool) "an interrupted terminal operation cannot start posting again" false
    (publish_runtime_assignment request ~observed_ns:34L (Assignment_posting prepared))

let test_assignment_serializes_same_keeper_config_intents () =
  let open Masc_tui_types in
  let state,keeper = keeper_settings_fixture () in
  state.view <- Keepers Keeper_runtime_pick;
  state.runtime_pick_keeper <- Some keeper.k_name;
  let original = runtime_assignment_request state keeper.k_name (Some "codex.example") 30L in
  Alcotest.(check bool) "a repeated default choice cannot mutate the pending concrete choice" true
    (Result.is_error (begin_runtime_assignment_save state ~keeper_name:keeper.k_name ~runtime_id:None ~started_ns:31L)
     && original.ras_runtime_id=Some "codex.example" && state.runtime_pick_keeper=Some keeper.k_name);
  state.view <- Keepers Keeper_detail;
  let editor_refused = Option.is_none (begin_keeper_settings_editor state ~available:true ~started_ns:32L) in
  state.detail_tab <- Detail_sandbox;
  Alcotest.(check bool) "pending assignment excludes same-Keeper editor and Sandbox writes" true
    (editor_refused && Result.is_error (begin_keeper_sandbox_save state ~profile:Keeper_sandbox_config.Docker ~started_ns:32L));
  let second = {keeper with k_name="beta"} in
  state.keepers <- [keeper;second];
  state.view <- Keepers Keeper_runtime_pick;
  state.runtime_pick_keeper <- Some second.k_name;
  let independent = runtime_assignment_request state second.k_name None 33L in
  Alcotest.(check bool) "another Keeper independently owns clearing its explicit assignment" true
    (independent.ras_runtime_id=None && independent.ras_key.ksk_keeper=second.k_name
     && independent.ras_token != original.ras_token);
  let finished = Assignment_finished (None,Assignment_not_sent "withdrawn before dispatch") in
  ignore (publish_runtime_assignment original ~observed_ns:34L finished);
  ignore (apply_runtime_assignment state original finished);
  state.runtime_pick_keeper <- Some keeper.k_name;
  let successor = runtime_assignment_request state keeper.k_name None 35L in
  Alcotest.(check bool) "an explicit later choice owns a fresh operation; old receipt cannot finish it" true
    (successor.ras_token != original.ras_token && successor.ras_runtime_id=None
     && not (apply_runtime_assignment state original finished)
     && (List.hd (Runtime_assignment_saves.all state.runtime_assignment_saves)).raa_status=Assignment_checking);
  let editor_state,editor_keeper,_,_,_ = keeper_settings_save_fixture () in
  editor_state.view <- Keepers Keeper_runtime_pick;
  editor_state.runtime_pick_keeper <- Some editor_keeper.k_name;
  Alcotest.(check bool) "pending editor also excludes a runtime assignment without losing picker selection" true
    (Result.is_error (begin_runtime_assignment_save editor_state ~keeper_name:editor_keeper.k_name
      ~runtime_id:None ~started_ns:36L)
     && editor_state.runtime_pick_keeper=Some editor_keeper.k_name
     && Runtime_assignment_saves.all editor_state.runtime_assignment_saves=[])

let catalog_request state intent started_ns =
  match Masc_tui_types.begin_runtime_catalog_read state ~intent ~started_ns with
  | Some request -> request | None -> Alcotest.fail "catalogue read did not start"

let test_catalog_demands_share_and_refresh_after_current_read () =
  let open Masc_tui_types in
  let state,_ = keeper_settings_fixture () in
  let first = catalog_request state Snapshot_read.Poll 40L in
  Alcotest.(check bool) "another consumer shares the in-flight catalogue owner" true
    (Option.is_none (begin_runtime_catalog_read state ~intent:Snapshot_read.Poll ~started_ns:41L));
  List.iter (fun started_ns ->
    Alcotest.(check bool) "refresh demand queues without dispatching a parallel read" true
      (Option.is_none (begin_runtime_catalog_read state ~intent:Snapshot_read.Refresh ~started_ns))) [42L;43L;44L];
  Alcotest.(check bool) "current result cannot satisfy later refresh demand" true
    (take_runtime_catalog_read state first (Ok ([],[],[],Some "old"))
     && Local_read_order.has_followup state.runtime_catalog_order
     && state.runtime_catalog_reading=Runtime_catalog_refreshing None);
  let followup = catalog_request state Snapshot_read.Poll 45L in
  Alcotest.(check bool) "one successor covers accumulated demand and rejects late original result" true
    (not (Local_read_order.has_followup state.runtime_catalog_order)
     && not (take_runtime_catalog_read state first (Ok ([],[],[],Some "late")))
     && take_runtime_catalog_read state followup (Ok ([],[],[],Some "current"))
     && state.runtime_catalog_default_route=Some "current"
     && state.runtime_catalog_reading=Runtime_catalog_read
     && not (Local_read_order.in_flight state.runtime_catalog_order))

let test_catalog_refresh_retains_observation_and_empty_success () =
  let open Masc_tui_types in
  let state,_ = keeper_settings_fixture () in
  let opening = catalog_request state Snapshot_read.Poll 40L in
  ignore (take_runtime_catalog_read state opening (Ok ([],[],[],Some "original")));
  let refresh = catalog_request state Snapshot_read.Refresh 41L in
  Alcotest.(check bool) "refresh keeps the prior observation" true
    (runtime_catalog_has_observation state && state.runtime_catalog_default_route=Some "original");
  ignore (take_runtime_catalog_read state refresh (Error "server unavailable"));
  Alcotest.(check bool) "failure preserves original data and explicit stale status" true
    (state.runtime_catalog_default_route=Some "original"
     && state.runtime_catalog_reading=Runtime_catalog_stale "server unavailable");
  let retry = catalog_request state Snapshot_read.Refresh 42L in
  Alcotest.(check bool) "pending retry retains the preceding failure" true
    (state.runtime_catalog_reading=Runtime_catalog_refreshing (Some "server unavailable"));
  ignore (take_runtime_catalog_read state retry (Ok ([],[],[],None)));
  Alcotest.(check bool) "successful empty catalogue is a completed observation" true
    (state.runtime_catalog_reading=Runtime_catalog_read && runtime_catalog_has_observation state
     && state.runtime_catalog=[] && state.runtime_catalog_default_route=None
     && not (Local_read_order.in_flight state.runtime_catalog_order))

let test_catalog_withdrawal_folds_demand_into_reconfirmation () =
  let open Masc_tui_types in
  let state,_ = keeper_settings_fixture () in
  let original = catalog_request state Snapshot_read.Poll 40L in
  ignore (begin_runtime_catalog_read state ~intent:Snapshot_read.Refresh ~started_ns:41L);
  state.workspace_read_authority <- ref ();
  state.workspace_identity <- Workspace_identity_match_unconfirmed "disconnected";
  suspend_workspace_readings state;
  Alcotest.(check bool) "retirement preserves demand but denies old response and unconfirmed dispatch" true
    (state.runtime_catalog_resume
     && not (take_runtime_catalog_read state original (Ok ([],[],[],Some "old")))
     && Option.is_none (begin_runtime_catalog_read state ~intent:Snapshot_read.Refresh ~started_ns:42L));
  state.workspace_identity <- Workspace_identity_match;
  let resumed = catalog_request state Snapshot_read.Poll 43L in
  Alcotest.(check bool) "one fresh owner replaces both retired read and queued demand" true
    (not state.runtime_catalog_resume && not (Local_read_order.has_followup state.runtime_catalog_order)
     && not (take_runtime_catalog_read state original (Ok ([],[],[],Some "late")))
     && take_runtime_catalog_read state resumed (Ok ([],[],[],Some "current")));
  let pending = catalog_request state Snapshot_read.Poll 44L in
  clear_runtime_catalog_read state;
  Alcotest.(check bool) "a changed workspace cannot reuse the old catalogue or completion" true
    (not (take_runtime_catalog_read state pending (Ok ([],[],[],Some "foreign")))
     && state.runtime_catalog_reading=Runtime_catalog_unread && state.runtime_catalog_default_route=None);
  let nested = catalog_request state Snapshot_read.Poll 45L in
  ignore (take_runtime_catalog_read state nested (Ok ([],[],[],Some "observed")));
  state.context_inspector_open <- true;
  state.context_inspector_target <- Masc_tui_context_inspector.Recent 0;
  suspend_runtime_catalog_read state;
  Alcotest.(check bool) "a completed catalogue needed by a nested consumer also requests reconfirmation" true
    (state.runtime_catalog_resume && runtime_catalog_has_observation state
     && not (Local_read_order.in_flight state.runtime_catalog_order))

let runtime_form_source = {|[providers.codex]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/masc-form-account"
[models.example]
api-name = "example"
max-context = 500000
[codex.example]
max-context = 272000
|}

let runtime_form_models source =
  Runtime_toml.parse_string source
  |> Result.map_error (fun errors -> String.concat "; "
       (List.map (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message) errors))
  |> fun parsed -> Result.bind parsed Runtime_config_models.of_config

let runtime_form_reading () : Masc_tui_runtime_config_view.reading =
  {path="/workspace/runtime.toml"; source_text=runtime_form_source;
   metadata={source_revision="opening";
     validation=Checked {valid=true; schema_version=1; current_schema_version=1;
       forward_schema=false; issues=[]}; routing=Routing_active; routing_requires_restart=false;
     keeper=Not_configured; keeper_requires_restart=false; configured_count=0;
     pending_keys=[]; applied_keys=[]; preempted_keys=[]};
   model_bindings=runtime_form_models runtime_form_source;
   account_groups=Ok []; account_emails=Ok (Masc_tui_account_login.Email_rows {rows=[];unattributed=0})}

let runtime_model_draft () =
  let row = match Masc_tui_model_runtime_table.parse (String.split_on_char '\n' runtime_form_source) with
    | Ok (row :: _) -> row | Ok [] -> Alcotest.fail "model missing" | Error detail -> Alcotest.fail detail in
  let form = Masc_tui_model_form.create ~source_revision:"opening" Edit row in
  let form = match Masc_tui_model_form.key form "ctrl-u" with
    | Editing form -> Masc_tui_model_form.paste form "300000"
    | Cancelled | Submit _ -> Alcotest.fail "context edit failed" in
  Masc_tui_types.Model_form_draft form

let runtime_form_request state draft =
  match Masc_tui_types.begin_runtime_form_save state ~draft ~started_ns:10L with
  | Ok request -> request | Error detail -> Alcotest.fail detail

let test_runtime_form_prepares_original_revision () =
  let open Masc_tui_types in
  let draft = runtime_model_draft () and reading = runtime_form_reading () in
  let prepared = match prepare_runtime_form_save draft reading with
    | Ok prepared -> prepared | Error _ -> Alcotest.fail "original edit rejected" in
  Alcotest.(check string) "base text is retained" runtime_form_source prepared.rfp_base.source_text;
  Alcotest.(check string) "guard uses opening revision" "opening" prepared.rfp_base.source_revision;
  (match Masc_tui_model_runtime_table.parse (String.split_on_char '\n' prepared.rfp_text) with
   | Ok [row] -> Alcotest.(check (option (pair string int))) "binding changes on same source"
       (Some ("binding",300000)) row.context
   | Ok [] | Ok (_::_) | Error _ -> Alcotest.fail "prepared binding missing");
  let changed = {reading with source_text="not the original source";
    metadata={reading.metadata with source_revision="another writer"}} in
  Alcotest.(check bool) "changed source refuses before applying original fields" true
    (match prepare_runtime_form_save draft changed with Error (Form_not_sent _) -> true
     | Ok _ | Error (Form_saved _ | Form_invalid_account _ | Form_refused _ | Form_conflict _ | Form_unconfirmed _) -> false)

let test_runtime_form_retains_unknown_and_rejects_duplicate () =
  let open Masc_tui_types in
  let state,_ = keeper_settings_fixture () in
  let draft = runtime_model_draft () in
  let form = match draft with Model_form_draft form -> form | Account_form_draft _ | Config_document_draft _ -> Alcotest.fail "model required" in
  state.runtime_model_form <- Some form;
  let request = runtime_form_request state draft in
  Alcotest.(check bool) "pending operation freezes input" true (runtime_form_input_locked state);
  Alcotest.(check bool) "duplicate has no second operation" true
    (Result.is_error (begin_runtime_form_save state ~draft ~started_ns:11L));
  let prepared = match prepare_runtime_form_save draft (runtime_form_reading ()) with
    | Ok prepared -> prepared | Error _ -> Alcotest.fail "prepare failed" in
  ignore (publish_runtime_form_save request ~observed_ns:12L (Form_previewing prepared));
  ignore (publish_runtime_form_save request ~observed_ns:13L (Form_posting prepared));
  let latest = match List.nth_opt (pending_runtime_form_save_receipts state) 0 with
    | Some (_,status,_) -> status | None -> Alcotest.fail "posting observation lost" in
  Alcotest.(check bool) "coalesced posting can skip preview admission" true (apply_runtime_form_save state request latest);
  state.runtime_model_form <- None; state.runtime_form_save_focus <- None;
  let unknown = Form_finished (Some prepared,Form_unconfirmed "connection ended after dispatch") in
  ignore (publish_runtime_form_save request ~observed_ns:14L unknown);
  suspend_workspace_readings state;
  Alcotest.(check bool) "operation receipt survives read withdrawal" true
    (apply_runtime_form_save state request unknown);
  Alcotest.(check bool) "no automatic or duplicate retry after unknown" true
    (Result.is_error (begin_runtime_form_save state ~draft ~started_ns:15L));
  Alcotest.(check bool) "original draft is manually recoverable" true (recover_runtime_form_save state ~account:false);
  Alcotest.(check bool) "unknown input cannot be resubmitted" true (runtime_form_input_locked state);
  Alcotest.(check bool) "late progress cannot erase terminal uncertainty" false
    (publish_runtime_form_save request ~observed_ns:16L (Form_posting prepared));
  release_runtime_form_recovery state;
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "explicitly starting fresh admits another operation" true
    (Result.is_ok (begin_runtime_form_save state ~draft ~started_ns:17L));
  Alcotest.(check bool) "old terminal receipt cannot consume successor" false
    (apply_runtime_form_save state request unknown);
  Alcotest.(check int) "both operation records remain" 2 (List.length (Runtime_form_saves.all state.runtime_form_saves))

let test_runtime_account_save_keeps_typed_form_and_workspace () =
  let open Masc_tui_types in
  let state,_ = keeper_settings_fixture () in
  let form = match Masc_tui_runtime_account_form.open_on ~source_revision:"opening"
      ~home_dir:"/tmp/operator" runtime_form_source with
    | Ok form -> form | Error detail -> Alcotest.fail detail in
  state.runtime_account_form <- Some form;
  let request = runtime_form_request state (Account_form_draft form) in
  Alcotest.(check bool) "another form cannot commit over pending source" true
    (Result.is_error (begin_runtime_form_save state ~draft:(runtime_model_draft ()) ~started_ns:11L));
  let refused = Masc_tui_runtime_account_form.refused form "field rejection" in
  let terminal = Form_finished (None,Form_invalid_account refused) in
  ignore (publish_runtime_form_save request ~observed_ns:12L terminal);
  let Workspace_authority epoch = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (epoch+1);
  Alcotest.(check bool) "retired authority cannot complete an on-screen successor" false
    (runtime_form_save_current state request);
  Alcotest.(check bool) "original refusal remains an operation receipt" true
    (apply_runtime_form_save state request terminal);
  state.server_identity <- Some (identity "/another-workspace");
  Alcotest.(check bool) "another workspace cannot restore this account input" false
    (recover_runtime_form_save state ~account:true);
  state.server_identity <- Some request.rfs_workspace;
  Alcotest.(check bool) "returning explicitly restores original account form" true
    (recover_runtime_form_save state ~account:true);
  Alcotest.(check bool) "typed field rejection is preserved" true
    (Option.exists (fun restored -> restored == refused) state.runtime_account_form);
  Alcotest.(check (option string)) "original source revision remains" (Some "opening")
    (Option.bind state.runtime_account_form Masc_tui_runtime_account_form.source_revision)


let runtime_document_fixture () =
  let state,_ = keeper_settings_fixture () in
  let workspace = match Masc_tui_types.runtime_config_workspace state with
    | Some workspace -> workspace | None -> Alcotest.fail "workspace missing" in
  let base : Masc_tui_runtime_config_edit.document = {
    path=Filename.concat (snd workspace) "config/runtime.toml";
    source_text="value = 1\n"; source_revision="opening"} in
  let session = Masc_tui_runtime_config_edit.open_document base
    |> Masc_tui_runtime_config_edit.edit "value = 2\n# exact original input\n" in
  Masc_tui_types.put_runtime_config_edit state ~workspace session;
  state,workspace,session

let runtime_document_receipt durability : Masc_tui_runtime_config_receipt.t =
  {source_revision="saved"; order="operation-1"; durability; lock_warnings=[];
   application={operation="runtime-config"; routing_status=Routing_active;
     routing_requires_restart=false; routing_applied_at=Not_applied;
     keeper_status=Keeper_not_configured; keeper_requires_restart=false;
     keeper_applied_at=Not_applied; keeper_configured_count=0; keeper_pending_keys=[];
     keeper_applied_keys=[]; keeper_preempted_keys=[];
     skills=Skill_unchanged {input_source_revision="saved"; snapshot_revision="skills";
       catalog_revision="catalog"; config_state=Configured};
     exact_output_registry=Exact_output_registry_unpublished}}

let finish_runtime_document state request prepared outcome =
  let open Masc_tui_types in
  let status = Form_finished (Some prepared,outcome) in
  ignore (publish_runtime_form_save request ~observed_ns:20L status);
  if not (apply_runtime_form_save state request status) then Alcotest.fail "receipt not retained";
  apply_runtime_document_save state request status

let test_runtime_document_save_owns_exact_input_across_refresh () =
  let open Masc_tui_types in
  let module Edit = Masc_tui_runtime_config_edit in
  let state,workspace,session = runtime_document_fixture () in
  let request = runtime_form_request state (Config_document_draft session) in
  let prepared = prepare_runtime_document session in
  Alcotest.(check string) "submitted text is frozen" session.text prepared.rfp_text;
  Alcotest.(check string) "guard keeps original revision" "opening" prepared.rfp_base.source_revision;
  Alcotest.(check bool) "second raw write is not dispatched" true
    (Result.is_error (begin_runtime_form_save state ~draft:(Config_document_draft session) ~started_ns:11L));
  Alcotest.(check bool) "structured form shares the same pending write gate" true
    (Result.is_error (begin_runtime_form_save state ~draft:(runtime_model_draft ()) ~started_ns:12L));
  let current = {session.base with source_text="value = 2\n"; source_revision="saved"} in
  let refreshed = match Edit.observe ~read_generation:1 current session with
    | Ok session -> session | Error detail -> Alcotest.fail detail in
  put_runtime_config_edit ~preserve_view:true state ~workspace refreshed;
  Alcotest.(check bool) "observation preserves editing ownership" true (Edit.same_draft session refreshed);
  Alcotest.(check bool) "confirmed receipt clears its own refreshed draft" true
    (finish_runtime_document state request prepared (Form_saved (runtime_document_receipt Durable)));
  Alcotest.(check int) "only submitted draft is completed" 0 (List.length state.runtime_config_edits)

let test_runtime_document_late_success_keeps_same_text_successor () =
  let open Masc_tui_types in
  let module Edit = Masc_tui_runtime_config_edit in
  let state,workspace,session = runtime_document_fixture () in
  let request = runtime_form_request state (Config_document_draft session) in
  let successor = Edit.edit session.text session in
  Alcotest.(check bool) "same text can be another editing intent" false (Edit.same_draft session successor);
  put_runtime_config_edit state ~workspace successor;
  let foreign = "/other","/other/.masc" in
  put_runtime_config_edit state ~workspace:foreign session;
  let Workspace_authority epoch = state.workspace_authority in
  state.workspace_authority <- Workspace_authority (epoch+1);
  Alcotest.(check bool) "old authority cannot own current effects" false (runtime_form_save_current state request);
  Alcotest.(check bool) "receipt cannot delete successor or another workspace" false
    (finish_runtime_document state request (prepare_runtime_document session)
       (Form_saved (runtime_document_receipt Durable)));
  Alcotest.(check int) "both drafts retained" 2 (List.length state.runtime_config_edits);
  Alcotest.(check bool) "exact successor identity retained" true
    (List.exists (fun edit -> edit.rce_workspace=workspace && Edit.same_draft successor edit.rce_session)
      state.runtime_config_edits)

let test_runtime_document_uncertainty_requires_new_read outcome =
  let open Masc_tui_types in
  let module Edit = Masc_tui_runtime_config_edit in
  let state,workspace,session = runtime_document_fixture () in
  let before = match Edit.observe ~read_generation:8 session.base session with
    | Ok session -> session | Error detail -> Alcotest.fail detail in
  let request = runtime_form_request state (Config_document_draft before) in
  let successor = Edit.edit "value = 3\n# later draft\n" before in
  put_runtime_config_edit state ~workspace successor;
  state.runtime_config_generation <- 9;
  Alcotest.(check bool) "uncertainty retires comparison without replacing later input" true
    (finish_runtime_document state request (prepare_runtime_document before) outcome);
  let retained = (List.find (fun edit -> edit.rce_workspace=workspace) state.runtime_config_edits).rce_session in
  Alcotest.(check string) "later input remains exact" successor.text retained.text;
  Alcotest.(check bool) "later editing intent remains" true (Edit.same_draft successor retained);
  Alcotest.(check bool) "old comparison cannot adopt" true (Result.is_error (Edit.adopt_current retained));
  Alcotest.(check bool) "editing cannot bypass uncertain original basis" true
    (Result.is_error (begin_runtime_form_save state ~draft:(Config_document_draft retained) ~started_ns:21L));
  let premature = match Edit.adopt_current before with
    | Ok session -> session | Error detail -> Alcotest.fail detail in
  put_runtime_config_edit state ~workspace premature;
  Alcotest.(check bool) "another basis chosen from a pre-outcome read cannot retry" true
    (Result.is_error (begin_runtime_form_save state ~draft:(Config_document_draft premature) ~started_ns:21L));
  put_runtime_config_edit state ~workspace retained;
  Alcotest.(check bool) "in-flight read cannot reconfirm after uncertainty" true
    (Result.is_error (Edit.observe ~read_generation:9 session.base retained));
  Alcotest.(check bool) "unstamped observation is not fresh revalidation" true
    (Result.is_error (Edit.observe session.base retained));
  let fresh = match Edit.observe ~read_generation:10 session.base retained with
    | Ok session -> session | Error detail -> Alcotest.fail detail in
  Alcotest.(check bool) "observation alone does not adopt basis" true (Edit.same_basis retained fresh);
  let adopted = match Edit.adopt_current fresh with
    | Ok session -> session | Error detail -> Alcotest.fail detail in
  Alcotest.(check string) "explicit adoption keeps later input" successor.text adopted.text;
  Alcotest.(check bool) "explicit choice starts another basis even at equal revision" false
    (Edit.same_basis before adopted);
  put_runtime_config_edit state ~workspace adopted;
  Alcotest.(check bool) "only explicit fresh intent can save again" true
    (Result.is_ok (begin_runtime_form_save state ~draft:(Config_document_draft adopted) ~started_ns:22L))


let test_runtime_snapshot_preserves_source_when_models_unavailable () =
  let module Snapshot = Masc_tui_runtime_config_snapshot in
  let reading = { (runtime_form_reading ()) with account_groups=Error "group observation unavailable" } in
  let snapshot = Snapshot.of_reading reading in
  Alcotest.(check bool) "source and metadata retain their original reading" true (snapshot.reading == reading);
  Alcotest.(check bool) "group failure is not an empty model catalogue" true
    (match snapshot.models with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool) "failed model interpretation does not hide the original source" true
    (Option.is_some (Snapshot.rows_for_source ~path:reading.path ~source_text:reading.source_text snapshot));
  let malformed = { reading with source_text="[not closed"; account_groups=Ok [];
    model_bindings=Error "server Runtime interpretation unavailable" } in
  let snapshot = Snapshot.of_reading malformed in
  Alcotest.(check string) "operator can retain malformed source to repair it" malformed.source_text snapshot.reading.source_text;
  Alcotest.(check bool) "malformed model parse stays unavailable" true
    (match snapshot.models with Error _ -> true | Ok _ -> false)

let test_runtime_snapshot_models_use_same_source_and_server_groups () =
  let module Snapshot = Masc_tui_runtime_config_snapshot in
  let source = runtime_form_source ^ {|
[providers.second]
protocol = "codex-app-server"
command = "codex"
is-non-interactive = true
account-home = "/tmp/another-account"
[second.example]
|} in
  let reading = { (runtime_form_reading ()) with source_text=source;
    model_bindings=runtime_form_models source;
    account_groups=Ok [["codex";"second"]]; account_emails=Error "emails unavailable" } in
  let snapshot = Snapshot.of_reading reading in
  let rows = match snapshot.models with Ok rows -> rows | Error detail -> Alcotest.fail detail in
  let row = match List.find_opt (fun (row : Masc_tui_model_runtime_table.row) -> row.provider="codex") rows with
    | Some row -> row | None -> Alcotest.fail "binding missing from source snapshot" in
  Alcotest.(check int) "both exact source bindings retained" 2 (List.length rows);
  Alcotest.(check (list string)) "membership comes from this server reading" ["second"] row.same_login;
  Alcotest.(check (option int)) "context belongs to original binding" (Some 272000) (Option.map snd row.context);
  Alcotest.(check bool) "unavailable email observation is retained independently" true
    (match snapshot.reading.account_emails with Error _ -> true | Ok _ -> false);
  Alcotest.(check bool) "another path cannot reuse this projection" true
    (Option.is_none (Snapshot.rows_for_source ~path:(reading.path ^ ".other") ~source_text:source snapshot));
  Alcotest.(check bool) "another source cannot reuse this projection" true
    (Option.is_none (Snapshot.rows_for_source ~path:reading.path ~source_text:runtime_form_source snapshot))

let test_runtime_snapshot_refresh_reuses_draft_without_changing_ownership () =
  let open Masc_tui_types in
  let module Edit = Masc_tui_runtime_config_edit in
  let module Snapshot = Masc_tui_runtime_config_snapshot in
  let state,workspace,session = runtime_document_fixture () in
  let initial = List.hd state.runtime_config_edits in
  state.runtime_config_edits <- [{initial with rce_view=Config_edit_current []}];
  let reading = { (runtime_form_reading ()) with path=session.base.path; source_text="value = 4\n";
    model_bindings=runtime_form_models "value = 4\n";
    metadata={ (runtime_form_reading ()).metadata with source_revision="fresh"} } in
  let snapshot = Snapshot.of_reading reading in
  let current : Edit.document = {path=reading.path; source_text=reading.source_text;
    source_revision=reading.metadata.source_revision} in
  let observed = match Edit.observe ~read_generation:3 current session with
    | Ok session -> session | Error detail -> Alcotest.fail detail in
  put_runtime_config_edit ~preserve_view:true ~snapshot state ~workspace observed;
  let held = List.hd state.runtime_config_edits in
  Alcotest.(check bool) "observation reuses existing immutable draft projection" true
    (held.rce_rows == initial.rce_rows);
  (match held.rce_view with
   | Config_edit_current rows -> Alcotest.(check bool) "comparison reuses the matching source projection" true
       (rows == snapshot.rows)
   | Config_edit_draft -> Alcotest.fail "comparison intent was lost");
  Alcotest.(check bool) "projection cannot change editing ownership" true (Edit.same_draft session held.rce_session);
  Alcotest.(check bool) "projection cannot choose a new basis" true (Edit.same_basis session held.rce_session);
  Alcotest.(check string) "observation does not replace original input" session.text held.rce_session.text;
  Alcotest.(check (option int)) "current comparison retains original read generation" (Some 3)
    held.rce_session.current_read_generation;
  let successor = Edit.edit session.text held.rce_session in
  put_runtime_config_edit ~snapshot state ~workspace successor;
  let held = List.hd state.runtime_config_edits in
  Alcotest.(check bool) "same-text successor may share tokens without sharing draft authority" true
    (held.rce_rows == initial.rce_rows && not (Edit.same_draft session held.rce_session))


(* This exercises request/state delivery, not rendered rows or elapsed time.
   The callback models the loop's existing deadline without adding a timer. *)
let test_owned_results_progress_between_shared_queue_prefixes () =
  Eio_main.run @@ fun _ ->
  let open Masc_tui_types in
  let module P = Masc_tui_async_protocol in
  let module Round = P.Delivery_round in
  let module Event = struct
    type t = Withdraw_reading | Shared_traffic | Owned of P.async_msg P.mailed
  end in
  let state,keeper,_,_,settings = keeper_settings_save_fixture () in
  let second_keeper = {keeper with k_name="assignment-owner"} in
  state.keepers <- [keeper;second_keeper];
  state.view <- Keepers Keeper_runtime_pick;
  state.runtime_pick_keeper <- Some second_keeper.k_name;
  let assignment = runtime_assignment_request state second_keeper.k_name (Some "codex.example") 30L in
  let form = runtime_form_request state (runtime_model_draft ()) in
  let created = creation_request state "created" "original created declaration" in
  let unknown = creation_request state "unknown" "original unconfirmed declaration" in
  let late = creation_request state "later" "later declaration" in
  let make_submission name : ask_submission =
    {as_request=ref ();as_started_ns=10L;as_receipt=Ask_answer_receipt.create ();
     as_completion=Ask_answer_completion.create ();as_reading=Some state.workspace_read_authority;
     as_authority=state.workspace_authority;as_keeper_name=keeper.k_name;as_ask_id=name;
     as_answered_label="original choice";as_source_turn_ref=None} in
  let superseded = make_submission "superseded" and current = make_submission "current" in
  let receipt = Ok (Masc.Tui_decode_asks.Ask_answer_recorded Masc.Tui_decode_asks.Ask_wake_stored) in
  let asks = Ok {Masc.Tui_decode_asks.asn_keeper=None;asn_open_count=0;asn_rows=[]} in
  List.iter (fun submission ->
    begin_ask_submission_state ~submission state;
    ignore (Ask_answer_receipt.publish submission.as_receipt ~observed_ns:40L receipt);
    ignore (Ask_answer_completion.publish submission.as_completion ~observed_ns:41L ~receipt ~asks))
    [superseded;current];
  let form_status = Form_finished (None,Form_unconfirmed "transport ended after dispatch") in
  let settings_status = Settings_finished (None,Settings_not_sent "proof unavailable before dispatch") in
  let assignment_status = Assignment_finished (None,Assignment_refused "server refused") in
  let unknown_status = Creation_finished (Creation_unconfirmed "response unavailable") in
  ignore (publish_runtime_form_save form ~observed_ns:42L form_status);
  ignore (publish_keeper_settings_save settings ~observed_ns:43L settings_status);
  ignore (publish_runtime_assignment assignment ~observed_ns:44L assignment_status);
  ignore (publish_keeper_creation_status created ~observed_ns:45L (Creation_finished Creation_created));
  ignore (publish_keeper_creation_status unknown ~observed_ns:46L unknown_status);
  let mailbox = Eio.Stream.create 2 in
  Eio.Stream.add mailbox Event.Withdraw_reading;
  Eio.Stream.add mailbox Event.Shared_traffic;
  let round = ref Round.empty and can_take = ref true in
  let first_collection = ref true in
  let terminal_seen = ref false in
  let collect_owned () =
    let captured = P.collect_owned_results state in
    if !first_collection then begin
      first_collection := false;
      can_take := false;
      (* A publication after collection must not extend the retained set. *)
      ignore (publish_keeper_creation_status late ~observed_ns:47L (Creation_finished Creation_created))
    end;
    List.map (fun ready -> Event.Owned ready) captured in
  let take () =
    let ready,next = Round.take !round ~can_take:(fun () -> !can_take)
      ~queued:(fun () -> Eio.Stream.length mailbox)
      ~take_shared:(fun () -> Eio.Stream.take_nonblocking mailbox) ~collect_owned in
    round := next;
    ready in
  let apply_owned (ready : P.async_msg P.mailed) = match ready.message with
    | P.Ask_answer_receipt_ready owner ->
        let held,fact = match take_ask_answer_receipt state owner with
          | Some observed -> observed | None -> Alcotest.fail "owned POST result was delivered twice" in
        Alcotest.(check bool) "read withdrawal retains the canonical POST without new feedback authority" true
          (held.as_request==owner.as_request && fact.result=receipt
           && Option.is_none (retain_ask_answer_feedback state held fact.result))
    | P.Workspace_scoped (authority,reading,(P.Ask_answer_done (owner,_,_) as inner)) ->
        Alcotest.(check bool) "captured identity withdrawal precedes terminal read admission" true
          (P.workspace_message_admitted state ~authority ~reading inner
           && match P.project_workspace_operation_reply state ~authority ~reading inner with
             | P.Ask_answer_done (_,saved,observed) -> saved=receipt && Result.is_error observed
             | _ -> false);
        if owner.as_request==current.as_request then terminal_seen := true
    | P.Runtime_form_save_changed (owner,status,_) ->
        let Workspace_authority generation = state.workspace_authority in
        state.workspace_authority <- Workspace_authority (generation+1);
        Alcotest.(check bool) "captured foreign form receipt grants no surface authority" true
          (!terminal_seen && owner.rfs_token==form.rfs_token && status=form_status
           && not (runtime_form_save_current state owner)
           && apply_runtime_form_save state owner status)
    | P.Keeper_settings_save_changed (owner,status,_) ->
        Alcotest.(check bool) "original refused settings result settles only its owner" true
          (owner.ksv_token==settings.ksv_token && status=settings_status
           && not (keeper_settings_save_current state owner)
           && apply_keeper_settings_save state owner status)
    | P.Runtime_assignment_changed (owner,status,_) ->
        Alcotest.(check bool) "original assignment refusal retains its explicit choice after withdrawal" true
          (owner.ras_token==assignment.ras_token && status=assignment_status
           && owner.ras_runtime_id=Some "codex.example"
           && not (runtime_assignment_current state owner)
           && apply_runtime_assignment state owner status)
    | P.Keeper_creation_changed (owner,status) ->
        Alcotest.(check bool) "each creation consumes only its own terminal result once" true
          (apply_keeper_creation_status state owner status)
    | _ -> Alcotest.fail "unexpected owned result" in
  let apply = function
    | Event.Withdraw_reading ->
        state.workspace_identity <- next_workspace_identity ~previous:state.workspace_identity
          ~local_base_path:state.local_base_path (Error "identity unavailable");
        suspend_workspace_readings state;
        Eio.Stream.add mailbox Event.Shared_traffic
    | Event.Shared_traffic -> Eio.Stream.add mailbox Event.Shared_traffic
    | Event.Owned ready -> apply_owned ready in
  let take_required () = match take () with Some ready -> apply ready
    | None -> Alcotest.fail "captured shared prefix was lost" in
  take_required ();
  can_take := false;
  Alcotest.(check bool) "a spent input pass neither consumes the prefix nor collects owned offers" true
    (Option.is_none (take ()) && !first_collection && Eio.Stream.length mailbox=2
     && List.exists (fun owner -> owner.as_request==current.as_request) state.ask_answer_completion_pending);
  can_take := true;
  take_required ();
  Alcotest.(check bool) "collection crossing the deadline retains its batch before any application" true
    (Option.is_none (take ()) && not !first_collection && not !terminal_seen
     && state.ask_answer_completion_pending=[] && Eio.Stream.length mailbox=2);
  can_take := true;
  let rec finish_round () = match take () with
    | None -> () | Some ready -> apply ready; finish_round () in
  finish_round ();
  let status_of owner = List.find_map (fun attempt ->
    if attempt.kca_request.kcr_token==owner.kcr_token then Some attempt.kca_status else None)
      state.keeper_creations in
  Alcotest.(check bool) "all originally ready owners settle while later traffic and publications remain" true
    (!terminal_seen && Eio.Stream.length mailbox=2
     && status_of created=Some (Creation_finished Creation_created)
     && status_of unknown=Some unknown_status && status_of late=Some Creation_checking
     && List.for_all (fun owner ->
       match Ask_answer_completion.read owner.as_completion with
       | Ask_answer_completion.Returned fact -> fact.receipt=receipt && fact.asks=asks
       | Ask_answer_completion.Waiting | Ask_answer_completion.Closed_without_result -> false)
       [superseded;current]);
  finish_round ();
  Alcotest.(check bool) "the next captured prefix also yields to the later original owner" true
    (Eio.Stream.length mailbox=2 && status_of late=Some (Creation_finished Creation_created)
     && P.collect_owned_results state=[])

let test_operation_histories_keep_unfinished_and_recovery_owners () =
  let open Masc_tui_types in
  let module P = Masc_tui_async_protocol in
  let state,keeper,_,_,settings = keeper_settings_save_fixture () in
  let assignment_keeper = {keeper with k_name="assignment-history"} in
  state.keepers <- [keeper;assignment_keeper];
  state.view <- Keepers Keeper_runtime_pick;
  state.runtime_pick_keeper <- Some assignment_keeper.k_name;
  let assignment = runtime_assignment_request state assignment_keeper.k_name (Some "codex.example") 30L in
  let draft = runtime_model_draft () in
  let form = runtime_form_request state draft in
  let prepared = match prepare_runtime_form_save draft (runtime_form_reading ()) with
    | Ok prepared -> prepared | Error _ -> Alcotest.fail "original form preparation failed" in
  let apply (ready : P.async_msg P.mailed) = match ready.message with
    | P.Runtime_form_save_changed (owner,status,_) ->
        Alcotest.(check bool) "form observation advances only its registered owner" true
          (apply_runtime_form_save state owner status)
    | P.Keeper_settings_save_changed (owner,status,_) ->
        Alcotest.(check bool) "settings observation advances only its registered owner" true
          (apply_keeper_settings_save state owner status)
    | P.Runtime_assignment_changed (owner,status,_) ->
        Alcotest.(check bool) "assignment observation advances only its registered owner" true
          (apply_runtime_assignment state owner status)
    | _ -> Alcotest.fail "unexpected configuration delivery" in
  let indexed form settings assignment =
    List.exists (fun attempt -> attempt.rfa_request.rfs_token==form.rfs_token)
      (Runtime_form_saves.pending state.runtime_form_saves)
    && List.exists (fun attempt -> attempt.ksa_request.ksv_token==settings.ksv_token)
      (Keeper_settings_saves.pending state.keeper_settings_saves)
    && List.exists (fun attempt -> attempt.raa_request.ras_token==assignment.ras_token)
      (Runtime_assignment_saves.pending state.runtime_assignment_saves) in
  let no_pending () =
    Runtime_form_saves.pending state.runtime_form_saves=[]
    && Keeper_settings_saves.pending state.keeper_settings_saves=[]
    && Runtime_assignment_saves.pending state.runtime_assignment_saves=[] in
  ignore (publish_runtime_form_save form ~observed_ns:40L (Form_previewing prepared));
  ignore (publish_keeper_settings_save settings ~observed_ns:41L Settings_reading);
  ignore (publish_runtime_assignment assignment ~observed_ns:42L Assignment_reading);
  let progress = P.collect_owned_results state in
  let form_unknown = Form_finished (Some prepared,Form_unconfirmed "response unavailable") in
  let settings_unknown = Settings_finished (None,Settings_unconfirmed "worker interrupted after dispatch") in
  let assignment_unknown = Assignment_finished (None,Assignment_unconfirmed "response unavailable") in
  ignore (publish_runtime_form_save form ~observed_ns:43L form_unknown);
  ignore (publish_keeper_settings_save settings ~observed_ns:44L settings_unknown);
  ignore (publish_runtime_assignment assignment ~observed_ns:45L assignment_unknown);
  Alcotest.(check bool) "publication cannot retire owners before terminal UI application" true
    (indexed form settings assignment);
  List.iter apply progress;
  Alcotest.(check bool) "captured progress cannot hide later terminal facts" true
    (indexed form settings assignment);
  let terminal = P.collect_owned_results state in
  state.workspace_identity <- Workspace_identity_match_unconfirmed "disconnected";
  suspend_workspace_readings state;
  List.iter apply terminal;
  Alcotest.(check bool) "withdrawn requests leave periodic delivery only after terminal application" true
    (no_pending () && not (runtime_form_save_current state form)
     && not (keeper_settings_save_current state settings)
     && not (runtime_assignment_current state assignment));
  state.workspace_identity <- Workspace_identity_match;
  Alcotest.(check bool) "retained unknown form still blocks an implicit retry" true
    (Result.is_error (begin_runtime_form_save state ~draft ~started_ns:46L));
  Alcotest.(check bool) "history retains original uncertain settings input for explicit recovery" true
    (match keeper_settings_recovery state settings.ksv_key with
     | Some held -> held.ksd_text=settings_editor_text settings | None -> false);
  (* Explicit new choices retain the old facts and admit distinct owners. *)
  release_runtime_form_recovery state;
  let next_form = runtime_form_request state draft in
  state.view <- Keepers Keeper_detail;
  state.detail_tab <- Detail_sandbox;
  let next_settings = match begin_keeper_sandbox_save state ~profile:Keeper_sandbox_config.Docker ~started_ns:47L with
    | Ok owner -> owner | Error detail -> Alcotest.fail detail in
  state.view <- Keepers Keeper_runtime_pick;
  state.runtime_pick_keeper <- Some assignment_keeper.k_name;
  let next_assignment = runtime_assignment_request state assignment_keeper.k_name None 48L in
  Alcotest.(check bool) "an empty ready collection keeps all unfinished successors indexed" true
    (P.collect_owned_results state=[] && indexed next_form next_settings next_assignment);
  release_runtime_form_recovery state;
  Alcotest.(check bool) "releasing input recovery does not retire a running request" true
    (indexed next_form next_settings next_assignment
     && Option.is_none state.runtime_form_save_focus && not (runtime_form_input_locked state));
  Alcotest.(check bool) "duplicate old outcomes cannot consume pending successors" true
    (not (apply_runtime_form_save state form form_unknown)
     && not (apply_keeper_settings_save state settings settings_unknown)
     && not (apply_runtime_assignment state assignment assignment_unknown)
     && indexed next_form next_settings next_assignment);
  Alcotest.(check bool) "late old progress cannot replace a preserved terminal fact" true
    (not (publish_runtime_form_save form ~observed_ns:49L (Form_posting prepared))
     && not (publish_keeper_settings_save settings ~observed_ns:49L Settings_reading)
     && not (publish_runtime_assignment assignment ~observed_ns:49L Assignment_reading));
  let form_unsent = Form_finished (None,Form_not_sent "worker withdrawn before entry") in
  let settings_unsent = Settings_finished (None,Settings_not_sent "worker withdrawn before entry") in
  let assignment_unsent = Assignment_finished (None,Assignment_not_sent "worker withdrawn before entry") in
  ignore (publish_runtime_form_save next_form ~observed_ns:50L form_unsent);
  ignore (publish_keeper_settings_save next_settings ~observed_ns:51L settings_unsent);
  ignore (publish_runtime_assignment next_assignment ~observed_ns:52L assignment_unsent);
  state.workspace_identity <- Workspace_identity_match_unconfirmed "disconnected again";
  suspend_workspace_readings state;
  List.iter apply (P.collect_owned_results state);
  Alcotest.(check bool) "pre-entry withdrawal facts settle their original successors without erasing history" true
    (no_pending () && P.collect_owned_results state=[]
     && List.exists (fun attempt -> attempt.rfa_request.rfs_token==form.rfs_token
          && attempt.rfa_status=form_unknown) (Runtime_form_saves.all state.runtime_form_saves)
     && List.exists (fun attempt -> attempt.rfa_request.rfs_token==next_form.rfs_token
          && attempt.rfa_status=form_unsent) (Runtime_form_saves.all state.runtime_form_saves)
     && List.exists (fun attempt -> attempt.ksa_request.ksv_token==settings.ksv_token
          && attempt.ksa_status=settings_unknown) (Keeper_settings_saves.all state.keeper_settings_saves)
     && List.exists (fun attempt -> attempt.ksa_request.ksv_token==next_settings.ksv_token
          && attempt.ksa_status=settings_unsent) (Keeper_settings_saves.all state.keeper_settings_saves)
     && List.exists (fun attempt -> attempt.raa_request.ras_token==assignment.ras_token
          && attempt.raa_status=assignment_unknown && attempt.raa_request.ras_runtime_id=Some "codex.example")
          (Runtime_assignment_saves.all state.runtime_assignment_saves)
     && List.exists (fun attempt -> attempt.raa_request.ras_token==next_assignment.ras_token
          && attempt.raa_status=assignment_unsent && attempt.raa_request.ras_runtime_id=None)
          (Runtime_assignment_saves.all state.runtime_assignment_saves))

let test_detail_histories_follow_refresh_and_workspace_owners () =
  let open Masc_tui_types in
  let module Fetched = Masc_tui_fetched in
  let state = create_state ~workspace:"history" ~local_base_path:"/workspace/history"
      ~port:0 ~refresh_interval:0. () in
  state.workspace_identity <- Workspace_identity_match;
  state.server_identity <- Some (identity state.local_base_path);
  let required = function Some request -> request | None -> Alcotest.fail "detail read did not acquire its owner" in
  let task_id = "task-original" and goal_id = "goal-original" in
  let task_rows status =
    Tui_decode.decode_task_history (`List [`Assoc
      ["type",`String "task_transition";"task",`String task_id;"agent",`String "original-keeper";
       "ts",`String "2026-10-19T01:00:00Z";"from_status",`String "todo";"to_status",`String status]])
    |> function Ok rows -> rows | Error detail -> Alcotest.fail detail in
  let goal_rows summary =
    Tui_decode.decode_goal_detail_timeline (`Assoc
      ["approval_queue_state",`Assoc ["state",`String "ready"];
       "timeline",`List [`Assoc ["ts",`String "2026-10-19T01:00:00Z";"kind",`String "goal_phase";
         "lane",`String "goal";"title",`String "Goal Phase";"summary",`String summary;"severity",`String "ok"]]])
    |> function
       | Ok (Tui_decode.Goal_timeline_ready rows) -> rows
       | Ok (Tui_decode.Goal_timeline_unavailable _) -> Alcotest.fail "original goal source became unavailable"
       | Error detail -> Alcotest.fail detail in
  let task_view () = Fetched.view_for ~equal:String.equal state.task_history ~key:task_id in
  let goal_view () = Fetched.view_for ~equal:String.equal state.goal_timeline ~key:goal_id in
  let previous = task_rows "todo" and current = task_rows "in_progress" and repaired = task_rows "done" in
  let initial = begin_task_history_read state ~task_id |> required in
  complete_task_history_read state initial (Error "initial history source unavailable");
  let old = begin_task_history_read state ~task_id |> required in
  let owner = begin_task_history_read state ~task_id |> required in
  complete_task_history_read state old (Ok previous);
  Alcotest.(check bool) "no-value retry retains original failure and rejects the old success" true
    (Fetched.is_current ~equal:String.equal state.task_history owner
     && Fetched.in_flight state.task_history && Fetched.value (task_view ()) = None
     && task_view () = Fetched.Failed "initial history source unavailable");
  complete_task_history_read state owner (Error "current retry failed");
  Alcotest.(check bool) "latest no-value failure replaces cause without inventing history" true
    (not (Fetched.in_flight state.task_history) && task_view () = Fetched.Failed "current retry failed");
  let recovery = begin_task_history_read state ~task_id |> required in
  complete_task_history_read state owner (Ok previous);
  Alcotest.(check bool) "duplicate retired completion cannot settle retry recovery" true
    (Fetched.is_current ~equal:String.equal state.task_history recovery
     && task_view () = Fetched.Failed "current retry failed");
  complete_task_history_read state recovery (Ok current);
  let old_refresh = begin_task_history_read state ~task_id |> required in
  let refresh = begin_task_history_read state ~task_id |> required in
  Alcotest.(check bool) "refresh retains original observed history while pending" true
    (Fetched.in_flight state.task_history && Fetched.value (task_view ()) = Some current);
  complete_task_history_read state refresh (Error "history source unavailable");
  complete_task_history_read state old_refresh (Ok previous);
  Alcotest.(check bool) "old success cannot erase latest failure or original history" true
    (task_view () = Fetched.Stale (current,"history source unavailable"));
  let retry = begin_task_history_read state ~task_id |> required in
  Alcotest.(check bool) "retry retains the unrepaired source failure" true
    (Fetched.in_flight state.task_history && task_view () = Fetched.Stale (current,"history source unavailable"));
  complete_task_history_read state retry (Ok repaired);
  Alcotest.(check bool) "current original history resumes after source repair" true
    (task_view () = Fetched.Ready repaired && not (Fetched.in_flight state.task_history));
  let initial_goal = begin_goal_timeline_read state ~goal_id |> required in
  complete_goal_timeline_read state initial_goal
    (Ok (Tui_decode.Goal_timeline_unavailable (Tui_decode.Approval_queue_failure "original goal source unavailable")));
  let initial_goal_failure = match goal_view () with
    | Fetched.Failed cause -> cause | _ -> Alcotest.fail "typed unavailable Goal source acquired a successful value" in
  let old_goal = begin_goal_timeline_read state ~goal_id |> required in
  let goal = begin_goal_timeline_read state ~goal_id |> required in
  complete_goal_timeline_read state old_goal (Error "retired retry failure");
  Alcotest.(check bool) "Goal no-value retry retains original typed source cause and current owner" true
    (goal_view () = Fetched.Failed initial_goal_failure && Fetched.value (goal_view ()) = None
     && Fetched.is_current ~equal:String.equal state.goal_timeline goal
     && Fetched.in_flight state.goal_timeline);
  let original_goal = goal_rows "original Task is in progress" in
  complete_goal_timeline_read state goal (Ok (Tui_decode.Goal_timeline_ready original_goal));
  complete_goal_timeline_read state old_goal (Error "late retired failure");
  Alcotest.(check bool) "goal history retains its own current observation" true
    (goal_view () = Fetched.Ready original_goal);
  let goal_refresh = begin_goal_timeline_read state ~goal_id |> required in
  complete_goal_timeline_read state goal_refresh
    (Ok (Tui_decode.Goal_timeline_unavailable (Tui_decode.Approval_queue_failure "goal source unavailable")));
  Alcotest.(check bool) "goal refresh failure retains original observation" true
    (match goal_view () with Fetched.Stale (rows,_) -> rows=original_goal | _ -> false);
  let retired_task = begin_task_history_read state ~task_id |> required in
  let retired_goal = begin_goal_timeline_read state ~goal_id |> required in
  withdraw_detail_histories state;
  state.server_identity <- Some (identity "/workspace/replacement");
  complete_task_history_read state retired_task (Ok previous);
  complete_goal_timeline_read state retired_goal (Ok (Tui_decode.Goal_timeline_ready original_goal));
  Alcotest.(check bool) "withdrawal retires both original histories" true
    (task_view () = Fetched.Absent && goal_view () = Fetched.Absent);
  let replacement_task = begin_task_history_read state ~task_id |> required in
  let replacement_goal = begin_goal_timeline_read state ~goal_id |> required in
  complete_task_history_read state retired_task (Ok previous);
  complete_goal_timeline_read state retired_goal (Ok (Tui_decode.Goal_timeline_ready original_goal));
  Alcotest.(check bool) "same IDs in replacement workspace cannot borrow retired responses" true
    (Fetched.is_current ~equal:String.equal state.task_history replacement_task
     && Fetched.is_current ~equal:String.equal state.goal_timeline replacement_goal
     && task_view () = Fetched.Loading && goal_view () = Fetched.Loading);
  let replacement = goal_rows "replacement workspace observation" in
  complete_task_history_read state replacement_task (Ok repaired);
  complete_goal_timeline_read state replacement_goal (Ok (Tui_decode.Goal_timeline_ready replacement));
  Alcotest.(check bool) "replacement completes only with its own observations" true
    (task_view () = Fetched.Ready repaired && goal_view () = Fetched.Ready replacement)

let () =
  Alcotest.run "tui_server_identity_refresh"
    [ ( "server-identity-refresh"
      , [ Alcotest.test_case "detail histories retain exact refresh and workspace owners" `Quick
            test_detail_histories_follow_refresh_and_workspace_owners
        ; Alcotest.test_case "operation histories retain unfinished delivery and uncertain recovery owners" `Quick
            test_operation_histories_keep_unfinished_and_recovery_owners
        ; Alcotest.test_case "owned operation results progress between continuously refilled shared prefixes" `Quick
            test_owned_results_progress_between_shared_queue_prefixes
        ; Alcotest.test_case "catalogue consumers share reads and accumulate fresh demand" `Quick
            test_catalog_demands_share_and_refresh_after_current_read
        ; Alcotest.test_case "catalogue refresh retains observation, failure and empty success" `Quick
            test_catalog_refresh_retains_observation_and_empty_success
        ; Alcotest.test_case "catalogue demand survives withdrawal without redundant rereads" `Quick
            test_catalog_withdrawal_folds_demand_into_reconfirmation
        ; Alcotest.test_case "assignment receipt retains original choice after navigation and withdrawal" `Quick
            test_assignment_receipt_keeps_original_choice_after_withdrawal
        ; Alcotest.test_case "assignment, editor and Sandbox saves serialize per Keeper" `Quick
            test_assignment_serializes_same_keeper_config_intents
        ; Alcotest.test_case "Sandbox shortcut binds only selected profile to observed revision" `Quick
            test_sandbox_shortcut_uses_observed_revision
        ; Alcotest.test_case "Sandbox and editor saves share pending ownership without losing recovery" `Quick
            test_sandbox_and_editor_saves_share_pending_ownership
        ; Alcotest.test_case "Sandbox receipt retains frozen source through withdrawal" `Quick
            test_sandbox_receipt_keeps_frozen_source_after_withdrawal
        ; Alcotest.test_case "settings save retains original receipt through withdrawal" `Quick
            test_settings_save_keeps_receipt_through_withdrawal
        ; Alcotest.test_case "settings recovery joins changed values to a fresh revision" `Quick
            test_settings_save_recovers_changes_on_fresh_revision
        ; Alcotest.test_case "settings origin refusal preserves input without dispatch" `Quick
            test_settings_save_not_sent_preserves_origin_input
        ; Alcotest.test_case "config projection retains source through unavailable model interpretation" `Quick
            test_runtime_snapshot_preserves_source_when_models_unavailable
        ; Alcotest.test_case "config projection joins exact source and server group observations" `Quick
            test_runtime_snapshot_models_use_same_source_and_server_groups
        ; Alcotest.test_case "config projection reuse preserves draft and observation ownership" `Quick
            test_runtime_snapshot_refresh_reuses_draft_without_changing_ownership
        ; Alcotest.test_case "document save owns exact input across refreshed observation" `Quick
            test_runtime_document_save_owns_exact_input_across_refresh
        ; Alcotest.test_case "late document receipt retains same-text successor and foreign drafts" `Quick
            test_runtime_document_late_success_keeps_same_text_successor
        ; Alcotest.test_case "unknown document commit requires post-outcome read and explicit basis" `Quick
            (fun () -> test_runtime_document_uncertainty_requires_new_read
              (Masc_tui_types.Form_unconfirmed "connection ended after possible dispatch"))
        ; Alcotest.test_case "unknown document durability requires post-outcome read and explicit basis" `Quick
            (fun () -> test_runtime_document_uncertainty_requires_new_read
              (Masc_tui_types.Form_saved (runtime_document_receipt Durability_unconfirmed)))
        ; Alcotest.test_case "runtime form transforms only its opening source" `Quick
            test_runtime_form_prepares_original_revision
        ; Alcotest.test_case "runtime form unknown save retains input and rejects duplicate" `Quick
            test_runtime_form_retains_unknown_and_rejects_duplicate
        ; Alcotest.test_case "runtime account form keeps typed refusal in original workspace" `Quick
            test_runtime_account_save_keeps_typed_form_and_workspace
        ; Alcotest.test_case "settings preparation hands original document to one editor intent" `Quick
            test_settings_preparation_hands_off_original_snapshot_once
        ; Alcotest.test_case "settings preparation withdraws focus and workspace owners" `Quick
            test_settings_preparation_retires_focus_and_workspace_owners
        ; Alcotest.test_case "metrics selection and cleanup preserve request ownership" `Quick
            test_keeper_log_selection_and_late_cleanup_keep_original_owner
        ; Alcotest.test_case "metrics refresh shares work and retains partial observations on failure" `Quick
            test_keeper_log_refresh_coalesces_and_failed_revalidation_keeps_partial_rows
        ; Alcotest.test_case "metrics suspension retains data without old authority" `Quick
            test_keeper_log_suspension_preserves_snapshot_without_old_authority
        ; Alcotest.test_case "creation cancellation retains receipt when notification queue is full" `Quick
            test_creation_receipt_survives_full_notification_queue_cancel
        ; Alcotest.test_case "creation interleaving preserves successor draft and focus" `Quick
            test_creation_interleaving_preserves_new_draft_and_focus
        ; Alcotest.test_case "creation receipts retain original scope after withdrawal" `Quick
            test_creation_receipt_retains_original_scope_after_withdrawal
        ; Alcotest.test_case "creation uncertainty requires explicit retry" `Quick
            test_creation_unknown_requires_explicit_create_only_retry
        ; Alcotest.test_case "response decode preserves cache and typed results" `Quick
            test_response_decode_keeps_cache_and_typed_results
        ; Alcotest.test_case "decode completion cannot consume new navigation" `Quick
            test_decode_completion_cannot_consume_new_navigation
        ; Alcotest.test_case "response decode preserves nested failures" `Quick
            test_response_decode_preserves_nested_failures
        ; Alcotest.test_case "response decode without runtime stays synchronous" `Quick
            test_response_decode_without_runtime_stays_synchronous
        ; Alcotest.test_case "datasets settle independently under original request ownership" `Quick
            test_datasets_settle_independently_under_original_request
        ; Alcotest.test_case "Board delivery preserves sibling and terminal remainder" `Quick
            test_board_delivery_retains_sibling_and_terminal_remainder
        ; Alcotest.test_case "Board navigation supersedes both dataset owners" `Quick
            test_board_delivery_supersedes_both_parts_without_replaying_early_data
        ; Alcotest.test_case "Board delivery preserves workspace and refresh guards" `Quick
            test_board_delivery_preserves_workspace_and_refresh_guards
        ; Alcotest.test_case "Board census distinguishes unread loading empty and failure" `Quick
            test_board_census_distinguishes_unread_loading_empty_and_failure
        ; Alcotest.test_case "Board census retains observations through retry and missing result" `Quick
            test_board_census_retains_values_through_retry_failure_and_missing_result
        ; Alcotest.test_case "Board census preserves successor and workspace ownership" `Quick
            test_board_census_old_cleanup_and_workspace_withdrawal
        ; Alcotest.test_case "dataset admission rejects retired workspace and refresh" `Quick
            test_dataset_admission_rejects_retired_workspace_and_refresh
        ; Alcotest.test_case "answer followup retains exact current source observations" `Quick
            test_answer_followup_retains_current_source_observations
        ; Alcotest.test_case "answer followup withdraws original reader without borrowing successor" `Quick
            test_answer_followup_withdraws_reader_without_borrowing_successor
        ; Alcotest.test_case "initial probe requires current cold workspace" `Quick
            test_initial_probe_requires_current_cold_workspace
        ; Alcotest.test_case "initial probe cannot revive a retired refresh" `Quick
            test_initial_probe_rejects_retired_refresh
        ; Alcotest.test_case "roster arrives before unrelated readers and settles once" `Quick
            test_early_roster_settles_before_slow_siblings_once
        ; Alcotest.test_case "question origin survives answer and workspace change" `Quick
            test_question_origin_survives_answer_and_workspace_change
        ; Alcotest.test_case "answer receipt has one original submission owner" `Quick
            test_answer_receipt_has_one_original_submission_owner
        ; Alcotest.test_case "answer receipt survives full mailbox and worker cancellation" `Quick
            test_answer_receipt_survives_full_mailbox_and_worker_cancellation
        ; Alcotest.test_case "local and HTTP sources progress independently" `Quick
            test_local_read_and_http_sources_progress_independently
        ; Alcotest.test_case "local read refuses retired epochs and foreign paths" `Quick
            test_local_read_refuses_retired_epoch_and_wrong_path
        ; Alcotest.test_case "local read failure releases its slot for retry" `Quick
            test_local_read_failure_settles_and_can_be_retried
        ; Alcotest.test_case "metadata admits input before work completes" `Quick
            test_keeper_metadata_admits_input_before_work_completes
        ; Alcotest.test_case "local source failures remain independent" `Quick
            test_local_source_failures_are_independent
        ; Alcotest.test_case "local refresh burst keeps active read and one followup" `Quick
            test_local_refresh_burst_keeps_active_read_and_one_followup
        ; Alcotest.test_case "failure preserves followup and withdrawal retires it" `Quick
            test_failed_read_keeps_followup_and_withdrawal_retires_it
        ; Alcotest.test_case "concurrent creations retain individual refresh coverage" `Quick
            test_concurrent_created_keepers_retain_individual_refresh_coverage
        ; Alcotest.test_case "archive cache does not cross equal-stat source files" `Quick
            test_archive_cache_does_not_cross_equal_stat_files
        ; Alcotest.test_case "created Keeper waits for owned metadata without Work" `Quick
            test_created_keeper_waits_for_owned_metadata_without_work
        ; Alcotest.test_case "fresh metadata confirms deletion without detail retargeting" `Quick
            test_deleted_keeper_reconciles_after_fresh_metadata
        ; Alcotest.test_case "cancelled local cache read releases the source for follow-up" `Quick
            test_local_cache_cancel_releases_source_for_followup
        ; Alcotest.test_case "context refuses queued prior-trace results" `Quick
            test_live_context_refuses_changed_trace_before_reconciliation
        ; Alcotest.test_case "chat target owns context independently of roster cursor" `Quick
            test_live_context_chat_target_is_independent_of_roster_cursor
        ; Alcotest.test_case "context suspension cancels and retires the source" `Quick
            test_live_context_suspension_cancels_and_retires_same_path_read
        ; Alcotest.test_case "local tickets cannot cross sources or suspension" `Quick
            test_local_source_tickets_cannot_cross_or_survive_suspension
        ; Alcotest.test_case "early roster preserves source and workspace ownership" `Quick
            test_early_roster_preserves_read_ownership
        ; Alcotest.test_case "refresh observations retain independent source outcomes" `Quick
            test_refresh_progress_tracks_independent_sources_and_interruption
        ; Alcotest.test_case "refresh observations retain partial receipts without granting dataset authority" `Quick
            test_refresh_progress_retains_partial_runtime_receipt
        ; Alcotest.test_case "composed refresh receipts retain success, partial and failure states" `Quick
            test_composed_refresh_receipts_preserve_all_availability_cases
        ; Alcotest.test_case "refresh observations reject superseded source authority" `Quick
            test_refresh_progress_rejects_old_request_and_workspace
        ; Alcotest.test_case "Board child receipts survive parent interruption" `Quick
            test_board_child_receipts_survive_parent_interruption
        ; Alcotest.test_case "Board child evidence preserves parent availability" `Quick
            test_board_component_receipts_keep_parent_category
        ; Alcotest.test_case "progress inbox retains request and workspace ownership" `Quick
            test_progress_inbox_cannot_cross_refresh_or_workspace
        ; Alcotest.test_case "early questions settle once without granting authority" `Quick
            test_early_asks_apply_once_without_granting_authority
        ; Alcotest.test_case "unadmitted cold questions retain their source owner" `Quick
            test_unadmitted_cold_asks_defer_without_consuming_the_read
        ; Alcotest.test_case "early questions reject foreign stale and retired readings" `Quick
            test_early_asks_reject_foreign_stale_and_retired_authority
        ; Alcotest.test_case "answer submission retires pre-answer listings" `Quick
            test_question_answer_retires_pre_answer_reads
        ; Alcotest.test_case "question listings respect supersession and workspace suspension" `Quick
            test_question_read_supersession_and_workspace_suspension
        ; Alcotest.test_case "overview rejects superseded refresh observations" `Quick
            test_overview_preview_rejects_superseded_reading
        ; Alcotest.test_case "overview preview preserves confirmed state and authority" `Quick
            test_overview_preview_preserves_confirmed_state_and_authority
        ; Alcotest.test_case "overview completion retires previews and late delivery" `Quick
            test_overview_refresh_finish_retires_preview_and_late_delivery
        ; Alcotest.test_case "overview preview refuses foreign and retired authority" `Quick
            test_overview_preview_refuses_foreign_or_retired_authority
        ; Alcotest.test_case "Child retirement preserves a running full audit" `Quick
            test_child_read_epoch_retains_running_audit
        ; Alcotest.test_case "native observations retire without losing queued audit" `Quick
            test_native_task_read_epoch_retirement
        ; Alcotest.test_case "unsent resource and log intents survive reconfirmation" `Quick
            test_unsent_resource_and_log_intents_survive_reconfirmation
        ; Alcotest.test_case "effect observations resume without repeating effects" `Quick
            test_effect_observations_resume_without_repeating_effects
        ; Alcotest.test_case "account read intents survive repeated suspension" `Quick
            test_account_read_intents_survive_repeated_suspension
        ; Alcotest.test_case "nested reader intents survive repeated suspension" `Quick
            test_pending_nested_reader_intents_survive_repeated_suspension
        ; Alcotest.test_case "task receipts wait for identity and roster" `Quick
            test_task_receipts_wait_for_identity_and_roster
        ; Alcotest.test_case "nested read owners retire without losing selection" `Quick
            test_nested_read_owners_retire_without_losing_selection
        ; Alcotest.test_case "discarded bundle retires readings before reconfirming A" `Quick
            test_discarded_bundle_retires_readings_before_reconfirming_a
        ; Alcotest.test_case "preset selection waits without an unconfirmed read" `Quick
            test_preset_selection_waits_without_owning_an_unconfirmed_read
        ; Alcotest.test_case "operation receipt outlives queued follow-up read" `Quick
            test_operation_receipt_outlives_queued_followup_read
        ; Alcotest.test_case "unknown voice save read retirement" `Quick
            test_unknown_voice_save_read_retirement
        ; Alcotest.test_case "detail focus waits for authoritative roster" `Quick
            test_detail_focus_waits_for_authoritative_roster
        ; Alcotest.test_case "same base and different MASC root retain separate inputs" `Quick
            test_same_base_with_different_masc_root_cannot_restore_inputs
        ; Alcotest.test_case "request authority requires complete current identity" `Quick
            test_request_authority_requires_complete_current_identity
        ; Alcotest.test_case "same endpoint replaces A with B" `Quick
            test_same_endpoint_restart_replaces_a_with_b
        ; Alcotest.test_case "failed probe is unread, not stale" `Quick
            test_failed_probe_is_unread_not_stale
        ; Alcotest.test_case "canonical aliases match" `Quick
            test_workspace_identity_matches_canonical_paths
        ; Alcotest.test_case "workspace identity compares the masc root" `Quick
            test_workspace_identity_compares_the_masc_root
        ; Alcotest.test_case "mismatch preserves both paths" `Quick
            test_workspace_identity_mismatch_keeps_both_paths
        ; Alcotest.test_case "Broadcast retry uses verified workspace store" `Quick
            test_broadcast_retry_scope_follows_verified_workspace
        ; Alcotest.test_case "detail intents wait for comparable identity" `Quick
            test_detail_intents_wait_for_comparable_identity
        ; Alcotest.test_case "local rows are unread until read" `Quick
            test_local_rows_are_unread_until_the_workspace_is_read
        ; Alcotest.test_case "an unread after a match keeps it unconfirmed" `Quick
            test_unread_after_a_match_keeps_it_unconfirmed
        ; Alcotest.test_case "writes wait for a confirmed identity" `Quick
            test_writes_wait_for_a_confirmed_identity
        ; Alcotest.test_case "a missing path does not hide a mismatch" `Quick
            test_partial_identity_keeps_definite_mismatches
        ; Alcotest.test_case "deletion inventory waits for workspace reconfirmation" `Quick
            test_deletion_inventory_waits_for_reconfirmed_workspace
        ; Alcotest.test_case "uncertainty retires reads while admitted operations survive" `Quick
            test_uncertain_identity_retires_reads_not_admitted_operations
        ; Alcotest.test_case "suspension folds a queued lanes reread into resume" `Quick
            test_suspension_folds_queued_lanes_reread_into_resume
        ] )
    ]
