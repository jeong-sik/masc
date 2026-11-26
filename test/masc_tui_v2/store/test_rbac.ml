(** Complete TUI RBAC test suite: core SSOT projection & exhaustive access
    decision matrix, poller/loader/SSE suppression, action/hotkey/modal/
    palette/slash gating, truthful chrome & locked screen rendering, and
    2-step bootstrap + in-place demotion / auth-loss cleanup. *)

open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol
open Masc_tui_store
open Masc_tui_term
open Masc_tui_screens_core
open Masc_tui_screens_ops
open Masc_tui_screens_domain

let t0 = Clock.Mono.of_ns 1_000_000_000L
let t1 = Clock.Mono.of_ns 2_000_000_000L
let t6 = Clock.Mono.of_ns 7_000_000_000L

let char_key ?(mods = Keymap.Input.no_mods) s : Keymap.Input.key_event =
  { key = Keymap.Input.Char s; mods }

let ctrl_key s = char_key ~mods:{ Keymap.Input.no_mods with ctrl = true } s

let contains_ci ~needle haystack = Store_scroll.contains_ci ~needle haystack

let grid_all_text (grid : Cell_grid.t) =
  let cols = Cell_grid.cols grid and rows = Cell_grid.rows grid in
  let buf = Buffer.create (cols * rows) in
  for y = 0 to rows - 1 do
    for x = 0 to cols - 1 do
      let c = Cell_grid.get grid ~x ~y in
      match c.glyph with
      | Cell_grid.Empty -> Buffer.add_char buf ' '
      | Cell_grid.Ascii ch -> Buffer.add_char buf ch
      | Cell_grid.Braille m -> Buffer.add_string buf (Cell_grid.braille_utf8 m)
      | Cell_grid.Utf8 s -> Buffer.add_string buf s
      | Cell_grid.Continuation -> ()
    done;
    Buffer.add_char buf '\n'
  done;
  Buffer.contents buf

let render_full_frame ?(cols = 140) ?(rows = 40) (model : Model.t) =
  let grid = Cell_grid.create ~cols ~rows in
  let cache = Masc_tui_ui.Card.Cache.create () in
  let render_body rect g =
    match Model.active_inspector model with
    | Some (Nav.Verification_inspector id) ->
        Screen_work.render_verification ~req_id:id ~model ~cache ~rect g
    | Some (Nav.Tool_inspector name) ->
        Screen_runtime.render_inspector ~target:(`Tool name) ~model ~cache ~rect
          g
    | Some (Nav.Skill_inspector ref_s) ->
        Screen_runtime.render_inspector ~target:(`Skill ref_s) ~model ~cache
          ~rect g
    | Some (Nav.Exact_run_inspector run_id) ->
        Screen_runtime.render_inspector ~target:(`Exact_run run_id) ~model
          ~cache ~rect g
    | Some (Nav.File_inspector peek) ->
        Screen_file_peek.render ~peek ~model ~cache ~rect g
    | None -> (
        match model.nav.workspace with
        | Nav.Pulse -> Screen_pulse.render ~model ~cache ~rect g
        | Nav.Work -> Screen_work.render ~model ~cache ~rect g
        | Nav.Knowledge -> Screen_knowledge.render ~model ~cache ~rect g
        | Nav.Keepers -> Screen_keepers.render ~model ~cache ~rect g
        | Nav.Runtime -> Screen_runtime.render ~model ~cache ~rect g
        | Nav.Infra -> Screen_infra.render ~model ~cache ~rect g)
  in
  let render_overlay rect g = Overlays.render ~model ~cache ~rect g in
  ignore (Chrome.render_frame ~model ~cache ~render_body ~render_overlay grid);
  grid_all_text grid

let sample_health ?(mode = Rbac.Single_user) () : Wire_common.server_health =
  {
    ok = true;
    live = Some true;
    ready = Some true;
    phase = Some "ready";
    status = "ok";
    version = "0.99.0";
    binary_commit = Some "deadbeef";
    uptime_display = Some "1h";
    uptime_sec = Some 3600.0;
    scope =
      Wire_common.Full_health
        {
          instance_id = Some "inst-rbac-1";
          base_path = "/tmp/masc";
          masc_root = "/tmp/masc/.masc";
          workspace_sha256 = Some "sha-rbac-1";
        };
    gc = None;
    active_keepers = Some 1;
    account_mode = mode;
    auth_methods = { Rbac.google = true; github = false; dev_token = true };
  }

let sample_shell ?(auth : Wire_fleet.shell_auth_summary option) () :
    Wire_fleet.dashboard_shell =
  {
    generated_at_unix = Some 1_700_000_000.0;
    project = Some "masc";
    version = Some "0.99.0";
    counts =
      {
        agents = 2;
        tasks = 3;
        tasks_done_24h = 1;
        keepers = 1;
        persisted_keepers = Observed.unreported;
        configured_keepers = Observed.unreported;
        total_runtimes = 1;
      };
    scorecard_24h =
      {
        tasks_done_24h = Observed.unreported;
        tasks_done_total = Observed.unreported;
        tasks_in_progress = Observed.unreported;
        tasks_claimed = Observed.unreported;
        tasks_awaiting_verification = Observed.unreported;
        tasks_todo = Observed.unreported;
        tasks_cancelled = Observed.unreported;
        goals_completed_24h = Observed.unreported;
        verifications_passed_24h = Observed.unreported;
        verifications_rejected_24h = Observed.unreported;
        board_posts_24h = Observed.unreported;
        turns_24h = Observed.unreported;
        cost_24h_usd = Observed.unreported;
      };
    groups = [];
    auth;
  }

let su_auth_admin_off : Wire_fleet.shell_auth_summary =
  {
    enabled = false;
    require_token = false;
    token_present = false;
    token_valid = false;
    token_agent = None;
    requested_agent = None;
    effective_agent = None;
    effective_role = Some Rbac.Admin;
    effective_admin = Some true;
    auth_error_code = None;
    auth_error_detail = None;
    can_keeper_msg = true;
    keeper_msg_error = None;
  }

let su_auth_worker : Wire_fleet.shell_auth_summary =
  {
    enabled = true;
    require_token = true;
    token_present = true;
    token_valid = true;
    token_agent = Some "worker-1";
    requested_agent = None;
    effective_agent = Some "worker-1";
    effective_role = Some Rbac.Worker;
    effective_admin = Some false;
    auth_error_code = None;
    auth_error_detail = None;
    can_keeper_msg = true;
    keeper_msg_error = None;
  }

let su_auth_loopback_missing_token : Wire_fleet.shell_auth_summary =
  {
    enabled = true;
    require_token = true;
    token_present = false;
    token_valid = false;
    token_agent = None;
    requested_agent = None;
    effective_agent = None;
    effective_role = None;
    effective_admin = Some false;
    auth_error_code = Some "missing_token";
    auth_error_detail = Some "Bearer token required on single-user server";
    can_keeper_msg = false;
    keeper_msg_error = Some "missing_token";
  }

let ma_human_admin_session : Rbac.auth_session =
  Rbac.Multi_account_signed_in
    {
      principal = { kind = Rbac.Human; id = "usr-admin" };
      role = Rbac.Admin;
      binding = { kind = Rbac.Session; id = "sess-1" };
      auth_methods = Rbac.default_auth_methods;
    }

let ma_human_admin_pat : Rbac.auth_session =
  Rbac.Multi_account_signed_in
    {
      principal = { kind = Rbac.Human; id = "usr-admin" };
      role = Rbac.Admin;
      binding = { kind = Rbac.Pat; id = "pat-1" };
      auth_methods = Rbac.default_auth_methods;
    }

let ma_human_worker_pat : Rbac.auth_session =
  Rbac.Multi_account_signed_in
    {
      principal = { kind = Rbac.Human; id = "usr-worker" };
      role = Rbac.Worker;
      binding = { kind = Rbac.Pat; id = "pat-2" };
      auth_methods = Rbac.default_auth_methods;
    }

let ma_service_worker : Rbac.auth_session =
  Rbac.Multi_account_signed_in
    {
      principal = { kind = Rbac.Service; id = "svc-runner" };
      role = Rbac.Worker;
      binding = { kind = Rbac.Service_credential; id = "sc-1" };
      auth_methods = Rbac.default_auth_methods;
    }

let su_optional_token_admin : Rbac.auth_session =
  Rbac.Single_user_local
    {
      auth_methods = Rbac.default_auth_methods;
      auth_enabled = true;
      require_token = false;
      token_present = false;
      token_valid = false;
      effective_agent = None;
      role = Rbac.Admin;
      effective_admin = true;
      can_keeper_msg = true;
      auth_error_code = None;
      auth_error_detail = None;
    }

let su_token_admin : Rbac.auth_session =
  Rbac.Single_user_local
    {
      auth_methods = Rbac.default_auth_methods;
      auth_enabled = true;
      require_token = true;
      token_present = true;
      token_valid = true;
      effective_agent = Some "root-admin";
      role = Rbac.Admin;
      effective_admin = true;
      can_keeper_msg = true;
      auth_error_code = None;
      auth_error_detail = None;
    }

let su_auth_required : Rbac.auth_session =
  Rbac.Single_user_auth_required
    {
      auth_methods = Rbac.default_auth_methods;
      reason = Rbac.Token_required;
    }

let ma_signed_out : Rbac.auth_session =
  Rbac.Multi_account_signed_out
    {
      auth_methods = Rbac.default_auth_methods;
      reason = Rbac.Signed_out (Some "Unauthorized");
    }

let all_route_accesses : (string * Rbac.route_access) list =
  [
    ("Always_public", Rbac.Always_public);
    ("Single_user_shell_probe", Rbac.Single_user_shell_probe);
    ("Multi_account_whoami_probe", Rbac.Multi_account_whoami_probe);
    ("Workspace_read", Rbac.Workspace_read);
    ("Single_user_read", Rbac.Single_user_read);
    ("Single_user_write", Rbac.Single_user_write);
    ("Admin_only", Rbac.Admin_only);
    ("Single_user_admin_only", Rbac.Single_user_admin_only);
    ("Single_user_token_admin_only", Rbac.Single_user_token_admin_only);
    ("Own_provider_manage", Rbac.Own_provider_manage);
    ("Own_keeper_sandbox_read", Rbac.Own_keeper_sandbox_read);
    ("Memory_diff_read(keeper)", Rbac.Memory_diff_read { keeper_scoped = true });
    ( "Memory_diff_read(workspace)",
      Rbac.Memory_diff_read { keeper_scoped = false } );
    ("Machine_play", Rbac.Machine_play);
  ]

(* 1. Core RBAC parsers & single-user shell.auth projection *)
let test_core_parsers_and_projection () =
  Alcotest.(check bool) "Single_user mode parses" true
    (Result.equal ~ok:Rbac.equal_account_mode ~error:String.equal
       (Rbac.account_mode_of_string "Single_user")
       (Ok Rbac.Single_user));
  Alcotest.(check bool) "Multi_account mode parses" true
    (Result.equal ~ok:Rbac.equal_account_mode ~error:String.equal
       (Rbac.account_mode_of_string "Multi_account")
       (Ok Rbac.Multi_account));
  Alcotest.(check bool) "unknown mode fails closed" true
    (Result.is_error (Rbac.account_mode_of_string "multi"));
  Alcotest.(check bool) "admin/worker/player roles parse" true
    (Result.is_ok (Rbac.role_of_string "admin")
     && Result.is_ok (Rbac.role_of_string "worker")
     && Result.is_ok (Rbac.role_of_string "player"));
  Alcotest.(check bool) "unknown role rejected" true
    (Result.is_error (Rbac.role_of_string "superadmin"));
  Alcotest.(check bool) "principal kinds parse" true
    (Result.is_ok (Rbac.principal_kind_of_string "human")
     && Result.is_ok (Rbac.principal_kind_of_string "service")
     && Result.is_error (Rbac.principal_kind_of_string "bot"));
  Alcotest.(check bool) "binding kinds parse" true
    (Result.is_ok (Rbac.binding_kind_of_string "session")
     && Result.is_ok (Rbac.binding_kind_of_string "pat")
     && Result.is_ok (Rbac.binding_kind_of_string "service_credential")
     && Result.is_error (Rbac.binding_kind_of_string "cookie"));

  (* Non-strict loopback 200 with enabled=true, require_token=true, token_valid=false
     MUST fail closed to Single_user_auth_required, never Admin. *)
  let loopback_session =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:true ~require_token:true ~token_present:false ~token_valid:false
      ~effective_agent:None ~effective_role:None ~effective_admin:(Some false)
      ~can_keeper_msg:false ~auth_error_code:(Some "missing_token")
      ~auth_error_detail:(Some "token required")
  in
  Alcotest.(check bool) "loopback !token_valid -> Single_user_auth_required"
    true (Rbac.requires_auth_gate loopback_session);
  Alcotest.(check bool) "loopback !token_valid is never admin" false
    (Rbac.can_admin loopback_session);

  (* Valid token with missing role and effective_admin=false MUST fail closed, never fabricate Admin *)
  let missing_role_session =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:true ~require_token:true ~token_present:true ~token_valid:true
      ~effective_agent:(Some "mystery") ~effective_role:None
      ~effective_admin:(Some false) ~can_keeper_msg:false ~auth_error_code:None
      ~auth_error_detail:None
  in
  Alcotest.(check bool) "missing role with require_token fails closed" true
    (Rbac.requires_auth_gate missing_role_session);

  (* Auth disabled local dev mode: server resolves effective_role = Some Admin,
     grants can_admin, but Token_permission CanAdmin still requires token auth *)
  let auth_off =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:false ~require_token:false ~token_present:false
      ~token_valid:false ~effective_agent:(Some "dashboard")
      ~effective_role:(Some Rbac.Admin) ~effective_admin:(Some true)
      ~can_keeper_msg:true ~auth_error_code:None ~auth_error_detail:None
  in
  Alcotest.(check bool) "auth off grants local admin" true
    (Rbac.can_admin auth_off);
  Alcotest.(check bool) "auth off does not satisfy Token_permission CanAdmin"
    false (Rbac.can_single_user_token_admin auth_off);

  (* Token-enabled admin satisfies both can_admin and can_single_user_token_admin *)
  let tok_admin =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:true ~require_token:true ~token_present:true
      ~token_valid:true ~effective_agent:(Some "admin")
      ~effective_role:(Some Rbac.Admin) ~effective_admin:(Some true)
      ~can_keeper_msg:true ~auth_error_code:None ~auth_error_detail:None
  in
  Alcotest.(check bool) "token admin grants can_admin and can_single_user_token_admin"
    true (Rbac.can_admin tok_admin && Rbac.can_single_user_token_admin tok_admin);

  (* Optional token without valid token: effective_role=Some Admin locally,
     but Token_permission CanAdmin requires require_token && token_valid *)
  let optional_no_token =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:true ~require_token:false ~token_present:false
      ~token_valid:false ~effective_agent:(Some "dashboard")
      ~effective_role:(Some Rbac.Admin) ~effective_admin:(Some true)
      ~can_keeper_msg:true ~auth_error_code:None ~auth_error_detail:None
  in
  Alcotest.(check bool) "optional-token without token cannot run Token_permission CanAdmin"
    false (Rbac.can_single_user_token_admin optional_no_token);

  (* Token worker stays Worker, never Admin *)
  let worker_sess =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:true ~require_token:true ~token_present:true ~token_valid:true
      ~effective_agent:(Some "w1") ~effective_role:(Some Rbac.Worker)
      ~effective_admin:(Some false) ~can_keeper_msg:true ~auth_error_code:None
      ~auth_error_detail:None
  in
  Alcotest.(check bool) "worker is authenticated" true
    (Rbac.is_authenticated worker_sess);
  Alcotest.(check bool) "worker is not admin" false (Rbac.can_admin worker_sess);
  Alcotest.(check bool) "worker role = Worker" true
    (Option.equal Rbac.equal_role (Rbac.role_of_session worker_sess)
       (Some Rbac.Worker))

(* 2. Exhaustive RBAC decision matrix across all sessions x all route tiers *)
let test_exhaustive_decision_matrix () =
  let check_allowed label session (r_lbl, route) expected =
    Alcotest.(check bool)
      (Printf.sprintf "%s -> %s" label r_lbl)
      expected
      (Rbac.is_allowed session route)
  in
  (* Probing_health: ONLY Always_public *)
  List.iter
    (fun (name, route) ->
      let expected =
        match route with
        | Rbac.Always_public -> true
        | Rbac.Single_user_shell_probe
        | Rbac.Multi_account_whoami_probe
        | Rbac.Workspace_read
        | Rbac.Single_user_read
        | Rbac.Single_user_write
        | Rbac.Admin_only
        | Rbac.Single_user_admin_only
        | Rbac.Single_user_token_admin_only
        | Rbac.Own_provider_manage
        | Rbac.Own_keeper_sandbox_read
        | Rbac.Memory_diff_read _
        | Rbac.Machine_play ->
            false
      in
      check_allowed "Probing_health" Rbac.Probing_health (name, route) expected)
    all_route_accesses;

  (* Probing_single_user: ONLY Always_public + Single_user_shell_probe *)
  let probe_su =
    Rbac.Probing_single_user { auth_methods = Rbac.default_auth_methods }
  in
  List.iter
    (fun (name, route) ->
      let expected =
        match route with
        | Rbac.Always_public | Rbac.Single_user_shell_probe -> true
        | Rbac.Multi_account_whoami_probe
        | Rbac.Workspace_read
        | Rbac.Single_user_read
        | Rbac.Single_user_write
        | Rbac.Admin_only
        | Rbac.Single_user_admin_only
        | Rbac.Single_user_token_admin_only
        | Rbac.Own_provider_manage
        | Rbac.Own_keeper_sandbox_read
        | Rbac.Memory_diff_read _
        | Rbac.Machine_play ->
            false
      in
      check_allowed "Probing_single_user" probe_su (name, route) expected)
    all_route_accesses;

  (* Probing_multi_account: ONLY Always_public + Multi_account_whoami_probe *)
  let probe_ma =
    Rbac.Probing_multi_account { auth_methods = Rbac.default_auth_methods }
  in
  List.iter
    (fun (name, route) ->
      let expected =
        match route with
        | Rbac.Always_public | Rbac.Multi_account_whoami_probe -> true
        | Rbac.Single_user_shell_probe
        | Rbac.Workspace_read
        | Rbac.Single_user_read
        | Rbac.Single_user_write
        | Rbac.Admin_only
        | Rbac.Single_user_admin_only
        | Rbac.Single_user_token_admin_only
        | Rbac.Own_provider_manage
        | Rbac.Own_keeper_sandbox_read
        | Rbac.Memory_diff_read _
        | Rbac.Machine_play ->
            false
      in
      check_allowed "Probing_multi_account" probe_ma (name, route) expected)
    all_route_accesses;

  (* Unauthenticated & Auth_unavailable: ONLY Always_public *)
  List.iter
    (fun (s_lbl, sess) ->
      List.iter
        (fun (r_lbl, route) ->
          let expected =
            match route with
            | Rbac.Always_public -> true
            | Rbac.Single_user_shell_probe
            | Rbac.Multi_account_whoami_probe
            | Rbac.Workspace_read
            | Rbac.Single_user_read
            | Rbac.Single_user_write
            | Rbac.Admin_only
            | Rbac.Single_user_admin_only
            | Rbac.Single_user_token_admin_only
            | Rbac.Own_provider_manage
            | Rbac.Own_keeper_sandbox_read
            | Rbac.Memory_diff_read _
            | Rbac.Machine_play ->
                false
          in
          check_allowed s_lbl sess (r_lbl, route) expected)
        all_route_accesses)
    [
      ("SU_auth_required", su_auth_required);
      ("MA_signed_out", ma_signed_out);
      ( "Auth_unavailable",
        Rbac.Auth_unavailable { mode = None; reason = "probe failed" } );
    ];

  (* Multi-account Admin PAT: NEVER gets Admin_only (Pat_cannot_admin), NEVER gets SU-only *)
  Alcotest.(check bool) "MA Admin PAT denied Admin_only with Pat_cannot_admin"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_human_admin_pat Rbac.Admin_only)
       (Rbac.Denied Rbac.Pat_cannot_admin));
  Alcotest.(check bool) "MA Admin PAT allowed Workspace_read" true
    (Rbac.is_allowed ma_human_admin_pat Rbac.Workspace_read);
  Alcotest.(check bool) "MA Admin PAT allowed Own_provider_manage" true
    (Rbac.is_allowed ma_human_admin_pat Rbac.Own_provider_manage);
  Alcotest.(check bool) "MA Admin PAT denied Single_user_read" false
    (Rbac.is_allowed ma_human_admin_pat Rbac.Single_user_read);
  Alcotest.(check bool) "MA Admin PAT denied Single_user_admin_only" false
    (Rbac.is_allowed ma_human_admin_pat Rbac.Single_user_admin_only);

  (* Multi-account Admin Session: gets Admin_only + Workspace_read + Own_provider_manage, NO SU-only *)
  Alcotest.(check bool) "MA Admin Session allowed Admin_only" true
    (Rbac.is_allowed ma_human_admin_session Rbac.Admin_only);
  Alcotest.(check bool) "MA Admin Session denied Single_user_token_admin_only"
    false
    (Rbac.is_allowed ma_human_admin_session Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "MA Admin Session denied Single_user_admin_only" false
    (Rbac.is_allowed ma_human_admin_session Rbac.Single_user_admin_only);

  (* Multi-account Worker PAT: Workspace_read + Own_provider_manage + world/keeper memory diff, denied Admin_only & SU *)
  Alcotest.(check bool) "MA Worker PAT allowed Workspace_read" true
    (Rbac.is_allowed ma_human_worker_pat Rbac.Workspace_read);
  Alcotest.(check bool) "MA Worker PAT allowed Own_provider_manage" true
    (Rbac.is_allowed ma_human_worker_pat Rbac.Own_provider_manage);
  Alcotest.(check bool) "MA Worker PAT allowed keeper-scoped memory diff" true
    (Rbac.is_allowed ma_human_worker_pat
       (Rbac.Memory_diff_read { keeper_scoped = true }));
  Alcotest.(check bool) "MA Worker PAT allowed workspace-wide memory diff (Workspace_read)"
    true
    (Rbac.is_allowed ma_human_worker_pat
       (Rbac.Memory_diff_read { keeper_scoped = false }));
  Alcotest.(check bool) "MA Worker PAT denied Admin_only" false
    (Rbac.is_allowed ma_human_worker_pat Rbac.Admin_only);

  (* Multi-account Service Worker: denied Own_provider_manage with Service_cannot_manage_own_provider *)
  Alcotest.(check bool) "MA Service Worker denied Own_provider_manage" true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_service_worker Rbac.Own_provider_manage)
       (Rbac.Denied Rbac.Service_cannot_manage_own_provider));
  Alcotest.(check bool) "MA Service Worker denied keeper-scoped memory diff"
    false
    (Rbac.is_allowed ma_service_worker
       (Rbac.Memory_diff_read { keeper_scoped = true }));

  (* Single-user Worker: allowed SU read/write, denied Admin_only / SU_admin / Token_admin / Own_provider_manage *)
  Alcotest.(check bool) "SU Worker allowed Single_user_read" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Single_user_read);
  Alcotest.(check bool) "SU Worker allowed Single_user_write" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Single_user_write);
  Alcotest.(check bool) "SU Worker allowed Machine_play" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Machine_play);
  Alcotest.(check bool) "SU Worker denied Admin_only" false
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Admin_only);
  Alcotest.(check bool) "SU Worker denied Single_user_admin_only" false
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Single_user_admin_only);
  Alcotest.(check bool) "SU Worker denied Single_user_token_admin_only" false
    (Rbac.is_allowed Rbac.single_user_local_worker
       Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "SU Worker denied Own_provider_manage" false
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Own_provider_manage);

  (* Single-user Optional-token Admin without token vs Token Admin *)
  Alcotest.(check bool) "SU Optional-token Admin denied Token_permission CanAdmin"
    false
    (Rbac.is_allowed su_optional_token_admin Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "SU Token Admin allowed Token_permission CanAdmin" true
    (Rbac.is_allowed su_token_admin Rbac.Single_user_token_admin_only);

  (* Single-user Player: allowed Machine_play ONLY, denied Workspace_read, Single_user_read, Admin_only *)
  Alcotest.(check bool) "SU Player allowed Machine_play" true
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Machine_play);
  Alcotest.(check bool) "SU Player denied Workspace_read" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Workspace_read);
  Alcotest.(check bool) "SU Player denied Single_user_read" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Single_user_read);
  Alcotest.(check bool) "SU Player denied Admin_only" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Admin_only)

let stream_name = function
  | Subscriptions.Stream_observer -> "observer"
  | Subscriptions.Stream_fleet -> "fleet"
  | Subscriptions.Stream_model_metrics -> "model_metrics"
  | Subscriptions.Stream_tool_metrics_series -> "tool_metrics_series"
  | Subscriptions.Stream_logs _ -> "logs"

let empty_tool_metrics_24h : Wire_infra.tool_metrics_24h =
  {
    calls = 0;
    failures = 0;
    failure_unclassified = 0;
    p50_ms = Observed.unreported;
    p95_ms = Observed.unreported;
    max_ms = Observed.unreported;
    failure_classes =
      {
        dependency_unavailable = 0;
        runtime_failure = 0;
        policy_rejection = 0;
        workflow_rejection = 0;
        operator_cancelled = 0;
      };
  }

let empty_sandboxes_snapshot ?(running = 0) () : Wire_infra.sandboxes_snapshot =
  {
    probe_state = Wire_infra.Probe_fresh 1_700_000_000.0;
    microvm_declared = running;
    microvm_running = running;
    microvm_sockets_present = running;
    microvm_shim_mismatch = 0;
    ssh_pools_count = 0;
    ssh_keepers_count = 0;
    ssh_unbound_keepers_count = 0;
    ssh_active_sessions = Observed.unreported;
    ssh_max_sessions = 0;
    docker_keepers_count = 0;
    microvm_guests = [];
    ssh_pools = [];
    ssh_unbound_keepers = [];
    docker_keepers = [];
    fleet_metrics_24h = empty_tool_metrics_24h;
    volume_gc_report = None;
    host_storage = None;
    unobserved_reasons = [];
  }

(* 3. Poller, loader, and SSE suppression across all workspaces and tabs *)
let test_poller_loader_and_sse_suppression () =
  let sessions =
    [
      ("Probing_health", Rbac.Probing_health);
      ("SU_auth_required", su_auth_required);
      ("SU_worker", Rbac.single_user_local_worker);
      ("SU_player", Rbac.single_user_local_player);
      ("MA_signed_out", ma_signed_out);
      ("MA_worker_pat", ma_human_worker_pat);
      ("MA_admin_pat", ma_human_admin_pat);
      ("MA_admin_session", ma_human_admin_session);
    ]
  in
  let assert_all_cmds_allowed label session cmds =
    let flat = Cmd.flatten cmds in
    List.iter
      (fun c ->
        if not (Rbac_policy.is_cmd_allowed session c) then
          Alcotest.failf "%s emitted disallowed command for session" label)
      flat
  in
  List.iter
    (fun (s_lbl, session) ->
      let m0 = Model.initial ~auth_session:session ~cols:140 ~rows:40 () in
      assert_all_cmds_allowed (s_lbl ^ "/bootstrap") session
        (View_fetches.bootstrap_fetches m0);
      List.iter
        (fun ws ->
          let m_ws = { m0 with nav = { m0.nav with workspace = ws } } in
          let plan = Subscriptions.plan m_ws in
          List.iter
            (fun sid ->
              Alcotest.(check bool)
                (Printf.sprintf "%s/%s stream allowed" s_lbl (stream_name sid))
                true
                (Rbac.is_allowed session
                   (Subscriptions.route_access_of_stream_id sid)))
            plan;
          if
            Rbac.is_multi_account session || not (Rbac.is_authenticated session)
          then
            Alcotest.(check int)
              (Printf.sprintf "%s zero SSE streams" s_lbl)
              0 (List.length plan);
          assert_all_cmds_allowed (s_lbl ^ "/ws") session
            (View_fetches.fetches_for_current_view m_ws))
        Nav.all_workspaces;
      List.iter
        (fun tab ->
          let m =
            {
              m0 with
              nav = { m0.nav with workspace = Nav.Work };
              work = { m0.work with active_tab = tab };
            }
          in
          assert_all_cmds_allowed (s_lbl ^ "/work_tab") session
            (View_fetches.fetches_for_current_view m))
        Nav.all_work_tabs;
      List.iter
        (fun tab ->
          let m =
            {
              m0 with
              nav = { m0.nav with workspace = Nav.Knowledge };
              knowledge = { m0.knowledge with active_tab = tab };
            }
          in
          assert_all_cmds_allowed (s_lbl ^ "/knowledge_tab") session
            (View_fetches.fetches_for_current_view m))
        Nav.all_knowledge_tabs;
      List.iter
        (fun tab ->
          let m =
            {
              m0 with
              nav = { m0.nav with workspace = Nav.Runtime };
              runtime = { m0.runtime with active_tab = tab };
            }
          in
          assert_all_cmds_allowed (s_lbl ^ "/runtime_tab") session
            (View_fetches.fetches_for_current_view m))
        Nav.all_runtime_tabs;
      List.iter
        (fun tab ->
          let m =
            {
              m0 with
              nav = { m0.nav with workspace = Nav.Infra };
              infra = { m0.infra with active_tab = tab };
            }
          in
          assert_all_cmds_allowed (s_lbl ^ "/infra_tab") session
            (View_fetches.fetches_for_current_view m))
        Nav.all_infra_tabs)
    sessions;

  (* Server Truth Check #1: GET /api/v1/keepers/oauth/attached-tools is Public_read
     in SU (allowed for SU Worker, 404 in MA) *)
  Alcotest.(check bool) "SU Worker allowed Get_oauth_attached_tools" true
    (Rbac_policy.can_fetch_get Rbac.single_user_local_worker
       (Cmd.Get_oauth_attached_tools { keeper = "alpha" }));
  Alcotest.(check bool) "MA Worker PAT denied Get_oauth_attached_tools (404 in MA)"
    false
    (Rbac_policy.can_fetch_get ma_human_worker_pat
       (Cmd.Get_oauth_attached_tools { keeper = "alpha" }));

  (* Server Truth Check #2: /api/v1/setup/accounts/login* allowed for MA Human
     Worker PAT (Manage_own_provider), denied for MA Service *)
  Alcotest.(check bool) "MA Worker PAT allowed Get_setup_login_status" true
    (Rbac_policy.can_fetch_get ma_human_worker_pat
       (Cmd.Get_setup_login_status { login_id = "l-1" }));
  Alcotest.(check bool) "MA Service denied Get_setup_login_status" false
    (Rbac_policy.can_fetch_get ma_service_worker
       (Cmd.Get_setup_login_status { login_id = "l-1" }));

  (* Server Truth Check #3: SU Worker on Infra_logs does NOT get Stream_logs *)
  let m_worker_logs =
    let m = Model.initial ~auth_session:Rbac.single_user_local_worker () in
    {
      m with
      nav = { m.nav with workspace = Nav.Infra };
      infra = { m.infra with active_tab = Nav.Infra_activity_logs };
    }
  in
  let worker_plan = Subscriptions.plan m_worker_logs in
  Alcotest.(check bool) "SU Worker plan excludes Stream_logs" false
    (List.exists
       (fun s ->
         Subscriptions.equal_stream_kind s
           (Subscriptions.Stream_logs { since_seq = None }))
       worker_plan);
  Alcotest.(check bool) "SU Worker plan still keeps persistent Stream_observer"
    true
    (List.exists
       (fun s -> Subscriptions.equal_stream_id s Subscriptions.Stream_observer)
       worker_plan);

  (* Check #4: Suppressed reads on Work_inbox for MA Worker PAT do NOT stick in Loading *)
  let m_ma = Model.initial ~auth_session:ma_human_worker_pat () in
  let m_work, cmds_work =
    Update.step ~now:t0 m_ma (Msg.Key_event (char_key "2"))
  in
  assert_all_cmds_allowed "MA_worker/jump_work" ma_human_worker_pat cmds_work;
  Alcotest.(check bool) "MA Worker inbox asks not stuck in Loading" false
    (Observed.is_loading m_work.work.asks);
  Alcotest.(check bool) "MA Worker tool_approvals not stuck in Loading" false
    (Observed.is_loading m_work.work.tool_approvals)

(* 4. Action, hotkey, modal, settings, palette, and slash gating *)
let test_action_hotkey_modal_palette_and_slash_gating () =
  let check_blocked label m msg =
    let next, cmds = Update.step ~now:t0 m msg in
    Alcotest.(check int) (label ^ " emits 0 cmds") 0
      (List.length (Cmd.flatten cmds));
    Alcotest.(check bool) (label ^ " shows denial toast") true
      (Option.is_some next.toast);
    next
  in
  let m_worker =
    Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140 ~rows:40
      ()
  in
  (* Ctrl+, Settings blocked for SU Worker *)
  let m_after_settings =
    check_blocked "SU Worker Ctrl+," m_worker (Msg.Key_event (ctrl_key ","))
  in
  Alcotest.(check bool) "Settings overlay stays closed" true
    (Option.is_none m_after_settings.nav.overlay);

  (* Restricted slash commands blocked for SU Worker *)
  List.iter
    (fun slash_text ->
      let m_typed =
        {
          m_worker with
          drafts =
            m_worker.drafts |> Drafts.set_focus true
            |> Drafts.insert_text slash_text;
        }
      in
      let enter : Keymap.Input.key_event =
        { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods }
      in
      ignore
        (check_blocked ("SU Worker slash " ^ slash_text) m_typed
           (Msg.Key_event enter)))
    [
      "/config";
      "/boot alpha";
      "/down alpha";
      "/gate";
      "/lane";
      "/skill";
      "/preset";
      "/addon";
      "/browser";
      "/exec";
    ];

  (* Navigation slash /infra still navigates cleanly with zero admin fetches *)
  let m_nav_infra, cmds_nav_infra =
    let m_draft =
      {
        m_worker with
        drafts =
          m_worker.drafts |> Drafts.set_focus true |> Drafts.insert_text "/infra";
      }
    in
    Update.step ~now:t0 m_draft
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "SU Worker /infra switches workspace to Infra" true
    (Nav.equal_workspace m_nav_infra.nav.workspace Nav.Infra);
  Alcotest.(check bool) "SU Worker /infra emits zero admin HTTP gets" true
    (List.for_all
       (Rbac_policy.is_cmd_allowed Rbac.single_user_local_worker)
       (Cmd.flatten cmds_nav_infra));

  (* Command palette hides Settings & Sandboxes & /config for SU Worker *)
  let worker_pal, _ = Update_nav.palette_entries_with_overflow m_worker in
  Alcotest.(check bool) "SU Worker palette hides Settings entries" false
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.section with Update_nav.Pal_sec_settings -> true | _ -> false)
       worker_pal);
  Alcotest.(check bool) "SU Worker palette hides Sandbox entries" false
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.section with Update_nav.Pal_sec_sandboxes -> true | _ -> false)
       worker_pal);
  let m_worker_cfg_pal =
    {
      m_worker with
      nav = { m_worker.nav with overlay = Some Nav.Palette };
      palette = { m_worker.palette with query = "config" };
    }
  in
  let worker_cfg_pal, _ =
    Update_nav.palette_entries_with_overflow m_worker_cfg_pal
  in
  Alcotest.(check bool) "SU Worker palette hides /config slash" false
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.action with
         | Update_nav.Pal_slash_spec sp -> String.equal sp.name "config"
         | _ -> false)
       worker_cfg_pal);

  (* Composer chat blocked in Multi-account mode *)
  let m_ma =
    let base =
      Model.initial ~auth_session:ma_human_worker_pat ~cols:140 ~rows:40 ()
    in
    {
      base with
      drafts =
        base.drafts
        |> Drafts.set_active_keeper "alpha"
        |> Drafts.set_focus true
        |> Drafts.insert_text "hello keeper";
    }
  in
  ignore
    (check_blocked "MA Worker chat submit" m_ma
       (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods }));

  (* Multi-account Admin PAT also blocked from Ctrl+, Settings *)
  let m_ma_pat =
    Model.initial ~auth_session:ma_human_admin_pat ~cols:140 ~rows:40 ()
  in
  let m_pat_after =
    check_blocked "MA Admin PAT Ctrl+," m_ma_pat (Msg.Key_event (ctrl_key ","))
  in
  Alcotest.(check bool) "MA Admin PAT Settings stays closed" true
    (Option.is_none m_pat_after.nav.overlay)

(* 5. Truthful chrome, badges, lock markers, footer/help filtering & locked screens *)
let test_chrome_footer_help_and_locked_screens () =
  let lock_glyph = Glyph.to_utf8 Glyph.Locked in

  (* Admin SU: badge LOCAL ADMIN, no lock glyph on top rail *)
  let m_admin =
    Model.initial ~auth_session:Rbac.single_user_local_admin ~lang:Say.Lang_en
      ~cols:140 ~rows:40 ()
  in
  let txt_admin = render_full_frame m_admin in
  Alcotest.(check bool) "Admin top rail shows LOCAL ADMIN" true
    (contains_ci ~needle:"LOCAL ADMIN" txt_admin);
  Alcotest.(check bool) "Admin top rail has no lock glyph" false
    (contains_ci ~needle:lock_glyph txt_admin);

  (* Worker SU on Infra: badge LOCAL WORKER, lock glyph on Infra, locked panel rendered,
     and footer omits dead Admin hotkeys *)
  let m_worker_infra =
    let m =
      Model.initial ~auth_session:Rbac.single_user_local_worker
        ~lang:Say.Lang_en ~cols:140 ~rows:40 ()
    in
    { m with nav = { m.nav with workspace = Nav.Infra } }
  in
  let txt_worker_infra = render_full_frame m_worker_infra in
  Alcotest.(check bool) "Worker top rail shows LOCAL WORKER" true
    (contains_ci ~needle:"LOCAL WORKER" txt_worker_infra);
  Alcotest.(check bool) "Worker top rail marks locked workspaces" true
    (contains_ci ~needle:lock_glyph txt_worker_infra);
  Alcotest.(check bool) "Worker Infra renders LOCKED panel" true
    (contains_ci ~needle:"LOCKED" txt_worker_infra);
  Alcotest.(check bool) "Worker Infra footer hides Settings hotkey" false
    (contains_ci ~needle:"Settings" txt_worker_infra);

  (* Multi-account Admin PAT on Keepers: badge MA ADMIN·PAT, locked screen *)
  let m_ma_pat_keepers =
    let m =
      Model.initial ~auth_session:ma_human_admin_pat ~lang:Say.Lang_en
        ~cols:140 ~rows:40 ()
    in
    { m with nav = { m.nav with workspace = Nav.Keepers } }
  in
  let txt_ma_pat = render_full_frame m_ma_pat_keepers in
  Alcotest.(check bool) "MA Admin PAT badge shown" true
    (contains_ci ~needle:"MA ADMIN·PAT" txt_ma_pat);
  Alcotest.(check bool) "MA Admin PAT Keepers renders LOCKED panel" true
    (contains_ci ~needle:"LOCKED" txt_ma_pat);

  (* Multi-account Admin PAT on Infra: explains PAT cannot access admin *)
  let m_ma_pat_infra =
    {
      m_ma_pat_keepers with
      nav = { m_ma_pat_keepers.nav with workspace = Nav.Infra };
    }
  in
  let txt_ma_pat_infra = render_full_frame m_ma_pat_infra in
  Alcotest.(check bool) "MA Admin PAT Infra explains PAT limitation" true
    (contains_ci ~needle:"Multi-account PATs cannot hold admin permissions"
       txt_ma_pat_infra);

  (* Fast approval strip suppressed for Worker even when pending approval exists *)
  let approval_item : Attention.entry =
    {
      id = "ta-1";
      kind =
        Health.Held_tool_approval
          { request_id = "ta-1"; keeper = "alpha"; tool = "shell" };
      title = "Approve shell";
      summary = "Needs admin";
      created_at_unix = Some 1_700_000_000.0;
      keeper = Some "alpha";
      payload =
        Attention.Payload_tool_approval
          {
            approval_id = "ta-1";
            tool_call_id = "tc-1";
            keeper = "alpha";
            tool = "shell";
            args_preview = "rm -rf";
            question = "Allow shell?";
            because = Some "high risk";
            asked_at = 1_700_000_000.0;
            timeout_sec = 300.0;
          };
    }
  in
  let attn = Attention.upsert_entry approval_item Attention.empty in
  let m_admin_attn = { m_admin with attention = attn } in
  let m_worker_attn =
    {
      (Model.initial ~auth_session:Rbac.single_user_local_worker
         ~lang:Say.Lang_en ~cols:140 ~rows:40 ())
      with
      attention = attn;
    }
  in
  Alcotest.(check bool) "Admin sees fast approval strip" true
    (Option.is_some (Model.fast_approval_strip_item m_admin_attn));
  Alcotest.(check bool) "Worker does NOT see fast approval strip" true
    (Option.is_none (Model.fast_approval_strip_item m_worker_attn));

  (* Help overlay omits Settings hotkey for Worker *)
  let m_worker_help =
    {
      m_worker_attn with
      nav = { m_worker_attn.nav with overlay = Some Nav.Help };
    }
  in
  let txt_help = render_full_frame m_worker_help in
  Alcotest.(check bool) "Worker Help overlay omits Ctrl+, Settings" false
    (contains_ci ~needle:"Ctrl+," txt_help);

  (* Single_user Player on Pulse renders LOCKED screen *)
  let m_player =
    Model.initial ~auth_session:Rbac.single_user_local_player ~lang:Say.Lang_en
      ~cols:140 ~rows:40 ()
  in
  let txt_player = render_full_frame m_player in
  Alcotest.(check bool) "Player Pulse renders LOCKED panel" true
    (contains_ci ~needle:"LOCKED" txt_player);

  (* Auth_gate overlay renders mode-aware token remediation *)
  let m_gate =
    let base =
      Model.initial ~auth_session:su_auth_required ~lang:Say.Lang_en ~cols:140
        ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with overlay = Some (Nav.System_gate Nav.Auth_gate) };
    }
  in
  let txt_gate = render_full_frame m_gate in
  Alcotest.(check bool) "Auth_gate displays MASC_TOKEN remediation" true
    (contains_ci ~needle:"MASC_TOKEN" txt_gate)

(* 6. 2-step bootstrap handshakes & in-place demotion / auth-loss cleanup *)
let test_bootstrap_and_inplace_demotion_cleanup () =
  (* A. Default Model.initial () starts fail-closed at Probing_health *)
  let m0 = Model.initial ~cols:140 ~rows:40 () in
  Alcotest.(check bool) "Model.initial defaults to Probing_health" true
    (Rbac.equal_auth_session m0.auth_session Rbac.Probing_health);
  let _, boot_cmds = Update.step ~now:t0 m0 Msg.Boot in
  let boot_http =
    List.filter
      (function
        | Cmd.Http_get _ | Cmd.Http_post _ | Cmd.Http_put _
        | Cmd.Http_delete _ | Cmd.Http_post_stream _ ->
            true
        | _ -> false)
      (Cmd.flatten boot_cmds)
  in
  Alcotest.(check bool) "Boot emits ONLY Get_health over HTTP" true
    (match boot_http with
    | [ Cmd.Http_get { req = Cmd.Get_health; _ } ] -> true
    | _ -> false);

  (* B. Single-user handshake: /health -> Probing_single_user + Get_dashboard_shell ONLY *)
  let m_su_probe, cmds_su_probe =
    Update.step ~now:t0 m0
      (Msg.Server_health_result
         { epoch = m0.epoch; result = Ok (sample_health ~mode:Rbac.Single_user ()) })
  in
  Alcotest.(check bool) "SU /health enters Probing_single_user" true
    (match m_su_probe.auth_session with
    | Rbac.Probing_single_user _ -> true
    | Rbac.Probing_health
    | Rbac.Probing_multi_account _
    | Rbac.Single_user_local _
    | Rbac.Single_user_auth_required _
    | Rbac.Multi_account_signed_out _
    | Rbac.Multi_account_signed_in _
    | Rbac.Auth_unavailable _ ->
        false);
  Alcotest.(check bool) "SU /health emits Get_dashboard_shell" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_dashboard_shell; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_su_probe));
  Alcotest.(check bool) "SU /health emits NO admin/data GETs while probing" true
    (List.for_all
       (Rbac_policy.is_cmd_allowed m_su_probe.auth_session)
       (Cmd.flatten cmds_su_probe));

  (* B1. Loopback 200 with enabled && require_token && not token_valid -> Auth_gate *)
  let m_su_gated, cmds_su_gated =
    Update.step ~now:t0 m_su_probe
      (Msg.Http_reply
         {
           epoch = m_su_probe.epoch;
           reply =
             Msg.Reply_dashboard_shell
               (Ok (sample_shell ~auth:su_auth_loopback_missing_token ()));
         })
  in
  Alcotest.(check bool) "Loopback !token_valid enters Auth_gate" true
    (Option.equal Nav.equal_overlay m_su_gated.nav.overlay
       (Some (Nav.System_gate Nav.Auth_gate)));
  Alcotest.(check bool) "Loopback !token_valid emits zero data GETs" false
    (List.exists
       (function Cmd.Http_get _ -> true | _ -> false)
       (Cmd.flatten cmds_su_gated));

  (* B2. Single-user shell omitting auth fails closed to Auth_unavailable *)
  let m_su_missing_auth, _ =
    Update.step ~now:t0 m_su_probe
      (Msg.Http_reply
         {
           epoch = m_su_probe.epoch;
           reply = Msg.Reply_dashboard_shell (Ok (sample_shell ()));
         })
  in
  Alcotest.(check bool) "Missing shell.auth fails closed (not Admin)" false
    (Rbac.can_admin m_su_missing_auth.auth_session);

  (* C. Multi-account handshake: /health -> Probing_multi_account + Get_auth_whoami ONLY *)
  let m_ma_probe, cmds_ma_probe =
    Update.step ~now:t0 m0
      (Msg.Server_health_result
         { epoch = m0.epoch; result = Ok (sample_health ~mode:Rbac.Multi_account ()) })
  in
  Alcotest.(check bool) "MA /health emits Get_auth_whoami" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_auth_whoami; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_ma_probe));
  (* MA whoami 401 -> Multi_account_signed_out + Auth_gate *)
  let m_ma_401, _ =
    Update.step ~now:t0 m_ma_probe
      (Msg.Http_reply
         {
           epoch = m_ma_probe.epoch;
           reply =
             Msg.Reply_auth_whoami
               (Error (Msg.Http_error { status = 401; body = "unauth"; api_error = None }));
         })
  in
  Alcotest.(check bool) "MA whoami 401 opens Auth_gate" true
    (Option.equal Nav.equal_overlay m_ma_401.nav.overlay
       (Some (Nav.System_gate Nav.Auth_gate)));
  (* MA whoami Ok (Admin PAT) -> signed in, zero SSE, zero Admin_only / SU-only GETs *)
  let whoami_ok : Wire_common.auth_whoami =
    {
      principal = { kind = Rbac.Human; id = "usr-1" };
      role = Rbac.Admin;
      binding = { kind = Rbac.Pat; id = "pat-1" };
    }
  in
  let m_ma_in, cmds_ma_in =
    Update.step ~now:t0 m_ma_probe
      (Msg.Http_reply
         { epoch = m_ma_probe.epoch; reply = Msg.Reply_auth_whoami (Ok whoami_ok) })
  in
  Alcotest.(check bool) "MA whoami Ok signs in as PAT Admin (can_admin=false)"
    true
    (Rbac.is_authenticated m_ma_in.auth_session
     && not (Rbac.can_admin m_ma_in.auth_session));
  Alcotest.(check int) "MA whoami Ok plans 0 SSE streams" 0
    (List.length (Subscriptions.plan m_ma_in));
  Alcotest.(check bool) "MA bootstrap cmds are all allowed for Admin PAT" true
    (List.for_all
       (Rbac_policy.is_cmd_allowed m_ma_in.auth_session)
       (Cmd.flatten cmds_ma_in));

  (* D. In-place Admin -> Worker demotion cleanup & stale-epoch reply drop *)
  let m_admin_dirty =
    let base =
      Model.initial ~auth_session:su_token_admin ~cols:140 ~rows:40 ()
    in
    let dummy_schema : Wire_config.config_schema =
      {
        target = Wire_config.Target_runtime;
        keeper = None;
        file_exists = true;
        file_sha256 = "sha-test";
        sections = [];
      }
    in
    let config =
      base.config
      |> Config_store.apply_schema ~observed_at:t0 dummy_schema
      |> Config_store.stage_patch ~full_key:"test.key"
           (Wire_config.Set_scalar
              { table = "test"; key = "key"; value = "val" })
    in
    let infra =
      {
        base.infra with
        sandboxes = Observed.value ~observed_at:t0 (empty_sandboxes_snapshot ());
      }
    in
    {
      base with
      nav =
        {
          base.nav with
          workspace = Nav.Infra;
          overlay = Some (Nav.Settings Nav.Settings_routing_failover);
          inspector = Some (Nav.Skill_inspector "sk-1");
        };
      config;
      infra;
      keeper_stop_armed = Some ("alpha", t0);
    }
  in
  let pre_demote_epoch = m_admin_dirty.epoch in
  (* 403 triggers throttled auth re-probe; second 403 within 5s is throttled *)
  let m_403, cmds_403 =
    Update.step ~now:t0 m_admin_dirty
      (Msg.Http_reply
         {
           epoch = pre_demote_epoch;
           reply =
             Msg.Reply_sandboxes
               (Error (Msg.Http_error { status = 403; body = "forbidden"; api_error = None }));
         })
  in
  Alcotest.(check bool) "403 emits Get_dashboard_shell re-probe" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_dashboard_shell; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_403));
  let _, cmds_403_throttled =
    Update.step ~now:t1 m_403
      (Msg.Http_reply
         {
           epoch = m_403.epoch;
           reply =
             Msg.Reply_sandboxes
               (Error (Msg.Http_error { status = 403; body = "forbidden"; api_error = None }));
         })
  in
  Alcotest.(check bool) "Second 403 within 5s is throttled (no loop)" false
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_dashboard_shell; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_403_throttled));
  (* After 5s cooldown expires (t6 = t0 + 6s), re-probe fires again *)
  let _, cmds_403_after_cd =
    Update.step ~now:t6 m_403
      (Msg.Http_reply
         {
           epoch = m_403.epoch;
           reply =
             Msg.Reply_sandboxes
               (Error (Msg.Http_error { status = 403; body = "forbidden"; api_error = None }));
         })
  in
  Alcotest.(check bool) "403 after 5s cooldown re-probes auth" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_dashboard_shell; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_403_after_cd));

  (* Deliver demoted Worker shell reply *)
  let m_demoted, _ =
    Update.step ~now:t1 m_403
      (Msg.Http_reply
         {
           epoch = m_403.epoch;
           reply = Msg.Reply_dashboard_shell (Ok (sample_shell ~auth:su_auth_worker ()));
         })
  in
  Alcotest.(check bool) "Demotion bumps epoch" true
    (not (Epoch.equal pre_demote_epoch m_demoted.epoch));
  Alcotest.(check bool) "Demotion closes Settings overlay" true
    (Option.is_none m_demoted.nav.overlay);
  Alcotest.(check bool) "Demotion closes Skill_inspector" true
    (Option.is_none m_demoted.nav.inspector);
  Alcotest.(check int) "Demotion clears Config_store dirty overrides" 0
    (Config_store.dirty_count m_demoted.config);
  Alcotest.(check bool) "Demotion purges Config_store schema" true
    (Option.is_none (Observed.to_option m_demoted.config.schema));
  Alcotest.(check bool) "Demotion purges Infra sandboxes cache" true
    (Option.is_none (Observed.to_option m_demoted.infra.sandboxes));
  Alcotest.(check bool) "Demotion disarms keeper_stop_armed" true
    (Option.is_none m_demoted.keeper_stop_armed);

  (* Stale pre-demotion HTTP reply MUST be dropped by epoch guard (cannot repopulate purged cache) *)
  let m_after_late, _ =
    Update.step ~now:t1 m_demoted
      (Msg.Http_reply
         {
           epoch = pre_demote_epoch;
           reply = Msg.Reply_sandboxes (Ok (empty_sandboxes_snapshot ~running:3 ()));
         })
  in
  Alcotest.(check bool) "Late pre-demotion reply dropped (sandboxes stay purged)"
    true
    (Option.is_none (Observed.to_option m_after_late.infra.sandboxes));

  (* E. Runtime SSE 401 enters Auth_gate, bumps epoch, and tears down streams *)
  let m_sse_401, cmds_sse_401 =
    Update.step ~now:t1 m_demoted
      (Msg.Sse_freshness
         {
           epoch = m_demoted.epoch;
           stream = Subscriptions.Stream_observer;
           freshness =
             Health.Disconnected
               { since_ns = t1; reason = Health.Http_status 401 };
         })
  in
  Alcotest.(check bool) "SSE 401 opens Auth_gate" true
    (Option.equal Nav.equal_overlay m_sse_401.nav.overlay
       (Some (Nav.System_gate Nav.Auth_gate)));
  Alcotest.(check bool) "SSE 401 bumps epoch" true
    (not (Epoch.equal m_demoted.epoch m_sse_401.epoch));
  Alcotest.(check bool) "SSE 401 syncs empty stream list" true
    (List.exists
       (function Cmd.Sync_streams { streams = []; _ } -> true | _ -> false)
       (Cmd.flatten cmds_sse_401));

  (* Verify SU auth_off bootstrap resolves to local admin *)
  let m_off, _ =
    Update.step ~now:t0 m_su_probe
      (Msg.Http_reply
         {
           epoch = m_su_probe.epoch;
           reply =
             Msg.Reply_dashboard_shell (Ok (sample_shell ~auth:su_auth_admin_off ()));
         })
  in
  Alcotest.(check bool) "SU auth_off bootstrap resolves to local admin" true
    (Rbac.can_admin m_off.auth_session)

let () =
  Alcotest.run "masc_tui_rbac"
    [
      ( "rbac_ssot"
      , [
          Alcotest.test_case "core parsers & single-user shell.auth projection"
            `Quick test_core_parsers_and_projection;
          Alcotest.test_case "exhaustive decision matrix (all sessions x all routes)"
            `Quick test_exhaustive_decision_matrix;
        ] );
      ( "gating"
      , [
          Alcotest.test_case "poller, loader, and SSE suppression" `Quick
            test_poller_loader_and_sse_suppression;
          Alcotest.test_case "action, hotkey, modal, palette, and slash gating"
            `Quick test_action_hotkey_modal_palette_and_slash_gating;
        ] );
      ( "chrome_and_lifecycle"
      , [
          Alcotest.test_case "truthful chrome, badges, footer/help, and locked screens"
            `Quick test_chrome_footer_help_and_locked_screens;
          Alcotest.test_case "2-step bootstrap handshakes & in-place demotion cleanup"
            `Quick test_bootstrap_and_inplace_demotion_cleanup;
        ] );
    ]
