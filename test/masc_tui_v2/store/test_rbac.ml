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
    ("Single_user_token_read", Rbac.Single_user_token_read);
    ("Single_user_write", Rbac.Single_user_write);
    ("Su_read_ma_admin", Rbac.Su_read_ma_admin);
    ("Bridged_token_admin", Rbac.Bridged_token_admin);
    ("Single_user_role_admin", Rbac.Single_user_role_admin);
    ("Single_user_token_admin_only", Rbac.Single_user_token_admin_only);
    ("Own_provider_manage", Rbac.Own_provider_manage);
    ("Multi_account_own_provider", Rbac.Multi_account_own_provider);
    ("Multi_account_own_keeper", Rbac.Multi_account_own_keeper);
    ("Keepers_workspace_access", Rbac.Keepers_workspace_access);
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

  (* Auth disabled local dev mode: server allows SU Public_read/CanReadState
     (including Su_read_ma_admin), while Token_permission routes (Bridged_token_admin,
     Single_user_token_admin_only, Single_user_token_read) return Token_auth_not_enabled. *)
  let auth_off =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:false ~require_token:false ~token_present:false
      ~token_valid:false ~effective_agent:(Some "dashboard")
      ~effective_role:(Some Rbac.Admin) ~effective_admin:(Some true)
      ~can_keeper_msg:true ~auth_error_code:None ~auth_error_detail:None
  in
  Alcotest.(check bool) "auth off allows Su_read_ma_admin (SU Public_read/CanReadState)"
    true (Rbac.is_allowed auth_off Rbac.Su_read_ma_admin);
  Alcotest.(check bool) "auth off allows Single_user_role_admin (Tool/Tool_actor admin_tool)"
    true (Rbac.is_allowed auth_off Rbac.Single_user_role_admin);
  Alcotest.(check bool) "auth off denies Bridged_token_admin with Token_auth_not_enabled"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide auth_off Rbac.Bridged_token_admin)
       (Rbac.Denied Rbac.Token_auth_not_enabled));
  Alcotest.(check bool) "auth off denies Single_user_token_read with Token_auth_not_enabled"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide auth_off Rbac.Single_user_token_read)
       (Rbac.Denied Rbac.Token_auth_not_enabled));
  Alcotest.(check bool) "auth off does not satisfy can_admin (Token_permission CanAdmin)"
    false (Rbac.can_admin auth_off);
  Alcotest.(check bool) "auth off does not satisfy Token_permission CanAdmin"
    false (Rbac.can_single_user_token_admin auth_off);

  (* Token-enabled admin satisfies Bridged_token_admin, Single_user_token_admin_only, and Single_user_token_read *)
  let tok_admin =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods
      ~enabled:true ~require_token:true ~token_present:true
      ~token_valid:true ~effective_agent:(Some "admin")
      ~effective_role:(Some Rbac.Admin) ~effective_admin:(Some true)
      ~can_keeper_msg:true ~auth_error_code:None ~auth_error_detail:None
  in
  Alcotest.(check bool) "token admin grants can_admin, token_admin, and token_read"
    true
    (Rbac.can_admin tok_admin
     && Rbac.can_single_user_token_admin tok_admin
     && Rbac.is_allowed tok_admin Rbac.Single_user_token_read);

  (* Optional token without valid token: Token_permission routes require require_token && token_valid *)
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
  Alcotest.(check bool) "optional-token without token cannot run Bridged_token_admin"
    false (Rbac.can_admin optional_no_token);
  Alcotest.(check bool) "optional-token without token cannot run Single_user_token_read"
    false (Rbac.is_allowed optional_no_token Rbac.Single_user_token_read);
  Alcotest.(check bool) "optional-token without token allows Su_read_ma_admin"
    true (Rbac.is_allowed optional_no_token Rbac.Su_read_ma_admin);

  (* Token worker stays Worker, gets Su_read_ma_admin & Single_user_token_read, never Admin *)
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
  Alcotest.(check bool) "worker gets Su_read_ma_admin" true
    (Rbac.is_allowed worker_sess Rbac.Su_read_ma_admin);
  Alcotest.(check bool) "worker gets Single_user_token_read" true
    (Rbac.is_allowed worker_sess Rbac.Single_user_token_read);
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
        | Rbac.Single_user_token_read
        | Rbac.Single_user_write
        | Rbac.Su_read_ma_admin
        | Rbac.Bridged_token_admin
        | Rbac.Single_user_role_admin
        | Rbac.Single_user_token_admin_only
        | Rbac.Own_provider_manage
        | Rbac.Multi_account_own_provider
        | Rbac.Multi_account_own_keeper
        | Rbac.Keepers_workspace_access
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
        | Rbac.Single_user_token_read
        | Rbac.Single_user_write
        | Rbac.Su_read_ma_admin
        | Rbac.Bridged_token_admin
        | Rbac.Single_user_role_admin
        | Rbac.Single_user_token_admin_only
        | Rbac.Own_provider_manage
        | Rbac.Multi_account_own_provider
        | Rbac.Multi_account_own_keeper
        | Rbac.Keepers_workspace_access
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
        | Rbac.Single_user_token_read
        | Rbac.Single_user_write
        | Rbac.Su_read_ma_admin
        | Rbac.Bridged_token_admin
        | Rbac.Single_user_role_admin
        | Rbac.Single_user_token_admin_only
        | Rbac.Own_provider_manage
        | Rbac.Multi_account_own_provider
        | Rbac.Multi_account_own_keeper
        | Rbac.Keepers_workspace_access
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
            | Rbac.Single_user_token_read
            | Rbac.Single_user_write
            | Rbac.Su_read_ma_admin
            | Rbac.Bridged_token_admin
            | Rbac.Single_user_role_admin
            | Rbac.Single_user_token_admin_only
            | Rbac.Own_provider_manage
            | Rbac.Multi_account_own_provider
            | Rbac.Multi_account_own_keeper
            | Rbac.Keepers_workspace_access
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

  (* Multi-account Admin PAT: NEVER gets Bridged_token_admin or Su_read_ma_admin (Pat_cannot_admin), NEVER gets SU-only *)
  Alcotest.(check bool) "MA Admin PAT denied Bridged_token_admin with Pat_cannot_admin"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_human_admin_pat Rbac.Bridged_token_admin)
       (Rbac.Denied Rbac.Pat_cannot_admin));
  Alcotest.(check bool) "MA Admin PAT denied Su_read_ma_admin with Pat_cannot_admin"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_human_admin_pat Rbac.Su_read_ma_admin)
       (Rbac.Denied Rbac.Pat_cannot_admin));
  Alcotest.(check bool) "MA Admin PAT allowed Workspace_read" true
    (Rbac.is_allowed ma_human_admin_pat Rbac.Workspace_read);
  Alcotest.(check bool) "MA Admin PAT allowed Own_provider_manage" true
    (Rbac.is_allowed ma_human_admin_pat Rbac.Own_provider_manage);
  Alcotest.(check bool) "MA Admin PAT denied Single_user_read" false
    (Rbac.is_allowed ma_human_admin_pat Rbac.Single_user_read);
  Alcotest.(check bool) "MA Admin PAT denied Single_user_token_read" false
    (Rbac.is_allowed ma_human_admin_pat Rbac.Single_user_token_read);

  (* Multi-account Admin Session: gets Bridged_token_admin + Su_read_ma_admin + Workspace_read + Own_provider_manage, NO SU-only *)
  Alcotest.(check bool) "MA Admin Session allowed Bridged_token_admin" true
    (Rbac.is_allowed ma_human_admin_session Rbac.Bridged_token_admin);
  Alcotest.(check bool) "MA Admin Session allowed Su_read_ma_admin" true
    (Rbac.is_allowed ma_human_admin_session Rbac.Su_read_ma_admin);
  Alcotest.(check bool) "MA Admin Session denied Single_user_token_admin_only"
    false
    (Rbac.is_allowed ma_human_admin_session Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "MA Admin Session denied Single_user_role_admin"
    false
    (Rbac.is_allowed ma_human_admin_session Rbac.Single_user_role_admin);
  Alcotest.(check bool) "MA Admin Session denied Single_user_token_read" false
    (Rbac.is_allowed ma_human_admin_session Rbac.Single_user_token_read);

  (* Multi-account Worker PAT: Workspace_read + Own_provider_manage + world/keeper memory diff, denied MA admin & SU *)
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
  Alcotest.(check bool) "MA Worker PAT denied Bridged_token_admin" false
    (Rbac.is_allowed ma_human_worker_pat Rbac.Bridged_token_admin);
  Alcotest.(check bool) "MA Worker PAT denied Su_read_ma_admin" false
    (Rbac.is_allowed ma_human_worker_pat Rbac.Su_read_ma_admin);

  (* Multi-account Service Worker: denied Own_provider_manage & Multi_account_own_keeper *)
  Alcotest.(check bool) "MA Service Worker denied Own_provider_manage" true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_service_worker Rbac.Own_provider_manage)
       (Rbac.Denied Rbac.Service_cannot_manage_own_provider));
  Alcotest.(check bool) "MA Service Worker denied Multi_account_own_keeper" true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_service_worker Rbac.Multi_account_own_keeper)
       (Rbac.Denied Rbac.Service_cannot_manage_own_provider));
  Alcotest.(check bool) "MA Service Worker denied Keepers_workspace_access" false
    (Rbac.is_allowed ma_service_worker Rbac.Keepers_workspace_access);
  Alcotest.(check bool) "MA Human Admin/Worker PAT allowed Multi_account_own_keeper & Keepers_workspace_access"
    true
    (Rbac.is_allowed ma_human_admin_session Rbac.Multi_account_own_keeper
     && Rbac.is_allowed ma_human_admin_pat Rbac.Multi_account_own_keeper
     && Rbac.is_allowed ma_human_worker_pat Rbac.Multi_account_own_keeper
     && Rbac.is_allowed ma_human_worker_pat Rbac.Keepers_workspace_access);
  Alcotest.(check bool) "SU Token Admin denied Multi_account_own_keeper, allowed Keepers_workspace_access"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide su_token_admin Rbac.Multi_account_own_keeper)
       (Rbac.Denied Rbac.Multi_account_only_in_single_user)
     && Rbac.is_allowed su_token_admin Rbac.Keepers_workspace_access);
  Alcotest.(check bool) "MA Service Worker denied keeper-scoped memory diff"
    false
    (Rbac.is_allowed ma_service_worker
       (Rbac.Memory_diff_read { keeper_scoped = true }));

  (* Single-user Worker: allowed SU read/token_read/write/Su_read_ma_admin, denied Bridged_token_admin / Token_admin / Own_provider_manage *)
  Alcotest.(check bool) "SU Worker allowed Single_user_read" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Single_user_read);
  Alcotest.(check bool) "SU Worker allowed Single_user_token_read" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Single_user_token_read);
  Alcotest.(check bool) "SU Worker allowed Su_read_ma_admin" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Su_read_ma_admin);
  Alcotest.(check bool) "SU Worker allowed Single_user_write" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Single_user_write);
  Alcotest.(check bool) "SU Worker allowed Machine_play" true
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Machine_play);
  Alcotest.(check bool) "SU Worker denied Bridged_token_admin" false
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Bridged_token_admin);
  Alcotest.(check bool) "SU Worker denied Single_user_role_admin (Requires_admin)"
    true
    (Rbac.equal_access_verdict
       (Rbac.decide Rbac.single_user_local_worker Rbac.Single_user_role_admin)
       (Rbac.Denied Rbac.Requires_admin));
  Alcotest.(check bool) "SU Worker denied Single_user_token_admin_only" false
    (Rbac.is_allowed Rbac.single_user_local_worker
       Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "SU Worker denied Own_provider_manage" false
    (Rbac.is_allowed Rbac.single_user_local_worker Rbac.Own_provider_manage);

  (* Single-user Optional-token Admin without token vs Token Admin *)
  Alcotest.(check bool) "SU Optional-token Admin denied Token_permission CanAdmin"
    false
    (Rbac.is_allowed su_optional_token_admin Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "SU Optional-token Admin denied Bridged_token_admin"
    false
    (Rbac.is_allowed su_optional_token_admin Rbac.Bridged_token_admin);
  Alcotest.(check bool) "SU Optional-token Admin denied Single_user_token_read"
    false
    (Rbac.is_allowed su_optional_token_admin Rbac.Single_user_token_read);
  Alcotest.(check bool) "SU Optional-token Admin allowed Su_read_ma_admin"
    true
    (Rbac.is_allowed su_optional_token_admin Rbac.Su_read_ma_admin);
  Alcotest.(check bool) "SU Token Admin allowed Token_permission CanAdmin" true
    (Rbac.is_allowed su_token_admin Rbac.Single_user_token_admin_only);
  Alcotest.(check bool) "SU Token Admin allowed Bridged_token_admin" true
    (Rbac.is_allowed su_token_admin Rbac.Bridged_token_admin);

  (* Single-user Player: allowed Machine_play ONLY, denied Workspace_read, Single_user_read, Su_read_ma_admin, Bridged_token_admin *)
  Alcotest.(check bool) "SU Player allowed Machine_play" true
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Machine_play);
  Alcotest.(check bool) "SU Player denied Workspace_read" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Workspace_read);
  Alcotest.(check bool) "SU Player denied Single_user_read" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Single_user_read);
  Alcotest.(check bool) "SU Player denied Single_user_token_read" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Single_user_token_read);
  Alcotest.(check bool) "SU Player denied Su_read_ma_admin" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Su_read_ma_admin);
  Alcotest.(check bool) "SU Player denied Bridged_token_admin" false
    (Rbac.is_allowed Rbac.single_user_local_player Rbac.Bridged_token_admin)

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

  (* Server Truth Check #3: GET /api/v1/dashboard/logs/stream is Public_read in SU
     (allowed for SU Worker), and 404 in MA (0 SSE streams even for MA Admin Session). *)
  let m_worker_logs =
    let m = Model.initial ~auth_session:Rbac.single_user_local_worker () in
    {
      m with
      nav = { m.nav with workspace = Nav.Infra };
      infra = { m.infra with active_tab = Nav.Infra_activity_logs };
    }
  in
  let worker_plan = Subscriptions.plan m_worker_logs in
  Alcotest.(check bool) "SU Worker plan includes Stream_logs (Public_read in SU)"
    true
    (List.exists
       (fun s ->
         Subscriptions.equal_stream_kind s
           (Subscriptions.Stream_logs { since_seq = None }))
       worker_plan);
  Alcotest.(check bool) "SU Worker plan keeps persistent Stream_observer"
    true
    (List.exists
       (fun s -> Subscriptions.equal_stream_id s Subscriptions.Stream_observer)
       worker_plan);
  let m_ma_admin_logs =
    let m = Model.initial ~auth_session:ma_human_admin_session () in
    {
      m with
      nav = { m.nav with workspace = Nav.Infra };
      infra = { m.infra with active_tab = Nav.Infra_activity_logs };
    }
  in
  Alcotest.(check int) "MA Admin Session plan has 0 SSE streams (no Stream_logs)"
    0 (List.length (Subscriptions.plan m_ma_admin_logs));

  (* Server Truth Check #4: Exact SU Worker / SU Auth-off / MA route classifications *)
  let su_auth_off_sess =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods ~enabled:false
      ~require_token:false ~token_present:false ~token_valid:false
      ~effective_agent:(Some "local") ~effective_role:(Some Rbac.Admin)
      ~effective_admin:(Some true) ~can_keeper_msg:true ~auth_error_code:None
      ~auth_error_detail:None
  in
  (* Su_read_ma_admin routes: SU Worker & SU Auth-off allowed; MA Admin Session allowed; MA Admin PAT denied *)
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("SU Auth-off allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get su_auth_off_sess req);
      Alcotest.(check bool) ("MA Admin Session allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get ma_human_admin_session req);
      Alcotest.(check bool) ("MA Admin PAT denied " ^ lbl) false
        (Rbac_policy.can_fetch_get ma_human_admin_pat req))
    [
      ("Get_sandboxes", Cmd.Get_sandboxes);
      ("Get_system_logs", Cmd.Get_system_logs { limit = Some 50; level = None });
    ];
  (* Bridged_token_admin routes: SU Worker denied; SU Auth-off denied Token_auth_not_enabled; MA Admin Session allowed *)
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker denied " ^ lbl) false
        (Rbac_policy.can_fetch_get Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("SU Auth-off denied Token_auth_not_enabled " ^ lbl)
        true
        (Rbac.equal_access_verdict
           (Rbac_policy.decide_get su_auth_off_sess req)
           (Rbac.Denied Rbac.Token_auth_not_enabled));
      Alcotest.(check bool) ("MA Admin Session allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get ma_human_admin_session req);
      Alcotest.(check bool) ("MA Admin PAT denied " ^ lbl) false
        (Rbac_policy.can_fetch_get ma_human_admin_pat req))
    [
      ("Get_config_schema", Cmd.Get_config_schema Wire_config.Target_runtime);
      ("Get_standalone_lanes", Cmd.Get_standalone_lanes);
      ("Get_exact_lane_runs", Cmd.Get_exact_lane_runs { lane = None; limit = Some 20 });
      ("Get_exact_lane_run_detail", Cmd.Get_exact_lane_run_detail { run_id = "r1" });
    ];
  let sample_wiki_put =
    Cmd.Put_wiki_page
      {
        page = "index";
        request =
          {
            Wire_knowledge.expected_revision = Some 1;
            expected_sha256 = Some "abc";
            title = "Index";
            summary = "Summary";
            source = Wire_knowledge.Source_direct_experience;
            tags = [];
            body = "hi";
            note = "";
          };
      }
  in
  Alcotest.(check bool) "SU Auth-off denied Put_wiki_page (Token_auth_not_enabled)"
    true
    (Rbac.equal_access_verdict
       (Rbac_policy.decide_put su_auth_off_sess sample_wiki_put)
       (Rbac.Denied Rbac.Token_auth_not_enabled));
  Alcotest.(check bool) "MA Admin Session allowed Put_wiki_page" true
    (Rbac_policy.can_put ma_human_admin_session sample_wiki_put);

  (* 24 SU Worker-allowed read routes + Workspace/Git/Browser/Addon/Presets/Memory *)
  let ws_scope = Wire_infra.Ws_project in
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("MA Admin Session denied SU-only " ^ lbl) false
        (Rbac_policy.can_fetch_get ma_human_admin_session req))
    [
      ("Get_repositories", Cmd.Get_repositories);
      ("Get_repository_pulls", Cmd.Get_repository_pulls);
      ("Get_repository_detail", Cmd.Get_repository_detail { repo_id = "r1" });
      ("Get_workspace_children", Cmd.Get_workspace_children { scope = ws_scope; dir = "" });
      ("Get_workspace_files", Cmd.Get_workspace_files { scope = ws_scope });
      ("Get_workspace_search", Cmd.Get_workspace_search { scope = ws_scope; query = "x" });
      ("Get_workspace_file", Cmd.Get_workspace_file { scope = ws_scope; path = "README.md" });
      ("Get_git_branches", Cmd.Get_git_branches { scope = ws_scope });
      ("Get_git_worktrees", Cmd.Get_git_worktrees { scope = ws_scope });
      ("Get_git_status", Cmd.Get_git_status { scope = ws_scope });
      ("Get_git_blame", Cmd.Get_git_blame { scope = ws_scope; path = "README.md" });
      ("Get_git_log", Cmd.Get_git_log { scope = ws_scope; path = "README.md" });
      ("Get_git_diff", Cmd.Get_git_diff { scope = ws_scope; path = "README.md" });
      ("Get_addon_package_catalog", Cmd.Get_addon_package_catalog { directory = None });
      ("Get_addon_package_preview", Cmd.Get_addon_package_preview { manifest_path = "p1" });
      ("Get_lane_addon_slice", Cmd.Get_lane_addon_slice { run_id = None; lane_id = None });
      ( "Get_lane_addon_action_status",
        Cmd.Get_lane_addon_action_status { instance_id = "inst-1"; request_id = "req-1" } );
      ("Get_presets", Cmd.Get_presets);
      ("Get_preset_show", Cmd.Get_preset_show { name = "default" });
      ("Get_runtime_params", Cmd.Get_runtime_params);
      ("Get_workspace_memory_ledger", Cmd.Get_workspace_memory_ledger);
      ("Get_workspace_memory_context", Cmd.Get_workspace_memory_context);
    ];
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker allowed " ^ lbl) true
        (Rbac_policy.can_post Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("MA Admin Session denied SU-only " ^ lbl) false
        (Rbac_policy.can_post ma_human_admin_session req))
    [
      ("Post_browser_tabs", Cmd.Post_browser_tabs { client_id = "c1" });
      ("Post_browser_scene", Cmd.Post_browser_scene { client_id = "c1"; tab_id = 1; view = `Content });
      ("Post_browser_screenshot", Cmd.Post_browser_screenshot { client_id = "c1"; tab_id = 1 });
    ];
  Alcotest.(check bool) "SU Worker still denied Get_repository_activity" false
    (Rbac_policy.can_fetch_get Rbac.single_user_local_worker
       (Cmd.Get_repository_activity { repo_id = "r1" }));
  Alcotest.(check bool) "SU Worker allowed Nav.Infra_repos_changes & Infra_code & File_inspector"
    true
    (Rbac.is_allowed Rbac.single_user_local_worker
       (Rbac_policy.route_access_of_infra_tab Nav.Infra_repos_changes)
     && Rbac.is_allowed Rbac.single_user_local_worker
          (Rbac_policy.route_access_of_infra_tab Nav.Infra_code)
     && Rbac.is_allowed Rbac.single_user_local_worker
          (Rbac_policy.route_access_of_inspector
             (Nav.File_inspector { keeper = "alpha"; path = "a.ml"; line = 1 })));
  Alcotest.(check bool) "SU Worker allowed /addon slice" true
    (match
       Rbac_policy.decide_slash_parsed Rbac.single_user_local_worker
         (Slash.Addon (Slash.Addon_slice { run_id = None; lane_id = None }))
     with
    | Rbac.Allowed -> true
    | Rbac.Denied _ -> false);

  (* P1-3: Reclassified Token_permission SU routes *)
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker denied " ^ lbl) false
        (Rbac_policy.can_fetch_get Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("SU Auth-off denied " ^ lbl) false
        (Rbac_policy.can_fetch_get su_auth_off_sess req);
      Alcotest.(check bool) ("SU Token Admin allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get su_token_admin req))
    [
      ("Get_artifacts", Cmd.Get_artifacts { generation = 0 });
      ("Get_artifact_checks", Cmd.Get_artifact_checks);
    ];
  Alcotest.(check bool) "SU Worker denied Post_tui_preference" false
    (Rbac_policy.can_post Rbac.single_user_local_worker
       (Cmd.Post_tui_preference (Wire_config.Pref_theme (Some "dark"))));
  Alcotest.(check bool) "SU Token Admin allowed Post_tui_preference" true
    (Rbac_policy.can_post su_token_admin
       (Cmd.Post_tui_preference (Wire_config.Pref_theme (Some "dark"))));
  Alcotest.(check bool) "SU Worker denied Nav.Knowledge_artifacts" false
    (match
       Rbac_policy.decide_knowledge_tab Rbac.single_user_local_worker
         Nav.Knowledge_artifacts
     with
    | Rbac.Allowed -> true
    | Rbac.Denied _ -> false);
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker (token valid) allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("SU Auth-off denied Token_auth_not_enabled " ^ lbl)
        true
        (Rbac.equal_access_verdict
           (Rbac_policy.decide_get su_auth_off_sess req)
           (Rbac.Denied Rbac.Token_auth_not_enabled));
      Alcotest.(check bool) ("SU Player denied " ^ lbl) false
        (Rbac_policy.can_fetch_get Rbac.single_user_local_player req))
    [
      ("Get_tui_preferences", Cmd.Get_tui_preferences);
      ("Get_keeper_sandbox_logs", Cmd.Get_keeper_sandbox_logs { keeper = "alpha"; tail = Some 50 });
      ("Get_efficiency", Cmd.Get_efficiency { month = None });
      ("Get_keeper_turn_records", Cmd.Get_keeper_turn_records { keeper = "alpha"; limit = 20 });
      ( "Get_keeper_context_turn_records",
        Cmd.Get_keeper_context_turn_records
          { keeper = "alpha"; limit = Some 20; turn_ref = None } );
      ("Get_keeper_metrics", Cmd.Get_keeper_metrics { keeper = "alpha" });
      ( "Get_keeper_cache_outcome",
        Cmd.Get_keeper_cache_outcome { keeper = "alpha"; turn_ref = "t-1" } );
      ( "Get_keeper_memory_os_internals",
        Cmd.Get_keeper_memory_os_internals { keeper = "alpha" } );
    ];

  (* #28 P1-1: Token_permission CanAdmin keeper GET routes *)
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker denied " ^ lbl) false
        (Rbac_policy.can_fetch_get Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("SU Auth-off denied Token_auth_not_enabled " ^ lbl)
        true
        (Rbac.equal_access_verdict
           (Rbac_policy.decide_get su_auth_off_sess req)
           (Rbac.Denied Rbac.Token_auth_not_enabled));
      Alcotest.(check bool) ("SU Token Admin allowed " ^ lbl) true
        (Rbac_policy.can_fetch_get su_token_admin req))
    [
      ("Get_keeper_memory_activity", Cmd.Get_keeper_memory_activity { keeper = "alpha"; limit = 20 });
      ( "Get_chat_operation_events",
        Cmd.Get_chat_operation_events
          { keeper = "alpha"; operation_id = "op-1"; from = Wire_chat_journal.From_start } );
      ("Get_keeper_next_request", Cmd.Get_keeper_next_request { keeper = "alpha" });
    ];

  (* #28 P1-2: Worker-allowed Tool/Tool_actor routes (CanReadState / CanBroadcast / mutating_tool) *)
  Alcotest.(check bool) "SU Worker allowed Get_lane_addon_declaration" true
    (Rbac_policy.can_fetch_get Rbac.single_user_local_worker
       (Cmd.Get_lane_addon_declaration { source_path = "a.toml" }));
  Alcotest.(check bool) "MA Admin Session denied Get_lane_addon_declaration" false
    (Rbac_policy.can_fetch_get ma_human_admin_session
       (Cmd.Get_lane_addon_declaration { source_path = "a.toml" }));
  Alcotest.(check bool) "SU Worker allowed /addon decl-read & write subcommands"
    true
    (List.for_all
       (fun p ->
         match Rbac_policy.decide_slash_parsed Rbac.single_user_local_worker p with
         | Rbac.Allowed -> true
         | Rbac.Denied _ -> false)
       [
         Slash.Addon (Slash.Addon_decl_read "a.toml");
         Slash.Addon (Slash.Addon_decl_new "b.toml");
         Slash.Addon (Slash.Addon_attach { manifest_path = "m"; run_id = "r"; binding_json = None });
         Slash.Addon (Slash.Addon_detach "inst-1");
         Slash.Addon (Slash.Addon_observe "inst-1");
         Slash.Addon (Slash.Addon_act { instance_id = "inst-1"; action_json = None });
         Slash.Addon (Slash.Addon_evidence { instance_id = "inst-1"; row_ids = []; keeper_name = None });
       ]);
  let sample_fusion : Wire_runtime.fusion_launch_request =
    { prompt = "check"; preset = None; topology = None; web_tools = false }
  in
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Worker allowed " ^ lbl) true
        (Rbac_policy.can_post Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("MA Admin Session denied SU-only " ^ lbl) false
        (Rbac_policy.can_post ma_human_admin_session req))
    [
      ("Post_fusion_launch", Cmd.Post_fusion_launch { keeper = "alpha"; request = sample_fusion });
      ( "Post_keeper_turn_interrupt",
        Cmd.Post_keeper_turn_interrupt { keeper = "alpha"; target = `Operation_id "op-1" } );
      ( "Post_connector_bind",
        Cmd.Post_connector_bind { connector = "discord"; channel_id = "c1"; keeper_name = "alpha" } );
      ( "Post_connector_unbind",
        Cmd.Post_connector_unbind { connector = "discord"; channel_id = "c1"; keeper_name = Some "alpha" } );
      ( "Post_lane_addon_attach",
        Cmd.Post_lane_addon_attach
          { manifest_path = "m"; run_id = "r"; binding = `Assoc []; from_modal = false } );
      ("Post_lane_addon_detach", Cmd.Post_lane_addon_detach { instance_id = "inst-1" });
      ( "Post_lane_addon_action",
        Cmd.Post_lane_addon_action
          { instance_id = "inst-1"; expected_incarnation = "i"; request_id = "r"; action = `Assoc [] } );
      ( "Post_lane_addon_declaration_save",
        Cmd.Post_lane_addon_declaration_save
          { mode = `Create; file_name = "a.toml"; source_text = ""; expected_source_revision = None } );
      ("Post_lane_addon_observe", Cmd.Post_lane_addon_observe { instance_id = "inst-1" });
      ( "Post_lane_addon_evidence",
        Cmd.Post_lane_addon_evidence
          { instance_id = "inst-1"; row_ids = []; keeper_name = None; broadcast = false; request_id = None } );
      ( "Post_lane_addon_act",
        Cmd.Post_lane_addon_act
          { instance_id = "inst-1"; expected_incarnation = "i"; request_id = "r"; action = `Assoc [] } );
    ];
  Alcotest.(check bool) "SU Worker allowed Fusion_launch_form, Connector_form, Addon_* modals"
    true
    (List.for_all
       (Rbac_policy.can_access_inline_action Rbac.single_user_local_worker)
       [
         Nav.Fusion_launch_form;
         Nav.Connector_form;
         Nav.Addon_attach_form;
         Nav.Addon_detach_confirm { instance_id = "i"; title = "t" };
         Nav.Addon_invoke_action { instance_id = "i"; action_names = [] };
         Nav.Addon_decl_form { file_name = "a.toml"; mode = `Create; expected_source_revision = None };
         Nav.Addon_act_form { instance_id = "i"; expected_incarnation = "e" };
       ]);

  (* #28 P2-3: Single_user_role_admin allows SU auth_enabled=false Admin while denying SU Worker & MA *)
  List.iter
    (fun (lbl, req) ->
      Alcotest.(check bool) ("SU Auth-off Admin allowed " ^ lbl) true
        (Rbac_policy.can_post su_auth_off_sess req);
      Alcotest.(check bool) ("SU Token Admin allowed " ^ lbl) true
        (Rbac_policy.can_post su_token_admin req);
      Alcotest.(check bool) ("SU Worker denied " ^ lbl) false
        (Rbac_policy.can_post Rbac.single_user_local_worker req);
      Alcotest.(check bool) ("MA Admin Session denied " ^ lbl) false
        (Rbac_policy.can_post ma_human_admin_session req))
    [
      ("Post_ask_answer", Cmd.Post_ask_answer { keeper = "alpha"; ask_id = "a1"; answers = [] });
      ( "Post_tool_approval",
        Cmd.Post_tool_approval
          {
            keeper = "alpha";
            tool_call_id = "tc1";
            approval_id = "ap1";
            decision = Wire_work.Tool_approve;
            expected_workspace = None;
          } );
      ( "Post_keeper_tool_approval_mode",
        Cmd.Post_keeper_tool_approval_mode
          { keeper = "alpha"; mode = Wire_work.Approval_auto } );
      ( "Post_lane_addon_ask_answer",
        Cmd.Post_lane_addon_ask_answer
          { declaration_id = "d1"; ask_id = "a1"; answers = [] } );
      ("Post_lane_addon_retain", Cmd.Post_lane_addon_retain { instance_id = "inst-1" });
      ("Post_prompt_override", Cmd.Post_prompt_override { key = "k"; value = Some "v" });
      ("Post_runtime_param_set", Cmd.Post_runtime_param_set { param_key = "k"; value = `String "v" });
      ("Post_runtime_param_clear", Cmd.Post_runtime_param_clear { param_key = "k" });
    ];
  Alcotest.(check bool) "SU Auth-off Admin STILL denied Post_lane_addon_operator (Token_auth_not_enabled)"
    true
    (Rbac.equal_access_verdict
       (Rbac_policy.decide_post su_auth_off_sess
          (Cmd.Post_lane_addon_operator
             {
               instance_id = "inst-1";
               expected_incarnation = "e";
               mode = Wire_runtime.Operator_describe;
             }))
       (Rbac.Denied Rbac.Token_auth_not_enabled));
  Alcotest.(check bool) "SU Auth-off Admin allowed Ask_answer overlay & prompt/param forms"
    true
    (Rbac_policy.can_access_overlay su_auth_off_sess Nav.Ask_answer
     && Rbac_policy.can_access_inline_action su_auth_off_sess
          (Nav.Prompt_override_form { key = "k" })
     && Rbac_policy.can_access_inline_action su_auth_off_sess
          (Nav.Runtime_param_set_form { param_key = "k" }));
  Alcotest.(check bool) "POST /api/v1/voice/transcribe (Start_ptt) requires Single_user_token_admin_only"
    true
    (Rbac_policy.is_cmd_allowed su_token_admin
       (Cmd.Voice_cmd (Cmd.Start_ptt { device = None }))
     && not
          (Rbac_policy.is_cmd_allowed Rbac.single_user_local_worker
             (Cmd.Voice_cmd (Cmd.Start_ptt { device = None })))
     && not
          (Rbac_policy.is_cmd_allowed su_auth_off_sess
             (Cmd.Voice_cmd (Cmd.Start_ptt { device = None }))));

  (* Check #5: Suppressed reads on Work_inbox for MA Worker PAT do NOT stick in Loading *)
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
      "/preset restore prod";
      "/addon operator inst-1";
      "/browser";
      "/voice";
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

  (* Command palette hides Settings & /config for SU Worker; MA Worker PAT hides Sandbox entries *)
  let worker_pal, _ = Update_nav.palette_entries_with_overflow m_worker in
  Alcotest.(check bool) "SU Worker palette hides Settings entries" false
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.section with Update_nav.Pal_sec_settings -> true | _ -> false)
       worker_pal);
  let m_ma_worker_sb =
    let base =
      Model.initial ~auth_session:ma_human_worker_pat ~cols:140 ~rows:40 ()
    in
    {
      base with
      infra =
        {
          base.infra with
          sandboxes = Observed.value ~observed_at:t0 (empty_sandboxes_snapshot ~running:1 ());
        };
    }
  in
  let ma_worker_pal, _ = Update_nav.palette_entries_with_overflow m_ma_worker_sb in
  Alcotest.(check bool) "MA Worker PAT palette hides Sandbox entries" false
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.section with Update_nav.Pal_sec_sandboxes -> true | _ -> false)
       ma_worker_pal);
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
    (Option.is_none m_pat_after.nav.overlay);

  (* P1-4: Single_user_local with can_keeper_msg = false blocks Stream_keeper_chat and /btw *)
  let su_no_keeper_msg =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods ~enabled:true ~require_token:true
      ~token_present:true ~token_valid:true ~effective_agent:(Some "w-nomsg")
      ~effective_role:(Some Rbac.Worker) ~effective_admin:(Some false)
      ~can_keeper_msg:false ~auth_error_code:None
      ~auth_error_detail:(Some "keeper msg disabled")
  in
  let sample_chat_req : Wire_fleet.chat_submit_request =
    {
      request_id = "req-1";
      keeper_name = "alpha";
      message = "hello";
      origin = Wire_fleet.Origin_bare;
      mode = Wire_fleet.Follow_up;
      turn_instructions = None;
      since_seq = None;
      attachments = [];
    }
  in
  let stream_chat_cmd =
    Cmd.Http_post_stream
      {
        epoch = Epoch.initial;
        req = Cmd.Stream_keeper_chat { request = sample_chat_req; is_btw = false };
      }
  in
  Alcotest.(check bool) "can_keeper_msg=false blocks Stream_keeper_chat in is_cmd_allowed"
    false (Rbac_policy.is_cmd_allowed su_no_keeper_msg stream_chat_cmd);
  Alcotest.(check int) "can_keeper_msg=false filters out Stream_keeper_chat" 0
    (List.length (Rbac_policy.filter_cmds su_no_keeper_msg [ stream_chat_cmd ]));
  let m_nomsg =
    Model.initial ~auth_session:su_no_keeper_msg ~cols:140 ~rows:40 ()
  in
  let m_btw_blocked, cmds_btw_blocked =
    Update_nav.start_btw_query ~now:t0 ~prompt:"ping" m_nomsg
  in
  Alcotest.(check int) "can_keeper_msg=false start_btw_query emits 0 cmds" 0
    (List.length (Cmd.flatten cmds_btw_blocked));
  Alcotest.(check bool) "can_keeper_msg=false start_btw_query sets warning toast"
    true
    (match m_btw_blocked.toast with
    | Some { level = Model.Toast_warning; _ } -> true
    | Some _ | None -> false);
  Alcotest.(check bool) "can_keeper_msg=false start_btw_query keeps modal closed"
    true (Option.is_none m_btw_blocked.inline_modal);

  (* P2-5: 5 direct-POST handlers warn & emit 0 cmds & mutate 0 state for SU Worker *)
  let check_warning_no_cmds label (next, cmds) =
    Alcotest.(check int) (label ^ " emits 0 cmds") 0
      (List.length (Cmd.flatten cmds));
    Alcotest.(check bool) (label ^ " sets warning toast") true
      (match next.Model.toast with
      | Some { level = Model.Toast_warning; _ } -> true
      | Some _ | None -> false);
    next
  in
  (* 5a. Verification approve/reject + precondition *)
  let sample_verif : Wire_work.verification_request =
    {
      request_id = "verif-1";
      task_id = "task-1";
      task_title = "Check RBAC";
      submitted_by = "alpha";
      created_at_unix = Some 1_700_000_000.0;
      completion_contract = [];
      required_artifacts = [];
      submitted_evidence = [];
      evidence_projection_error = None;
      review_observation = None;
    }
  in
  let m_worker_verif =
    let work =
      Work_store.apply_verifications ~observed_at:t0 [ sample_verif ]
        m_worker.work
    in
    { m_worker with work }
  in
  Alcotest.(check bool) "SU Worker check_verification_verdict_precondition returns Error"
    true
    (Result.is_error
       (Update_nav.check_verification_verdict_precondition m_worker_verif
          sample_verif));
  ignore
    (check_warning_no_cmds "SU Worker approve_verification_request"
       (Update_nav.approve_verification_request ~now:t0 m_worker_verif
          sample_verif));
  ignore
    (check_warning_no_cmds "SU Worker reject_verification_request"
       (Update_nav.reject_verification_request ~now:t0 m_worker_verif
          sample_verif));
  (* 5b. OAuth identity switch on Keeper_identity *)
  let sample_oauth_attached : Wire_keeper_context.oauth_attached_tools_snapshot =
    {
      keeper = "alpha";
      providers =
        [
          {
            provider = "github";
            provider_label = "GitHub";
            attached = true;
            app_state_kind = "ready";
            enabled = Some true;
            switch_problem = None;
            also_on = [];
            discovered_at = None;
            tools = [];
            problem = None;
          };
        ];
    }
  in
  let m_worker_oauth =
    let m0 =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    let ks0 = Keeper_context_store.get_keeper ~keeper:"alpha" m0.keeper_context in
    let ks1 =
      {
        ks0 with
        oauth_attached = Observed.value ~observed_at:t0 sample_oauth_attached;
        identity_selected_idx = 0;
      }
    in
    let kc =
      {
        m0.keeper_context with
        by_keeper =
          Keeper_context_store.String_map.add "alpha" ks1
            m0.keeper_context.by_keeper;
      }
    in
    let fleet =
      {
        (Fleet_store.set_keeper_dive_tab Nav.Keeper_identity m0.fleet) with
        selected_keeper = Some "alpha";
      }
    in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Keepers; pane_index = 1 };
      drafts = Drafts.set_active_keeper "alpha" m0.drafts;
      fleet;
      keeper_context = kc;
    }
  in
  ignore
    (check_warning_no_cmds "SU Worker Post_oauth_identity_switch"
       (Update_actions.execute_action ~now:t0 m_worker_oauth
          Keymap.Entity_approve_or_assign));
  (* 5c. Memory act resume on Knowledge_memory and Keeper_memory *)
  let m_worker_kmem =
    let m0 =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    let fleet =
      {
        (Fleet_store.set_keeper_dive_tab Nav.Keeper_memory m0.fleet) with
        selected_keeper = Some "alpha";
      }
    in
    {
      m0 with
      nav = { m0.nav with workspace = Nav.Keepers; pane_index = 1 };
      drafts = Drafts.set_active_keeper "alpha" m0.drafts;
      fleet;
    }
  in
  ignore
    (check_warning_no_cmds "SU Worker Keeper_memory Post_memory_act"
       (Update_actions.execute_action ~now:t0 m_worker_kmem
          Keymap.Entity_approve_or_assign));
  (* 5d. Preset restore on Runtime_tools_usage / Sec_presets *)
  let sample_preset : Wire_runtime.preset_manifest =
    {
      name = "prod";
      description = "Prod preset";
      created_at = "2026-11-26T00:00:00Z";
      override_count = 1;
      override_keys = [ "k" ];
      keepers = [];
      assignment_count = 0;
      lane_count = 1;
    }
  in
  let m_worker_preset =
    let m0 =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    let runtime =
      {
        m0.runtime with
        active_tab = Nav.Runtime_tools_usage;
        tools_subview = Runtime_store.Tools_prompts_presets;
        pp_section = Runtime_store.Sec_presets;
        pp_selected_index = 0;
        presets_listing =
          Observed.value ~observed_at:t0
            { Wire_runtime.presets = [ sample_preset ]; unreadable = [] };
      }
    in
    { m0 with nav = { m0.nav with workspace = Nav.Runtime }; runtime }
  in
  ignore
    (check_warning_no_cmds "SU Worker Post_preset_restore"
       (Update_actions.execute_action ~now:t0 m_worker_preset
          Keymap.Entity_approve_or_assign));
  (* 5e. Gate rule delete on Work_inbox / Inbox_rules must NOT mark gate_snapshot stale *)
  let sample_gate_rule : Wire_work.gate_rule =
    {
      id = "rule-1";
      keeper_name = "alpha";
      tool_name = "shell";
      request_fingerprint = "fp-1";
      created_at = 1_700_000_000.0;
      created_by = Some "admin";
      source_approval_id = None;
      expires_at = None;
    }
  in
  let sample_gate_snap : Wire_work.gate_snapshot =
    {
      generated_at = None;
      pending = [];
      pending_error = None;
      retry_meta = [];
      rules = [ sample_gate_rule ];
      rules_error = None;
      recent_resolved = [];
      recent_resolved_error = None;
      recent_resolved_partial = false;
      hitl = None;
    }
  in
  let m_worker_gate_rule =
    let m0 =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    let work =
      {
        m0.work with
        active_tab = Nav.Work_inbox;
        inbox_subview = Work_store.Inbox_rules;
        rule_selected_index = 0;
        gate_snapshot = Observed.value ~observed_at:t0 sample_gate_snap;
      }
    in
    { m0 with nav = { m0.nav with workspace = Nav.Work }; work }
  in
  let m_after_rule_del =
    check_warning_no_cmds "SU Worker Post_gate_rule_delete"
      (Update_actions.execute_action ~now:t0 m_worker_gate_rule
         Keymap.Entity_reject_or_cancel)
  in
  Alcotest.(check bool) "SU Worker denied gate rule delete leaves gate_snapshot fresh"
    false (Observed.is_stale m_after_rule_del.work.gate_snapshot);

  (* P1-2: Runtime_addons_browser O / D / W split for SU Worker *)
  let sample_client : Wire_runtime.browser_client_row =
    {
      client_id = "chrome-1";
      browser = "chrome";
      version = "130";
      engine_version = "130";
      transport = "ws";
      space = None;
      ownership = None;
      presence_state = None;
      presence_reason = None;
      interactions = [];
      last_activities = [];
    }
  in
  let sample_tab : Wire_runtime.browser_tab_row =
    {
      id = 7;
      title = "Home";
      url = "https://example.com";
      active = true;
      window_id = None;
      opened_by = None;
      label = None;
      dialog_present = false;
      dialog_kind = None;
    }
  in
  let sample_inst : Wire_runtime.addon_instance =
    {
      runtime_presence = Wire_runtime.Addon_live;
      instance_id = "inst-1";
      addon_id = "addon-1";
      title = "Addon";
      revision = "1";
      phase = Wire_runtime.Addon_attached;
      execution_kind = None;
      resolved_image = None;
      observation_seq = 1;
      rows_count = 0;
      observation_pending = false;
      visibility_kind = None;
      visibility_keeper = None;
      host_cycles = None;
      host_waiting_count = 0;
      host_issue_kind = None;
      action_names = [];
      config_declaration_id = None;
    }
  in
  let m_worker_addons_p1 =
    let m0 =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    let tabs_resp : Wire_runtime.browser_tabs_response =
      {
        client_id = Some "chrome-1";
        tabs = [ sample_tab ];
        complete = true;
        unavailable_count = 0;
        error = None;
      }
    in
    let runtime =
      {
        m0.runtime with
        active_tab = Nav.Runtime_addons_browser;
        addon_catalog_mode = false;
        browser_lane =
          Observed.value ~observed_at:t0
            {
              Wire_runtime.ok = true;
              available = true;
              inventory_complete = true;
              client_count = 1;
              issue_count = 0;
              automatic_browse_ok = true;
              detail = None;
              clients = [ sample_client ];
              issues = [];
            };
        browser_tabs =
          Runtime_store.String_map.add "chrome-1"
            (Observed.value ~observed_at:t0 tabs_resp)
            m0.runtime.browser_tabs;
        lane_addons =
          Observed.value ~observed_at:t0
            {
              Wire_runtime.configuration_complete = true;
              declarations = [];
              instances = [ sample_inst ];
              issues = [];
            };
      }
    in
    { m0 with nav = { m0.nav with workspace = Nav.Runtime; pane_index = 1 }; runtime }
  in
  let _, cmds_scene =
    Update.step ~now:t0 m_worker_addons_p1 (Msg.Key_event (char_key "O"))
  in
  Alcotest.(check bool) "SU Worker pane 1 [O] emits Post_browser_scene" true
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_browser_scene _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_scene));
  let _, cmds_shot =
    Update.step ~now:t0 m_worker_addons_p1 (Msg.Key_event (char_key "W"))
  in
  Alcotest.(check bool) "SU Worker pane 1 [W] emits Post_browser_screenshot" true
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_browser_screenshot _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_shot));
  let m_worker_addons_p0 =
    {
      m_worker_addons_p1 with
      nav = { m_worker_addons_p1.nav with pane_index = 0 };
    }
  in
  let _, cmds_slice =
    Update.step ~now:t0 m_worker_addons_p0 (Msg.Key_event (char_key "D"))
  in
  Alcotest.(check bool) "SU Worker pane 0 [D] emits Get_lane_addon_slice" true
    (List.exists
       (function
         | Cmd.Http_get { req = Cmd.Get_lane_addon_slice _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_slice));
  let _, cmds_observe =
    Update.step ~now:t0 m_worker_addons_p0 (Msg.Key_event (char_key "O"))
  in
  Alcotest.(check bool) "SU Worker pane 0 [O] emits Post_lane_addon_observe (CanBroadcast)"
    true
    (List.exists
       (function
         | Cmd.Http_post { req = Cmd.Post_lane_addon_observe _; _ } -> true
         | _ -> false)
       (Cmd.flatten cmds_observe));
  let m_ma_addons_p0 =
    { m_worker_addons_p0 with auth_session = ma_human_admin_session }
  in
  ignore
    (check_warning_no_cmds "MA Admin Session pane 0 [O] Post_lane_addon_observe blocked"
       (Update.step ~now:t0 m_ma_addons_p0 (Msg.Key_event (char_key "O"))));

  (* #28 P1-2: Unbind_connector allowed on Runtime_connectors for SU Worker, denied on Keeper_identity *)
  let m_worker_connectors =
    let base =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime };
      runtime = { base.runtime with active_tab = Nav.Runtime_connectors };
    }
  in
  Alcotest.(check bool) "SU Worker allowed Unbind_connector on Runtime_connectors"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_worker_connectors
       Keymap.Unbind_connector);
  Alcotest.(check bool) "SU Worker denied Unbind_connector on Keeper_identity"
    false
    (Rbac_policy.can_run_keymap_action_in_model m_worker_oauth
       Keymap.Unbind_connector);

  (* P2-6: Context-aware keymap action access (Edit_or_export / Launch_fusion / Probe_sandbox) *)
  let m_ma_quotas_login =
    let base =
      Model.initial ~auth_session:ma_human_worker_pat ~cols:140 ~rows:40 ()
    in
    let receipt : Wire_runtime.setup_login_receipt =
      {
        login_id = "login-1";
        integration_id = "openai";
        status = "pending";
        account = None;
        account_ref = None;
        authentication = None;
      }
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime };
      runtime =
        {
          base.runtime with
          active_tab = Nav.Runtime_quotas_credits;
          setup_login_receipt = Some receipt;
        };
    }
  in
  Alcotest.(check bool)
    "MA Human Worker PAT can run [e] on Quotas when login_id is active" true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_quotas_login
       Keymap.Edit_or_export);
  let m_svc_quotas_login =
    { m_ma_quotas_login with auth_session = ma_service_worker }
  in
  Alcotest.(check bool)
    "MA Service Worker denied [e] on Quotas even when login_id is active" false
    (Rbac_policy.can_run_keymap_action_in_model m_svc_quotas_login
       Keymap.Edit_or_export);
  let m_ma_admin_wiki =
    let base =
      Model.initial ~auth_session:ma_human_admin_session ~cols:140 ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge };
      knowledge = { base.knowledge with active_tab = Nav.Knowledge_wiki };
    }
  in
  Alcotest.(check bool) "MA Admin Session can run [e] on Wiki" true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_admin_wiki
       Keymap.Edit_or_export);
  let m_ma_pat_wiki =
    { m_ma_admin_wiki with auth_session = ma_human_admin_pat }
  in
  Alcotest.(check bool) "MA Admin PAT denied [e] on Wiki" false
    (Rbac_policy.can_run_keymap_action_in_model m_ma_pat_wiki
       Keymap.Edit_or_export);
  let m_ma_mem_diff =
    let base =
      Model.initial ~auth_session:ma_human_worker_pat ~cols:140 ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Knowledge };
      knowledge =
        {
          base.knowledge with
          active_tab = Nav.Knowledge_memory;
          memory_subview = Knowledge_store.Mem_diff_flow;
        };
    }
  in
  Alcotest.(check bool) "MA Worker PAT can run [e] (Evolution) & [f] (Facts) on Memory"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_mem_diff
       Keymap.Edit_or_export
     && Rbac_policy.can_run_keymap_action_in_model m_ma_mem_diff
          Keymap.Launch_fusion);
  let m_worker_code =
    let base =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Infra };
      infra = { base.infra with active_tab = Nav.Infra_code };
    }
  in
  Alcotest.(check bool) "SU Worker can run [f] (Code search) & [p] (Code finder) on Infra_code"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_worker_code
       Keymap.Launch_fusion
     && Rbac_policy.can_run_keymap_action_in_model m_worker_code
          Keymap.Probe_sandbox);

  (* R5-PR6: [x] Entity_reject_or_cancel on Runtime_addons_browser & Tools_prompts_presets *)
  let m_worker_addons =
    let base =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~cols:140
        ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime; pane_index = 0 };
      runtime =
        {
          base.runtime with
          active_tab = Nav.Runtime_addons_browser;
          addon_catalog_mode = false;
        };
    }
  in
  Alcotest.(check bool) "SU Worker can run [x] & [d] on Runtime_addons_browser"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_worker_addons
       Keymap.Entity_reject_or_cancel
     && Rbac_policy.can_run_keymap_action_in_model m_worker_addons
          Keymap.Delete_selected);
  let m_ma_addons = { m_worker_addons with auth_session = ma_human_admin_session } in
  Alcotest.(check bool) "MA Admin denied [x] & [d] on Runtime_addons_browser"
    false
    (Rbac_policy.can_run_keymap_action_in_model m_ma_addons
       Keymap.Entity_reject_or_cancel
     || Rbac_policy.can_run_keymap_action_in_model m_ma_addons
          Keymap.Delete_selected);

  let sample_prompt : Wire_runtime.prompt_item =
    {
      key = "keeper.base";
      category = "keeper";
      operator_surface = "prompts";
      description = "Base";
      effective = "eff";
      file_value = Some "file";
      override_value = Some "ovr";
      file_path = None;
      source = "override";
      has_override = true;
      override_default_moved = false;
      char_count = 3;
      template_variables = [];
    }
  in
  let sample_preset : Wire_runtime.preset_manifest =
    {
      name = "ops-preset";
      description = "Ops";
      created_at = "2026-11-27T00:00:00Z";
      override_count = 1;
      override_keys = [ "keeper.base" ];
      keepers = [];
      assignment_count = 0;
      lane_count = 0;
    }
  in
  let sample_param : Wire_runtime.runtime_param_item =
    {
      key = "turn_timeout_s";
      current = `Int 60;
      default = `Int 30;
      has_override = true;
      description = Some "timeout";
      value_type = Some "int";
      choices = [];
    }
  in
  let make_pp_model ~auth_session ~section =
    let base = Model.initial ~auth_session ~cols:140 ~rows:40 () in
    {
      base with
      nav = { base.nav with workspace = Nav.Runtime };
      runtime =
        {
          base.runtime with
          active_tab = Nav.Runtime_tools_usage;
          tools_subview = Runtime_store.Tools_prompts_presets;
          pp_section = section;
          pp_selected_index = 0;
          prompts_catalog =
            Observed.value ~observed_at:t0
              { Wire_runtime.prompts = [ sample_prompt ]; held_back = [] };
          presets_listing =
            Observed.value ~observed_at:t0
              { Wire_runtime.presets = [ sample_preset ]; unreadable = [] };
          runtime_params =
            Observed.value ~observed_at:t0
              { Wire_runtime.parameters = [ sample_param ] };
        };
    }
  in
  let m_opt_prompts =
    make_pp_model ~auth_session:su_optional_token_admin
      ~section:Runtime_store.Sec_prompts
  in
  let m_worker_prompts =
    make_pp_model ~auth_session:Rbac.single_user_local_worker
      ~section:Runtime_store.Sec_prompts
  in
  Alcotest.(check bool) "SU optional-token Admin allowed [x] on Sec_prompts (Single_user_role_admin)"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_opt_prompts
       Keymap.Entity_reject_or_cancel);
  Alcotest.(check bool) "SU Worker denied [x] on Sec_prompts" false
    (Rbac_policy.can_run_keymap_action_in_model m_worker_prompts
       Keymap.Entity_reject_or_cancel);
  let _, worker_prompt_cmds =
    Update_actions.execute_action ~now:t0 m_worker_prompts
      Keymap.Entity_reject_or_cancel
  in
  Alcotest.(check int) "SU Worker [x] on Sec_prompts emits 0 cmds" 0
    (List.length (Cmd.flatten worker_prompt_cmds));
  let m_opt_presets =
    make_pp_model ~auth_session:su_optional_token_admin
      ~section:Runtime_store.Sec_presets
  in
  let m_tok_presets =
    make_pp_model ~auth_session:su_token_admin
      ~section:Runtime_store.Sec_presets
  in
  Alcotest.(check bool) "SU optional-token Admin denied [x] on Sec_presets (Single_user_token_admin_only)"
    false
    (Rbac_policy.can_run_keymap_action_in_model m_opt_presets
       Keymap.Entity_reject_or_cancel);
  Alcotest.(check bool) "SU token Admin allowed [x] on Sec_presets" true
    (Rbac_policy.can_run_keymap_action_in_model m_tok_presets
       Keymap.Entity_reject_or_cancel);
  let _, opt_preset_cmds =
    Update_actions.execute_action ~now:t0 m_opt_presets
      Keymap.Entity_reject_or_cancel
  in
  Alcotest.(check int) "SU optional-token Admin [x] on Sec_presets emits 0 cmds"
    0
    (List.length (Cmd.flatten opt_preset_cmds));
  let m_opt_params =
    make_pp_model ~auth_session:su_optional_token_admin
      ~section:Runtime_store.Sec_params
  in
  let m_worker_params =
    make_pp_model ~auth_session:Rbac.single_user_local_worker
      ~section:Runtime_store.Sec_params
  in
  Alcotest.(check bool) "SU optional-token Admin allowed [x] on Sec_params" true
    (Rbac_policy.can_run_keymap_action_in_model m_opt_params
       Keymap.Entity_reject_or_cancel);
  let _, worker_param_cmds =
    Update_actions.execute_action ~now:t0 m_worker_params
      Keymap.Entity_reject_or_cancel
  in
  Alcotest.(check int) "SU Worker [x] on Sec_params emits 0 cmds" 0
    (List.length (Cmd.flatten worker_param_cmds));

  (* R5-PR6: [d] Delete_selected context-aware RBAC *)
  Alcotest.(check bool) "MA Worker PAT allowed [d] (Diff view) on Knowledge_memory"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_mem_diff
       Keymap.Delete_selected);
  let m_ma_keeper_cfg =
    let base =
      Model.initial ~auth_session:ma_human_admin_session ~cols:140 ~rows:40 ()
    in
    {
      base with
      nav = { base.nav with workspace = Nav.Keepers };
      fleet = { base.fleet with keeper_dive_tab = Nav.Keeper_config };
    }
  in
  Alcotest.(check bool) "MA Admin Session allowed [d] on Personal Keepers"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_keeper_cfg
       Keymap.Delete_selected);
  let m_ma_pat_keeper_cfg =
    { m_ma_keeper_cfg with auth_session = ma_human_admin_pat }
  in
  Alcotest.(check bool) "MA Admin PAT allowed [d] (personal conversation delete) on Keepers"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_pat_keeper_cfg
       Keymap.Delete_selected);
  let m_ma_svc_keeper_cfg =
    { m_ma_keeper_cfg with auth_session = ma_service_worker }
  in
  Alcotest.(check bool) "MA Service denied [d] on Keepers" false
    (Rbac_policy.can_run_keymap_action_in_model m_ma_svc_keeper_cfg
       Keymap.Delete_selected);

  (* R5-PR6: Verification Dive tabs surface RBAC denial, Failed, and Absent truthfully *)
  let sample_verif : Wire_work.verification_request =
    {
      request_id = "verif-r5";
      task_id = "task-r5";
      task_title = "Check RBAC";
      submitted_by = "alpha";
      created_at_unix = None;
      completion_contract = [];
      required_artifacts = [];
      submitted_evidence = [];
      evidence_projection_error = None;
      review_observation = None;
    }
  in
  let m_verif_worker =
    let base =
      Model.initial ~auth_session:Rbac.single_user_local_worker ~lang:Say.Lang_en
        ~cols:140 ~rows:40 ()
    in
    {
      base with
      work =
        {
          base.work with
          verification_dive_tab = Work_store.Verif_tab_evidence;
          verification_summary =
            Observed.failed ~reason:"HTTP 500" ~retryable:true ~at:t0;
          verification_specs = Observed.Absent;
        };
    }
  in
  let ev_lines =
    Update_nav.verification_dive_tab_lines ~width:80 m_verif_worker sample_verif
  in
  Alcotest.(check bool) "Verif_tab_evidence shows Access denied for SU Worker (not infinite loading)"
    true
    (List.exists
       (fun (l : Update_nav.styled_line) ->
         contains_ci ~needle:"Access denied" l.text)
       ev_lines);
  let sum_lines =
    Update_nav.verification_dive_tab_lines ~width:80
      {
        m_verif_worker with
        work =
          {
            m_verif_worker.work with
            verification_dive_tab = Work_store.Verif_tab_summary;
          };
      }
      sample_verif
  in
  Alcotest.(check bool) "Verif_tab_summary renders Observed.Failed error" true
    (List.exists
       (fun (l : Update_nav.styled_line) ->
         l.tone = Update_nav.Line_error
         && contains_ci ~needle:"HTTP 500" l.text)
       sum_lines);
  let spec_lines =
    Update_nav.verification_dive_tab_lines ~width:80
      {
        m_verif_worker with
        work =
          {
            m_verif_worker.work with
            verification_dive_tab = Work_store.Verif_tab_specs;
          };
      }
      sample_verif
  in
  Alcotest.(check bool) "Verif_tab_specs renders Observed.Absent warning" true
    (List.exists
       (fun (l : Update_nav.styled_line) ->
         l.tone = Update_nav.Line_warn
         && contains_ci ~needle:"404" l.text)
       spec_lines)

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

  (* Worker SU on Infra: badge LOCAL WORKER, Infra is readable (Su_read_ma_admin),
     and footer omits dead Admin hotkeys (Settings). *)
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
  Alcotest.(check bool) "Worker top rail marks non-admin session with lock glyph" true
    (contains_ci ~needle:lock_glyph txt_worker_infra);
  Alcotest.(check bool) "Worker Infra Sandboxes is NOT locked (SU CanReadState)" false
    (contains_ci ~needle:"LOCKED" txt_worker_infra);
  Alcotest.(check bool) "Worker Infra footer hides Settings hotkey" false
    (contains_ci ~needle:"Settings" txt_worker_infra);

  (* Worker SU on Knowledge > Artifacts (Token_permission CanAdmin): renders LOCKED panel *)
  let m_worker_artifacts =
    let m =
      Model.initial ~auth_session:Rbac.single_user_local_worker
        ~lang:Say.Lang_en ~cols:140 ~rows:40 ()
    in
    {
      m with
      nav = { m.nav with workspace = Nav.Knowledge };
      knowledge = { m.knowledge with active_tab = Nav.Knowledge_artifacts };
    }
  in
  let txt_worker_artifacts = render_full_frame m_worker_artifacts in
  Alcotest.(check bool) "Worker Knowledge Artifacts renders LOCKED panel" true
    (contains_ci ~needle:"LOCKED" txt_worker_artifacts);

  (* P2-6: Work_views card hotkeys gated for SU Worker *)
  let m_worker_inbox_rules =
    let m =
      Model.initial ~auth_session:Rbac.single_user_local_worker
        ~lang:Say.Lang_en ~cols:140 ~rows:40 ()
    in
    {
      m with
      nav = { m.nav with workspace = Nav.Work };
      work =
        {
          m.work with
          active_tab = Nav.Work_inbox;
          inbox_subview = Work_store.Inbox_rules;
        };
    }
  in
  let txt_worker_rules = render_full_frame m_worker_inbox_rules in
  Alcotest.(check bool) "Worker Work_inbox Rules omits [Ctrl+,] Settings card hotkey"
    false (contains_ci ~needle:"[Ctrl+,] Settings" txt_worker_rules);
  let m_worker_inbox_hist =
    {
      m_worker_inbox_rules with
      work =
        { m_worker_inbox_rules.work with inbox_subview = Work_store.Inbox_history };
    }
  in
  let txt_worker_hist = render_full_frame m_worker_inbox_hist in
  Alcotest.(check bool) "Worker Work_inbox History omits /gate ack-uncertain hotkey"
    false (contains_ci ~needle:"/gate ack-uncertain" txt_worker_hist);

  (* P2-7: Work_dive Verification_inspector renders LOCKED panel in Multi-account *)
  let m_ma_verif_dive =
    let m =
      Model.initial ~auth_session:ma_human_worker_pat ~lang:Say.Lang_en
        ~cols:140 ~rows:40 ()
    in
    {
      m with
      nav = { m.nav with inspector = Some (Nav.Verification_inspector "req-99") };
    }
  in
  let txt_ma_verif_dive = render_full_frame m_ma_verif_dive in
  Alcotest.(check bool) "MA Worker Verification_inspector renders LOCKED panel" true
    (contains_ci ~needle:"LOCKED" txt_ma_verif_dive);

  (* Multi-account Admin PAT on Keepers: badge MA ADMIN·PAT, unlocked Personal Keepers *)
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
  Alcotest.(check bool) "MA Admin PAT Keepers renders Personal Keepers (not LOCKED)"
    true
    (contains_ci ~needle:"Personal Keepers" txt_ma_pat
     && not (contains_ci ~needle:"LOCKED" txt_ma_pat));

  (* Multi-account Service on Keepers: renders LOCKED panel *)
  let m_ma_svc_keepers =
    { m_ma_pat_keepers with auth_session = ma_service_worker }
  in
  let txt_ma_svc = render_full_frame m_ma_svc_keepers in
  Alcotest.(check bool) "MA Service Keepers renders LOCKED panel" true
    (contains_ci ~needle:"LOCKED" txt_ma_svc);

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
  (* #28 P2-3: SU auth_enabled=false Admin sees Tool_approval on fast strip (Single_user_role_admin),
     but NOT Gate pending (Single_user_token_admin_only) *)
  let su_auth_off_local =
    Rbac.session_of_single_user_shell_auth
      ~auth_methods:Rbac.default_auth_methods ~enabled:false
      ~require_token:false ~token_present:false ~token_valid:false
      ~effective_agent:(Some "local") ~effective_role:(Some Rbac.Admin)
      ~effective_admin:(Some true) ~can_keeper_msg:true ~auth_error_code:None
      ~auth_error_detail:None
  in
  let m_auth_off_attn =
    {
      (Model.initial ~auth_session:su_auth_off_local ~lang:Say.Lang_en ~cols:140
         ~rows:40 ())
      with
      attention = attn;
    }
  in
  Alcotest.(check bool) "SU auth_off Admin sees Payload_tool_approval in fast approval strip"
    true
    (Option.is_some (Model.fast_approval_strip_item m_auth_off_attn));

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
        repo_activity =
          Some
            {
              Infra_store.repo_id = "r1";
              activity =
                Observed.value ~observed_at:t0
                  {
                    Wire_infra.window_hours = 24.0;
                    changes = [];
                    incomplete = 0;
                    unattributed = 0;
                  };
            };
      }
    in
    let work =
      {
        base.work with
        verification_evidence =
          Observed.value ~observed_at:t0
            ( "verif-1"
            , {
                Wire_work.task_id = "t1";
                verification_id = "verif-1";
                producer = None;
                authority_kind = "admin";
                authority_actor = "root";
                available = true;
                unavailable_reason = None;
                items = [];
              } );
        verification_evidence_auth_denied = true;
        late_approval_attempts =
          Observed.value ~observed_at:t0
            [
              {
                Wire_work.consume_id = "c1";
                keeper_name = "alpha";
                tool_name = "shell";
                args_fingerprint = "fp";
                consumed_at = 1_700_000_000.0;
                outcome = "uncertain";
              };
            ];
        late_approval_auth_denied = true;
      }
    in
    let runtime =
      {
        base.runtime with
        addon_declaration_doc =
          Observed.value ~observed_at:t0
            ( "a.toml"
            , {
                Wire_runtime.file_name = "a.toml";
                source_path = "a.toml";
                source_text = "id = \"a\"";
                source_revision = "r1";
                desired_revision = None;
                valid = true;
                messages = [];
              } );
        addon_last_action_receipt =
          Observed.value ~observed_at:t0
            {
              Wire_runtime.instance_id = "inst-1";
              request_id = "req-1";
              state = "ok";
              detail = None;
              result_json = None;
            };
        browser_last_receipt =
          Observed.value ~observed_at:t0
            {
              Wire_runtime.ok = true;
              summary = "clicked";
              data_json = None;
              error = None;
            };
      }
    in
    let keeper_context =
      let ks0 = Keeper_context_store.get_keeper ~keeper:"alpha" base.keeper_context in
      let ks1 =
        {
          ks0 with
          next_request =
            Observed.value ~observed_at:t0
              {
                Wire_keeper_context.keeper = "alpha";
                trace_id = "tr-1";
                checkpoint_messages = 1;
                wake_line_bytes = 64;
                walk = Wire_keeper_context.Walk_order { lane_id = "l1"; declared = [] };
                candidates = [];
              };
          next_request_absent = true;
        }
      in
      {
        base.keeper_context with
        by_keeper =
          Keeper_context_store.String_map.add "alpha" ks1
            base.keeper_context.by_keeper;
      }
    in
    let knowledge =
      {
        base.knowledge with
        keeper_memory_activity =
          Knowledge_store.String_map.add "alpha"
            (Observed.value ~observed_at:t0
               {
                 Wire_knowledge.keeper = "alpha";
                 limit = 20;
                 journal_lines = 1;
                 undecodable_lines = 0;
                 events = [];
                 notes = [];
               })
            base.knowledge.keeper_memory_activity;
        artifacts =
          Observed.value ~observed_at:t0
            [
              {
                Wire_knowledge.id = "art-1";
                revision = 1;
                title = "Secret";
                summary = "Admin only";
                author = "admin";
                created_at_unix = 1_700_000_000.0;
                body = { sha256 = "sha"; bytes = 10; mime = "text/markdown" };
              };
            ];
        artifact_checks =
          Observed.value ~observed_at:t0
            [
              {
                Wire_knowledge.id = "art-1";
                revision = 1;
                body_sha256 = "sha";
                checked = true;
                change_id = "ch-1";
                changed_by = "admin";
                changed_at = "2026-11-26T00:00:00Z";
              };
            ];
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
      work;
      runtime;
      keeper_context;
      knowledge;
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
  Alcotest.(check bool) "Demotion purges Infra repo_activity cache" true
    (Option.is_none m_demoted.infra.repo_activity);
  Alcotest.(check bool) "Demotion purges Work verification_evidence & auth_denied"
    true
    (Option.is_none (Observed.to_option m_demoted.work.verification_evidence)
     && not m_demoted.work.verification_evidence_auth_denied);
  Alcotest.(check bool) "Demotion purges Work late_approval_attempts & auth_denied"
    true
    (Option.is_none (Observed.to_option m_demoted.work.late_approval_attempts)
     && not m_demoted.work.late_approval_auth_denied);
  Alcotest.(check bool) "Demotion purges Runtime addon & browser receipts" true
    (Option.is_none (Observed.to_option m_demoted.runtime.addon_last_action_receipt)
     && Option.is_none (Observed.to_option m_demoted.runtime.browser_last_receipt));
  Alcotest.(check bool) "Demotion keeps addon_declaration_doc for SU Worker (Single_user_read)"
    true
    (Option.is_some (Observed.to_option m_demoted.runtime.addon_declaration_doc));
  let ks_demoted =
    Keeper_context_store.get_keeper ~keeper:"alpha" m_demoted.keeper_context
  in
  Alcotest.(check bool) "Demotion purges Keeper next_request & next_request_absent (#28 P1-1)"
    true
    (Option.is_none (Observed.to_option ks_demoted.next_request)
     && not ks_demoted.next_request_absent);
  Alcotest.(check bool) "Demotion purges Knowledge keeper_memory_activity (#28 P1-1)"
    true
    (Knowledge_store.String_map.is_empty m_demoted.knowledge.keeper_memory_activity);
  Alcotest.(check bool) "Demotion purges Knowledge artifacts & artifact_checks" true
    (Option.is_none (Observed.to_option m_demoted.knowledge.artifacts)
     && Option.is_none (Observed.to_option m_demoted.knowledge.artifact_checks));
  Alcotest.(check bool) "Demotion disarms keeper_stop_armed" true
    (Option.is_none m_demoted.keeper_stop_armed);

  (* Stale pre-demotion HTTP reply MUST be dropped by epoch guard (cannot repopulate purged cache) *)
  let m_after_late, _ =
    Update.step ~now:t1 m_demoted
      (Msg.Http_reply
         {
           epoch = pre_demote_epoch;
           reply =
             Msg.Reply_artifacts
               {
                 generation = 0;
                 result =
                   Ok
                     [
                       {
                         Wire_knowledge.id = "art-late";
                         revision = 1;
                         title = "Late";
                         summary = "Should drop";
                         author = "admin";
                         created_at_unix = 1_700_000_000.0;
                         body = { sha256 = "sha"; bytes = 5; mime = "text/markdown" };
                       };
                     ];
               };
         })
  in
  Alcotest.(check bool) "Late pre-demotion reply dropped (artifacts stay purged)"
    true
    (Option.is_none (Observed.to_option m_after_late.knowledge.artifacts));

  (* E. Runtime SSE 401 enters Auth_gate, bumps epoch, purges sandboxes, and tears down streams *)
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
  Alcotest.(check bool) "SSE 401 purges Infra sandboxes & Runtime addon_declaration_doc"
    true
    (Option.is_none (Observed.to_option m_sse_401.infra.sandboxes)
     && Option.is_none (Observed.to_option m_sse_401.runtime.addon_declaration_doc));
  Alcotest.(check bool) "SSE 401 bumps epoch" true
    (not (Epoch.equal m_demoted.epoch m_sse_401.epoch));
  Alcotest.(check bool) "SSE 401 syncs empty stream list" true
    (List.exists
       (function Cmd.Sync_streams { streams = []; _ } -> true | _ -> false)
       (Cmd.flatten cmds_sse_401));

  (* Verify SU auth_off bootstrap resolves to authenticated SU local (Su_read_ma_admin=true, Bridged_token_admin=false) *)
  let m_off, _ =
    Update.step ~now:t0 m_su_probe
      (Msg.Http_reply
         {
           epoch = m_su_probe.epoch;
           reply =
             Msg.Reply_dashboard_shell (Ok (sample_shell ~auth:su_auth_admin_off ()));
         })
  in
  Alcotest.(check bool) "SU auth_off bootstrap resolves authenticated with Su_read_ma_admin=true, can_admin=false"
    true
    (Rbac.is_authenticated m_off.auth_session
     && Rbac.is_allowed m_off.auth_session Rbac.Su_read_ma_admin
     && not (Rbac.can_admin m_off.auth_session));

  (* F. #75 P1: GET /health 401/403 defense-in-depth exits Probing_health -> Auth_unavailable + Auth_gate,
     and Public_health anon fallback completes 2-step SU Player & SU invalid-token handshakes *)
  List.iter
    (fun status ->
      let m_err, cmds_err =
        Update.step ~now:t0 m0
          (Msg.Server_health_result
             {
               epoch = m0.epoch;
               result =
                 Error
                   (Msg.Http_error
                      { status; body = {|{"error":"denied"}|}; api_error = None });
             })
      in
      let lbl = Printf.sprintf "/health HTTP %d" status in
      Alcotest.(check bool) (lbl ^ " exits Probing_health to Auth_unavailable")
        true
        (match m_err.auth_session with
        | Rbac.Auth_unavailable { mode = None; _ } -> true
        | Rbac.Probing_health
        | Rbac.Probing_single_user _
        | Rbac.Probing_multi_account _
        | Rbac.Single_user_local _
        | Rbac.Single_user_auth_required _
        | Rbac.Multi_account_signed_out _
        | Rbac.Multi_account_signed_in _
        | Rbac.Auth_unavailable { mode = Some _; _ } ->
            false);
      Alcotest.(check bool) (lbl ^ " opens Auth_gate") true
        (Option.equal Nav.equal_overlay m_err.nav.overlay
           (Some (Nav.System_gate Nav.Auth_gate)));
      Alcotest.(check bool) (lbl ^ " emits zero data GETs") false
        (List.exists
           (function Cmd.Http_get _ -> true | _ -> false)
           (Cmd.flatten cmds_err)))
    [ 401; 403 ];

  let public_su_health =
    { (sample_health ~mode:Rbac.Single_user ()) with scope = Wire_common.Public_health }
  in
  let m_pub_probe, cmds_pub_probe =
    Update.step ~now:t0 m0
      (Msg.Server_health_result { epoch = m0.epoch; result = Ok public_su_health })
  in
  Alcotest.(check bool) "Public_health SU advances to Probing_single_user + Get_dashboard_shell"
    true
    ((match m_pub_probe.auth_session with
     | Rbac.Probing_single_user _ -> true
     | Rbac.Probing_health
     | Rbac.Probing_multi_account _
     | Rbac.Single_user_local _
     | Rbac.Single_user_auth_required _
     | Rbac.Multi_account_signed_out _
     | Rbac.Multi_account_signed_in _
     | Rbac.Auth_unavailable _ ->
         false)
     && List.exists
          (function
            | Cmd.Http_get { req = Cmd.Get_dashboard_shell; _ } -> true
            | _ -> false)
          (Cmd.flatten cmds_pub_probe));
  let su_auth_player : Wire_fleet.shell_auth_summary =
    {
      su_auth_worker with
      token_agent = Some "player-1";
      effective_agent = Some "player-1";
      effective_role = Some Rbac.Player;
      effective_admin = Some false;
      can_keeper_msg = false;
    }
  in
  let m_player_settled, _ =
    Update.step ~now:t0 m_pub_probe
      (Msg.Http_reply
         {
           epoch = m_pub_probe.epoch;
           reply = Msg.Reply_dashboard_shell (Ok (sample_shell ~auth:su_auth_player ()));
         })
  in
  Alcotest.(check bool) "Public_health -> shell.auth settles SU Player without Auth_gate deadlock"
    true
    (Rbac.is_authenticated m_player_settled.auth_session
     && Option.is_none m_player_settled.nav.overlay
     && not (Rbac.is_allowed m_player_settled.auth_session Rbac.Single_user_read));
  let su_auth_invalid : Wire_fleet.shell_auth_summary =
    {
      su_auth_worker with
      token_present = true;
      token_valid = false;
      token_agent = None;
      effective_agent = None;
      effective_role = None;
      effective_admin = Some false;
      auth_error_code = Some "invalid_token";
      auth_error_detail = Some "Invalid bearer token";
      can_keeper_msg = false;
    }
  in
  let m_bad_settled, _ =
    Update.step ~now:t0 m_pub_probe
      (Msg.Http_reply
         {
           epoch = m_pub_probe.epoch;
           reply = Msg.Reply_dashboard_shell (Ok (sample_shell ~auth:su_auth_invalid ()));
         })
  in
  Alcotest.(check bool) "Public_health -> shell.auth invalid token settles to Token_invalid + Auth_gate"
    true
    ((match m_bad_settled.auth_session with
     | Rbac.Single_user_auth_required { reason = Rbac.Token_invalid _; _ } -> true
     | Rbac.Single_user_auth_required
         {
           reason =
             ( Rbac.Token_required
             | Rbac.Signed_out _
             | Rbac.Forbidden_credential _
             | Rbac.Auth_unavailable _ );
           _;
         }
     | Rbac.Probing_health
     | Rbac.Probing_single_user _
     | Rbac.Probing_multi_account _
     | Rbac.Single_user_local _
     | Rbac.Multi_account_signed_out _
     | Rbac.Multi_account_signed_in _
     | Rbac.Auth_unavailable _ ->
         false)
     && Option.equal Nav.equal_overlay m_bad_settled.nav.overlay
          (Some (Nav.System_gate Nav.Auth_gate)))

(* 5. Account/Session Overlay, Shortcuts, Capability Matrix & Truthful Rendering *)
let test_account_overlay_and_capability_matrix () =
  (* Reachability: slash /account, keymap @ & Alt+A, zero collisions, sidebar Menu_account, Ctrl+K palette *)
  Alcotest.(check int) "zero keymap collisions" 0 (List.length (Keymap.collisions ()));
  (match Slash.parse "/account" with
  | Ok Slash.Account -> ()
  | Ok _ | Error _ -> Alcotest.fail "expected /account -> Ok Slash.Account");
  let base_su =
    Model.initial ~lang:Say.Lang_en ~auth_session:su_token_admin ()
  in
  let m_slash, _ =
    Update.step ~now:t0 base_su
      (Msg.Key_event (char_key "@"))
  in
  Alcotest.(check bool) "'@' opens Nav.Account overlay" true
    (Option.equal Nav.equal_overlay m_slash.nav.overlay (Some Nav.Account));
  Alcotest.(check bool) "active_menu_target = Menu_account" true
    (Nav.equal_menu_target (Model.active_menu_target m_slash) Nav.Menu_account);
  let m_alt_close, _ =
    Update.step ~now:t0 m_slash
      (Msg.Key_event (char_key ~mods:{ Keymap.Input.no_mods with alt = true } "a"))
  in
  Alcotest.(check bool) "Alt+A toggles Nav.Account closed" true
    (Option.is_none m_alt_close.nav.overlay);
  let m_alt_open, _ =
    Update.step ~now:t0 m_alt_close
      (Msg.Key_event (char_key ~mods:{ Keymap.Input.no_mods with alt = true } "a"))
  in
  Alcotest.(check bool) "Alt+A opens Nav.Account" true
    (Option.equal Nav.equal_overlay m_alt_open.nav.overlay (Some Nav.Account));
  let m_slash_open, _ =
    Update_actions.execute_slash ~now:t0 base_su Slash.Account
  in
  Alcotest.(check bool) "/account opens Nav.Account" true
    (Option.equal Nav.equal_overlay m_slash_open.nav.overlay (Some Nav.Account));
  (* Palette discovery by alias "pat" / "account" *)
  let m_pal =
    {
      base_su with
      nav = { base_su.nav with overlay = Some Nav.Palette };
      palette = { mode = Model.Palette_commands; query = "account"; selected = 0 };
    }
  in
  let pal_entries, _ = Update_nav.palette_entries_with_overflow m_pal in
  Alcotest.(check bool) "Palette surfaces Menu_account on 'account'" true
    (List.exists
       (fun (e : Update_nav.palette_entry) ->
         match e.action with
         | Update_nav.Pal_menu_target Nav.Menu_account -> true
         | Update_nav.Pal_menu_target _
         | Update_nav.Pal_keymap_action _
         | Update_nav.Pal_keeper_lifecycle _
         | Update_nav.Pal_dive_keeper _
         | Update_nav.Pal_select_company _
         | Update_nav.Pal_dive_goal _
         | Update_nav.Pal_dive_task _
         | Update_nav.Pal_dive_thread _
         | Update_nav.Pal_dive_wiki _
         | Update_nav.Pal_dive_sandbox _
         | Update_nav.Pal_open_infra_sandboxes _
         | Update_nav.Pal_open_setting _
         | Update_nav.Pal_slash_spec _ ->
             false)
       pal_entries);

  (* Capability matrix truth across SU & MA sessions *)
  let check_matrix label sess ~rd ~wr ~ad ~trd ~tad ~own ~keeper =
    let cm = Rbac.capability_matrix_of_session sess in
    Alcotest.(check bool) (label ^ " can_read") rd cm.can_read;
    Alcotest.(check bool) (label ^ " can_write") wr cm.can_write;
    Alcotest.(check bool) (label ^ " can_admin") ad cm.can_admin;
    Alcotest.(check bool) (label ^ " can_token_read") trd cm.can_token_read;
    Alcotest.(check bool) (label ^ " can_token_admin") tad cm.can_token_admin;
    Alcotest.(check bool) (label ^ " can_manage_own_provider") own
      cm.can_manage_own_provider;
    Alcotest.(check bool) (label ^ " can_manage_own_keeper") keeper
      cm.can_manage_own_keeper
  in
  check_matrix "SU token admin" su_token_admin
    ~rd:true ~wr:true ~ad:true ~trd:true ~tad:true ~own:true ~keeper:false;
  check_matrix "SU optional-token admin" su_optional_token_admin
    ~rd:true ~wr:true ~ad:false ~trd:false ~tad:false ~own:false ~keeper:false;
  check_matrix "MA human admin session" ma_human_admin_session
    ~rd:true ~wr:false ~ad:true ~trd:false ~tad:false ~own:true ~keeper:true;
  check_matrix "MA human admin PAT" ma_human_admin_pat
    ~rd:true ~wr:false ~ad:false ~trd:false ~tad:false ~own:true ~keeper:true;
  check_matrix "MA human worker PAT" ma_human_worker_pat
    ~rd:true ~wr:false ~ad:false ~trd:false ~tad:false ~own:true ~keeper:true;
  check_matrix "MA service worker" ma_service_worker
    ~rd:true ~wr:false ~ad:false ~trd:false ~tad:false ~own:false ~keeper:false;
  check_matrix "MA signed out" ma_signed_out
    ~rd:false ~wr:false ~ad:false ~trd:false ~tad:false ~own:false ~keeper:false;

  (* Rendered Account overlay displays mode, principal, binding, role, all 6 capabilities, and scrubbed error *)
  let su_with_err =
    Rbac.Single_user_local
      {
        auth_methods = Rbac.default_auth_methods;
        auth_enabled = true;
        require_token = false;
        token_present = true;
        token_valid = false;
        effective_agent = Some "local-op";
        role = Rbac.Worker;
        effective_admin = false;
        can_keeper_msg = true;
        auth_error_code = Some "invalid_token";
        auth_error_detail = Some "Invalid credential bearer_secret_xyz";
      }
  in
  let m_su_err =
    let b = Model.initial ~lang:Say.Lang_en ~auth_session:su_with_err () in
    { b with nav = { b.nav with overlay = Some Nav.Account } }
  in
  let txt_su = render_full_frame m_su_err in
  Alcotest.(check bool) "SU Account with invalid token renders Single_user, principal, binding=none, role"
    true
    (contains_ci ~needle:"Single_user" txt_su
     && contains_ci ~needle:"local-op" txt_su
     && contains_ci ~needle:"Binding: none" txt_su
     && contains_ci ~needle:"worker" txt_su);
  let m_su_valid =
    let b = Model.initial ~lang:Say.Lang_en ~auth_session:su_token_admin () in
    { b with nav = { b.nav with overlay = Some Nav.Account } }
  in
  let txt_su_valid = render_full_frame m_su_valid in
  Alcotest.(check bool) "SU Account with valid token renders Binding: dev_token and admin"
    true
    (contains_ci ~needle:"Binding: dev_token" txt_su_valid
     && contains_ci ~needle:"Role: admin" txt_su_valid);
  Alcotest.(check bool) "SU Account renders all 6 capability keys" true
    (List.for_all
       (fun k -> contains_ci ~needle:k txt_su)
       [
         "can_read";
         "can_write";
         "can_admin";
         "can_token_read";
         "can_token_admin";
         "can_manage_own_provider";
         "can_manage_own_keeper";
       ]);
  Alcotest.(check bool) "SU Account renders auth error detail" true
    (contains_ci ~needle:"Auth error:" txt_su);
  Alcotest.(check bool) "SU Account footer includes [t] Token & [c] Clear" true
    (contains_ci ~needle:"Token" txt_su && contains_ci ~needle:"Clear" txt_su);

  let m_ma_pat =
    let b = Model.initial ~lang:Say.Lang_en ~auth_session:ma_human_worker_pat () in
    { b with nav = { b.nav with overlay = Some Nav.Account } }
  in
  let txt_ma = render_full_frame m_ma_pat in
  Alcotest.(check bool) "MA Account renders Multi_account, usr-worker, pat (pat-2)"
    true
    (contains_ci ~needle:"Multi_account" txt_ma
     && contains_ci ~needle:"usr-worker" txt_ma
     && contains_ci ~needle:"pat (pat-2)" txt_ma);

  (* Keymap Help (? overlay) documents Account/Session shortcut truthfully *)
  let m_help, _ =
    Update.step ~now:t0 m_ma_pat (Msg.Key_event (char_key "?"))
  in
  Alcotest.(check bool) "? from Account opens Help with return_overlay=Account"
    true
    (Option.equal Nav.equal_overlay m_help.nav.overlay (Some Nav.Help)
     && Option.equal Nav.equal_overlay m_help.nav.return_overlay
          (Some Nav.Account));
  let help_txt = render_full_frame m_help in
  Alcotest.(check bool) "Help overlay lists /account shortcut" true
    (contains_ci ~needle:"/account" help_txt)

(* 6. Runtime Token / PAT Entry, Rotation, Clear, Masking & Re-bootstrap *)
let test_runtime_token_swap_and_redaction () =
  let secret_tok = "masc_pat_ULTRA_SECRET_TOKEN_987654" in
  let check_no_leak label (m : Model.t) =
    let frame = render_full_frame m in
    Alcotest.(check bool) (label ^ ": zero plaintext token in rendered grid")
      false (contains_ci ~needle:"ULTRA_SECRET_TOKEN" frame);
    let toast_s =
      match m.toast with
      | Some t -> Say.resolve Say.Lang_en t.message
      | None -> ""
    in
    Alcotest.(check bool) (label ^ ": zero plaintext token in toast") false
      (contains_ci ~needle:"ULTRA_SECRET_TOKEN" toast_s);
    Alcotest.(check bool) (label ^ ": zero plaintext token in incidents") false
      (List.exists
         (fun (inc : Health.incident) ->
           contains_ci ~needle:"ULTRA_SECRET_TOKEN" inc.detail)
         m.incidents.entries)
  in

  (* A. Auth_gate runtime token entry + paste + masking + cancel wipe + submit re-bootstrap *)
  let m_gate =
    let b = Model.initial ~lang:Say.Lang_en ~auth_session:ma_signed_out () in
    {
      b with
      nav = { b.nav with overlay = Some (Nav.System_gate Nav.Auth_gate) };
      infra =
        {
          b.infra with
          sandboxes = Observed.value ~observed_at:t0 (empty_sandboxes_snapshot ());
        };
    }
  in
  let m_edit, _ = Update.step ~now:t0 m_gate (Msg.Key_event (char_key "t")) in
  Alcotest.(check bool) "Auth_gate 't' activates masked token editor" true
    m_edit.account.token_editor.active;
  let m_pasted, _ =
    Update.step ~now:t0 m_edit (Msg.Paste_text (secret_tok ^ "\r\n"))
  in
  Alcotest.(check string) "Paste strips CR/LF" secret_tok
    m_pasted.account.token_editor.draft;
  Alcotest.(check bool) "masked_draft_display hides plaintext and shows count"
    true
    (contains_ci ~needle:"(34)"
       (Account_store.masked_draft_display m_pasted.account.token_editor)
     && not
          (contains_ci ~needle:"ULTRA_SECRET"
             (Account_store.masked_draft_display m_pasted.account.token_editor)));
  check_no_leak "Auth_gate editing" m_pasted;
  (* Esc cancels editor and wipes draft while staying on Auth_gate *)
  let m_cancel, _ =
    Update.step ~now:t0 m_pasted
      (Msg.Key_event { key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Auth_gate Esc cancels editor & wipes draft" true
    ((not m_cancel.account.token_editor.active)
     && String.equal m_cancel.account.token_editor.draft ""
     && Option.equal Nav.equal_overlay m_cancel.nav.overlay
          (Some (Nav.System_gate Nav.Auth_gate)));

  (* Blank Enter shows inline error without emitting cmds *)
  let m_edit2, _ = Update.step ~now:t0 m_cancel (Msg.Key_event (char_key "t")) in
  let m_blank_err, cmds_blank =
    Update.step ~now:t0 m_edit2
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Blank token submit keeps editor open with error" true
    (m_blank_err.account.token_editor.active
     && Option.is_some m_blank_err.account.token_editor.error
     && cmds_blank = []);

  (* Submit valid token on Auth_gate -> Set_bearer_token, purge, epoch bump, Get_health *)
  let m_typed, _ =
    Update.step ~now:t0 m_edit2 (Msg.Paste_text secret_tok)
  in
  let m_swapped, cmds_swap =
    Update.step ~now:t0 m_typed
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  let flat_swap = Cmd.flatten cmds_swap in
  Alcotest.(check bool) "Submit wipes draft & marks Token_runtime_set" true
    ((not m_swapped.account.token_editor.active)
     && String.equal m_swapped.account.token_editor.draft ""
     && Account_store.equal_token_source m_swapped.account.token_source
          Account_store.Token_runtime_set);
  Alcotest.(check bool) "Submit bumps epoch & resets auth_session to Probing_health"
    true
    ((not (Epoch.equal m_gate.epoch m_swapped.epoch))
     && Rbac.equal_auth_session m_swapped.auth_session Rbac.Probing_health);
  Alcotest.(check bool) "Submit purges cached sandboxes" true
    (Option.is_none (Observed.to_option m_swapped.infra.sandboxes));
  Alcotest.(check bool) "Submit emits Set_bearer_token (Some secret_tok)" true
    (List.exists
       (function
         | Cmd.Set_bearer_token (Some tok) -> String.equal tok secret_tok
         | _ -> false)
       flat_swap);
  Alcotest.(check bool) "Submit clears workspace guard, syncs empty streams, probes Get_health"
    true
    (List.exists
       (function
         | Cmd.Update_workspace_guard { instance_id = None; workspace_sha256 = None } ->
             true
         | _ -> false)
       flat_swap
     && List.exists
          (function Cmd.Sync_streams { streams = []; _ } -> true | _ -> false)
          flat_swap
     && List.exists
          (function Cmd.Http_get { req = Cmd.Get_health; _ } -> true | _ -> false)
          flat_swap);
  check_no_leak "Auth_gate post-submit" m_swapped;

  (* B. Account overlay runtime clear ('c') requires 2-step confirmation + Esc cancel + '[f]' File/Env revert *)
  let sample_pa : Wire_account.provider_accounts_snapshot =
    {
      provider_accounts =
        [
          {
            provider_account_id = "pa-1";
            integration_id = "anthropic";
            kind = Wire_account.Provider_key Wire_account.Key_readable;
            removal = None;
            replacement = None;
          };
        ];
      runtimes = [];
    }
  in
  let m_acct =
    let b = Model.initial ~lang:Say.Lang_en ~auth_session:ma_human_worker_pat () in
    {
      b with
      nav = { b.nav with overlay = Some Nav.Account };
      account = Account_store.apply_provider_accounts ~observed_at:t0 sample_pa b.account;
    }
  in
  (* First 'c' arms confirmation without clearing token *)
  let m_armed, cmds_arm =
    Update.step ~now:t1 m_acct (Msg.Key_event (char_key "c"))
  in
  Alcotest.(check bool) "first 'c' arms clear_token_armed without emitting commands"
    true
    (m_armed.account.clear_token_armed
     && cmds_arm = []
     && Option.is_some (Observed.to_option m_armed.account.provider_accounts));
  let txt_armed = render_full_frame m_armed in
  Alcotest.(check bool) "armed Account overlay displays confirm prompt" true
    (contains_ci ~needle:"Press [c] again to clear token" txt_armed);
  (* Esc disarms clear_token_armed without closing Account overlay *)
  let m_cancelled, cmds_cancel =
    Update.step ~now:t1 m_armed
      (Msg.Key_event { key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Esc disarms clear_token_armed and keeps Account overlay open"
    true
    ((not m_cancelled.account.clear_token_armed)
     && cmds_cancel = []
     && Option.equal Nav.equal_overlay m_cancelled.nav.overlay (Some Nav.Account));
  (* 'c' then 'c' clears token + purges own-provider cache *)
  let m_armed2, _ =
    Update.step ~now:t1 m_cancelled (Msg.Key_event (char_key "c"))
  in
  let m_cleared, cmds_clear =
    Update.step ~now:t1 m_armed2 (Msg.Key_event (char_key "c"))
  in
  let flat_clear = Cmd.flatten cmds_clear in
  Alcotest.(check bool) "2nd 'c' marks Token_runtime_cleared & purges own-provider cache"
    true
    ((not m_cleared.account.clear_token_armed)
     && Account_store.equal_token_source m_cleared.account.token_source
          Account_store.Token_runtime_cleared
     && Option.is_none (Observed.to_option m_cleared.account.provider_accounts));
  Alcotest.(check bool) "2nd 'c' emits Set_bearer_token None + Get_health" true
    (List.exists
       (function Cmd.Set_bearer_token None -> true | _ -> false)
       flat_clear
     && List.exists
          (function Cmd.Http_get { req = Cmd.Get_health; _ } -> true | _ -> false)
          flat_clear);
  (* '[f]' reverts to default File/Env token with epoch bump and Reset_bearer_token_to_default *)
  let m_reverted, cmds_revert =
    Update.step ~now:t1 m_cleared (Msg.Key_event (char_key "f"))
  in
  let flat_revert = Cmd.flatten cmds_revert in
  Alcotest.(check bool) "'f' reverts token_source to Token_startup_default and bumps epoch"
    true
    (Account_store.equal_token_source m_reverted.account.token_source
       Account_store.Token_startup_default
     && not (Epoch.equal m_cleared.epoch m_reverted.epoch));
  Alcotest.(check bool) "'f' emits Reset_bearer_token_to_default + Get_health" true
    (List.exists
       (function Cmd.Reset_bearer_token_to_default -> true | _ -> false)
       flat_revert
     && List.exists
          (function Cmd.Http_get { req = Cmd.Get_health; _ } -> true | _ -> false)
          flat_revert)

(* 7. Multi-Account Own-Provider Decoders (Strict Fail-Closed) & RBAC/Action Flows *)
let test_ma_own_provider_wire_and_actions () =
  (* Strict Wire_account decoders: happy paths *)
  let pa_json =
    Yojson.Safe.from_string
      {|{
        "provider_accounts": [
          {"provider_account_id":"pa-login-1","integration_id":"claude","kind":"login"},
          {"provider_account_id":"pa-key-1","integration_id":"anthropic","kind":"key","key":"readable","replacement":"start_given_up"}
        ],
        "runtimes": [
          {"runtime_id":"rt-1","provider_account_id":"pa-login-1","model":"claude-sonnet-4-6"},
          {"runtime_id":"rt-2","provider_account_id":"pa-key-1","model":null,"unread":"key_missing"}
        ]
      }|}
  in
  let pa_snap =
    match Wire_account.decode_provider_accounts_snapshot pa_json with
    | Ok s -> s
    | Error e -> Alcotest.fail ("valid provider_accounts failed: " ^ e)
  in
  Alcotest.(check int) "2 provider_accounts decoded" 2
    (List.length pa_snap.provider_accounts);
  Alcotest.(check int) "2 runtimes decoded" 2 (List.length pa_snap.runtimes);

  let int_json =
    Yojson.Safe.from_string
      {|{
        "integrations": [
          {"integration_id":"claude","display_name":"Claude","connect":["login"],"models":["claude-sonnet-4-6"],"withheld":[{"model":"claude-opus-4","reason":"not_supported"}],"calls":"refused","refusal":"native_tools_reach_other_homes"},
          {"integration_id":"anthropic","display_name":"Anthropic","connect":["key"],"models":["claude-sonnet-4-6"],"withheld":[],"calls":"allowed"}
        ]
      }|}
  in
  let int_snap =
    match Wire_account.decode_person_integrations_snapshot int_json with
    | Ok s -> s
    | Error e -> Alcotest.fail ("valid integrations failed: " ^ e)
  in
  Alcotest.(check int) "2 integrations decoded" 2
    (List.length int_snap.integrations);

  let ver_json =
    Yojson.Safe.from_string
      {|{
        "verification": {
          "schema": "masc.runtime_verification.v1",
          "runtime_id": "rt-2",
          "model": "claude-sonnet-4-6",
          "observed_model": "claude-sonnet-4-6",
          "status": "verified",
          "checks": {"response": true, "tool_called": true, "tool_roundtrip": true},
          "failure": null
        },
        "runtime": {"runtime_id": "rt-2", "record": "made"}
      }|}
  in
  (match Wire_account.decode_account_verify_response ver_json with
  | Ok resp ->
      Alcotest.(check bool) "verify status = verified" true
        (Wire_account.equal_verification_status resp.verification.status
           Wire_account.Verify_verified)
  | Error e -> Alcotest.fail ("valid verify response failed: " ^ e));

  (* Strict fail-closed rejections *)
  let bad_pa_cases =
    [
      ("non-object root", `List []);
      ("non-array provider_accounts", Yojson.Safe.from_string {|{"provider_accounts":{},"runtimes":[]}|});
      ("login with key field", Yojson.Safe.from_string {|{"provider_accounts":[{"provider_account_id":"a","integration_id":"claude","kind":"login","key":"readable"}],"runtimes":[]}|});
      ("key without key field", Yojson.Safe.from_string {|{"provider_accounts":[{"provider_account_id":"a","integration_id":"anthropic","kind":"key"}],"runtimes":[]}|});
      ("unknown key enum", Yojson.Safe.from_string {|{"provider_accounts":[{"provider_account_id":"a","integration_id":"anthropic","kind":"key","key":"bogus"}],"runtimes":[]}|});
      ("null model missing unread", Yojson.Safe.from_string {|{"provider_accounts":[],"runtimes":[{"runtime_id":"r","provider_account_id":"a","model":null}]}|});
      ("present model with unread", Yojson.Safe.from_string {|{"provider_accounts":[],"runtimes":[{"runtime_id":"r","provider_account_id":"a","model":"m1","unread":"key_missing"}]}|});
    ]
  in
  List.iter
    (fun (lbl, j) ->
      Alcotest.(check bool) ("reject bad provider_accounts: " ^ lbl) true
        (Result.is_error (Wire_account.decode_provider_accounts_snapshot j)))
    bad_pa_cases;

  let bad_int_cases =
    [
      ("refused missing refusal", Yojson.Safe.from_string {|{"integrations":[{"integration_id":"claude","display_name":"Claude","connect":["login"],"models":[],"withheld":[],"calls":"refused"}]}|});
      ("allowed with refusal", Yojson.Safe.from_string {|{"integrations":[{"integration_id":"claude","display_name":"Claude","connect":["login"],"models":[],"withheld":[],"calls":"allowed","refusal":"native_unpublished"}]}|});
      ("unknown connect method", Yojson.Safe.from_string {|{"integrations":[{"integration_id":"claude","display_name":"Claude","connect":["oauth"],"models":[],"withheld":[],"calls":"allowed"}]}|});
    ]
  in
  List.iter
    (fun (lbl, j) ->
      Alcotest.(check bool) ("reject bad integrations: " ^ lbl) true
        (Result.is_error (Wire_account.decode_person_integrations_snapshot j)))
    bad_int_cases;

  Alcotest.(check bool) "reject wrong verification schema" true
    (Result.is_error
       (Wire_account.decode_account_verify_response
          (Yojson.Safe.from_string
             {|{"verification":{"schema":"wrong.v0","runtime_id":"r","model":null,"observed_model":null,"status":"failed","checks":{"response":false,"tool_called":false,"tool_roundtrip":false},"failure":null},"runtime":null}|})));
  Alcotest.(check bool) "reject removed=false on key remove" true
    (Result.is_error
       (Wire_account.decode_key_remove_response
          (Yojson.Safe.from_string {|{"provider_account_id":"pa-1","removed":false}|})));

  (* Zero MA own-provider fetches in Single_user mode *)
  let m_su = Model.initial ~lang:Say.Lang_en ~auth_session:su_token_admin () in
  let _, su_cmds = Update.step ~now:t0 m_su (Msg.Key_event (char_key "@")) in
  Alcotest.(check bool) "Single_user opening Account emits ZERO MA own-provider GETs"
    false
    (List.exists
       (function
         | Cmd.Http_get
             { req = Cmd.Get_auth_provider_accounts | Cmd.Get_auth_integrations; _ } ->
             true
         | _ -> false)
       (Cmd.flatten su_cmds));

  (* Multi-Account Human Worker PAT opening Account fetches MA endpoints & ZERO SU setup_inventory *)
  let m_ma0 =
    Model.initial ~lang:Say.Lang_en ~auth_session:ma_human_worker_pat ()
  in
  let m_ma_open, ma_cmds =
    Update.step ~now:t0 m_ma0 (Msg.Key_event (char_key "@"))
  in
  let flat_ma = Cmd.flatten ma_cmds in
  Alcotest.(check bool) "MA opening Account fetches /api/v1/auth/provider-accounts & /integrations"
    true
    (List.exists
       (function Cmd.Http_get { req = Cmd.Get_auth_provider_accounts; _ } -> true | _ -> false)
       flat_ma
     && List.exists
          (function Cmd.Http_get { req = Cmd.Get_auth_integrations; _ } -> true | _ -> false)
          flat_ma);
  Alcotest.(check bool) "MA opening Account NEVER fetches SU /api/v1/setup/inventory"
    false
    (List.exists
       (function Cmd.Http_get { req = Cmd.Get_setup_inventory; _ } -> true | _ -> false)
       flat_ma);

  (* HTTP 403 on /provider-accounts keeps MA session signed in, displays 403, and halts auto-refetch *)
  let m_403, cmds_403 =
    Update.step ~now:t0 m_ma_open
      (Msg.Http_reply
         {
           epoch = m_ma_open.epoch;
           reply =
             Msg.Reply_auth_provider_accounts
               (Error
                  (Msg.Http_error
                     {
                       status = 403;
                       body = {|{"error":"missing manage_own_provider scope"}|};
                       api_error = None;
                     }));
         })
  in
  Alcotest.(check bool) "HTTP 403 keeps MA session signed in (no Auth_gate, no recheck loop)"
    true
    (Rbac.is_authenticated m_403.auth_session
     && Option.equal Nav.equal_overlay m_403.nav.overlay (Some Nav.Account)
     && cmds_403 = []
     && Option.is_some m_403.account.own_provider_forbidden);
  let is_ma_own_provider_get = function
    | Cmd.Http_get
        { req = Cmd.Get_auth_provider_accounts | Cmd.Get_auth_integrations; _ } ->
        true
    | _ -> false
  in
  Alcotest.(check bool) "HTTP 403 halts own-provider View_fetches retries until manual refresh"
    false
    (List.exists is_ma_own_provider_get
       (Cmd.flatten (View_fetches.fetches_for_current_view m_403)));
  Alcotest.(check bool) "Manual refresh (~force:true) re-attempts own-provider fetch after 403"
    true
    (List.exists is_ma_own_provider_get
       (Cmd.flatten (View_fetches.fetches_for_current_view ~force:true m_403)));
  let txt_403 = render_full_frame m_403 in
  Alcotest.(check bool) "HTTP 403 banner rendered on Account overlay" true
    (contains_ci ~needle:"HTTP 403" txt_403
     && contains_ci ~needle:"manage_own_provider" txt_403);

  (* Loaded MA own-provider data + scope honesty + login/key/verify actions *)
  let m_loaded =
    let m1, _ =
      Update.step ~now:t0 m_ma_open
        (Msg.Http_reply
           { epoch = m_ma_open.epoch; reply = Msg.Reply_auth_provider_accounts (Ok pa_snap) })
    in
    let m2, _ =
      Update.step ~now:t0 m1
        (Msg.Http_reply
           { epoch = m1.epoch; reply = Msg.Reply_auth_integrations (Ok int_snap) })
    in
    m2
  in
  let txt_loaded = render_full_frame m_loaded in
  Alcotest.(check bool) "MA Account renders refusal & withheld scope honesty + provider accounts"
    true
    (contains_ci ~needle:"calls=refused(native_tools_reach_other_homes)" txt_loaded
     && contains_ci ~needle:"withheld:claude-opus-4" txt_loaded
     && contains_ci ~needle:"pa-login-1" txt_loaded
     && contains_ci ~needle:"pa-key-1" txt_loaded);

  (* 'l' opens Ma_provider_login_form -> Enter submits Post_setup_login_start with account_ref=None *)
  let m_login_modal, _ =
    Update.step ~now:t0 m_loaded (Msg.Key_event (char_key "l"))
  in
  let m_login_done, cmds_login =
    Update.step ~now:t0 m_login_modal
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "MA CLI login submits account_ref=None and returns to Account overlay"
    true
    (Option.equal Nav.equal_overlay m_login_done.nav.overlay (Some Nav.Account)
     && List.exists
          (function
            | Cmd.Http_post
                {
                  req =
                    Cmd.Post_setup_login_start
                      { integration_id = "claude"; account_ref = None };
                  _;
                } ->
                true
            | _ -> false)
          (Cmd.flatten cmds_login));

  (* 'u' on login account (index 0) refuses rotation; 'j' selects key account (index 1), 'u' opens replace modal *)
  let m_rot_login, _ =
    Update.step ~now:t0 m_loaded (Msg.Key_event (char_key "u"))
  in
  Alcotest.(check bool) "'u' on login account keeps Account overlay with warning"
    true
    (Option.equal Nav.equal_overlay m_rot_login.nav.overlay (Some Nav.Account));
  let m_sel_key, _ =
    Update.step ~now:t0 m_loaded (Msg.Key_event (char_key "j"))
  in
  let m_verify_modal, _ =
    Update.step ~now:t0 m_sel_key (Msg.Key_event (char_key "v"))
  in
  let m_verify_sent, cmds_verify =
    Update.step ~now:t0 m_verify_modal
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "'v' verifies selected account with exact provider_account_id & prefilled model"
    true
    (Option.equal Nav.equal_overlay m_verify_sent.nav.overlay (Some Nav.Account)
     && List.exists
          (function
            | Cmd.Http_post
                {
                  req =
                    Cmd.Post_setup_account_verify
                      {
                        provider_account_id = "pa-key-1";
                        model = "claude-sonnet-4-6";
                      };
                  _;
                } ->
                true
            | _ -> false)
          (Cmd.flatten cmds_verify));

  (* 'K' key registration uses MA /api/v1/setup/accounts/key (NEVER SU /api/v1/setup/credential) *)
  let m_key_modal, _ =
    Update.step ~now:t0 m_sel_key (Msg.Key_event (char_key "K"))
  in
  let m_key_tab, _ =
    Update.step ~now:t0 m_key_modal
      (Msg.Key_event { key = Keymap.Input.Tab; mods = Keymap.Input.no_mods })
  in
  let m_key_pasted, _ =
    Update.step ~now:t0 m_key_tab (Msg.Paste_text "sk-ant-SECRETKEY-99")
  in
  let m_key_sent, cmds_key =
    Update.step ~now:t0 m_key_pasted
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "'K' posts to /api/v1/setup/accounts/key without leaking key in toast"
    true
    (List.exists
       (function
         | Cmd.Http_post
             {
               req =
                 Cmd.Post_ma_setup_account_key
                   { integration_id = "anthropic"; key = "sk-ant-SECRETKEY-99" } as req;
               _;
             } ->
             String.equal (Cmd.post_request_path req) "/api/v1/setup/accounts/key"
         | _ -> false)
       (Cmd.flatten cmds_key)
     && not
          (match m_key_sent.toast with
          | Some t -> contains_ci ~needle:"SECRETKEY" (Say.resolve Say.Lang_en t.message)
          | None -> false));

  (* #55063 P3-2: Key CRUD Decode_error still reports incident/toast AND triggers Get_auth_provider_accounts refresh *)
  let check_key_decode_refresh label reply =
    let m_err, cmds_err =
      Update.step ~now:t0 m_loaded
        (Msg.Http_reply { epoch = m_loaded.epoch; reply })
    in
    Alcotest.(check bool) (label ^ " records incident + refreshes provider accounts")
      true
      (List.length m_err.incidents.entries > List.length m_loaded.incidents.entries
       && Option.is_some m_err.toast
       && List.exists
            (function
              | Cmd.Http_get { req = Cmd.Get_auth_provider_accounts; _ } -> true
              | _ -> false)
            (Cmd.flatten cmds_err))
  in
  check_key_decode_refresh "key register Decode_error"
    (Msg.Reply_ma_setup_account_key_register
       { integration_id = "anthropic"; result = Error (Msg.Decode_error "truncated") });
  check_key_decode_refresh "key replace Decode_error"
    (Msg.Reply_ma_setup_account_key_replace
       { provider_account_id = "pa-key-1"; result = Error (Msg.Decode_error "truncated") });
  check_key_decode_refresh "key remove Decode_error"
    (Msg.Reply_ma_setup_account_key_remove
       { provider_account_id = "pa-key-1"; result = Error (Msg.Decode_error "truncated") });

  (* #55063 P3-3 + P2-5: initial load failure scrubs secrets in Observed.Failed
     AND transient refresh failure on already-loaded slot retains stale Value *)
  let m_unloaded_acct =
    let m0 =
      Model.initial ~auth_session:m_loaded.auth_session ~cols:120 ~rows:36
        ~lang:Say.Lang_en ()
    in
    fst (Update_nav.open_overlay m0 Nav.Account)
  in
  let m_scrub_pa, _ =
    Update.step ~now:t0 m_unloaded_acct
      (Msg.Http_reply
         {
           epoch = m_unloaded_acct.epoch;
           reply =
             Msg.Reply_auth_provider_accounts
               (Error
                  (Msg.Http_error
                     {
                       status = 500;
                       body = "upstream failed with sk-ant-api03-LEAKED9999999999 token";
                       api_error = None;
                     }));
         })
  in
  let m_scrub_both, _ =
    Update.step ~now:t0 m_scrub_pa
      (Msg.Http_reply
         {
           epoch = m_scrub_pa.epoch;
           reply =
             Msg.Reply_auth_integrations
               (Error
                  (Msg.Http_error
                     {
                       status = 500;
                       body = "bad bearer sk-proj-SHOULDNOTSHOW88888888";
                       api_error = None;
                     }));
         })
  in
  Alcotest.(check bool) "unloaded provider_accounts failure lands scrubbed Observed.Failed"
    true
    (match m_scrub_both.account.provider_accounts with
    | Observed.Failed { reason; _ } -> not (contains_ci ~needle:"LEAKED9999999999" reason)
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported -> false);
  Alcotest.(check bool) "unloaded integrations failure lands scrubbed Observed.Failed"
    true
    (match m_scrub_both.account.integrations with
    | Observed.Failed { reason; _ } -> not (contains_ci ~needle:"SHOULDNOTSHOW88888888" reason)
    | Observed.Value _ | Observed.Loading _ | Observed.Absent | Observed.Unreported -> false);
  let txt_scrub = render_full_frame m_scrub_both in
  Alcotest.(check bool) "Account overlay scrubs secrets in provider_accounts & integrations errors"
    true
    ((not (contains_ci ~needle:"LEAKED9999999999" txt_scrub))
     && not (contains_ci ~needle:"SHOULDNOTSHOW88888888" txt_scrub));

  let t1 = Clock.Mono.of_ns 12_000_000_000L in
  let m_stale_pa, _ =
    Update.step ~now:t1 m_loaded
      (Msg.Http_reply
         {
           epoch = m_loaded.epoch;
           reply =
             Msg.Reply_auth_provider_accounts
               (Error (Msg.Transport Health.Timeout));
         })
  in
  let m_stale_int, _ =
    Update.step ~now:t1 m_stale_pa
      (Msg.Http_reply
         {
           epoch = m_stale_pa.epoch;
           reply =
             Msg.Reply_auth_integrations
               (Error (Msg.Transport Health.Timeout));
         })
  in
  Alcotest.(check bool) "transient refresh failure retains stale provider_accounts Value"
    true
    (match m_stale_int.account.provider_accounts with
    | Observed.Value { stale = true; _ } -> true
    | Observed.Value { stale = false; _ }
    | Observed.Loading _ | Observed.Failed _ | Observed.Absent | Observed.Unreported -> false);
  Alcotest.(check bool) "transient refresh failure retains stale integrations Value"
    true
    (match m_stale_int.account.integrations with
    | Observed.Value { stale = true; _ } -> true
    | Observed.Value { stale = false; _ }
    | Observed.Loading _ | Observed.Failed _ | Observed.Absent | Observed.Unreported -> false);

  (* P2-3: Account clear_token_armed disarms on unhandled/global keys, overlay close & mouse *)
  let m_acct_arm, _ =
    Update.step ~now:t1 m_loaded (Msg.Key_event (char_key "c"))
  in
  Alcotest.(check bool) "Account [c] arms clear_token_armed" true
    m_acct_arm.account.clear_token_armed;
  let m_acct_alt_a, _ =
    Update.step ~now:t1 m_acct_arm
      (Msg.Key_event
         {
           Keymap.Input.key = Keymap.Input.Char "a";
           mods = { Keymap.Input.no_mods with alt = true };
         })
  in
  Alcotest.(check bool) "Account [c] then Alt+A disarms clear_token_armed" false
    m_acct_alt_a.account.clear_token_armed;
  let m_acct_reopen, _ =
    Update.step ~now:t1 m_acct_alt_a (Msg.Key_event (char_key "@"))
  in
  let m_acct_c_again, cmds_c_again =
    Update.step ~now:t1 m_acct_reopen (Msg.Key_event (char_key "c"))
  in
  Alcotest.(check bool) "reopened Account single [c] arms fresh instead of clearing"
    true
    (m_acct_c_again.account.clear_token_armed && cmds_c_again = []);
  let m_acct_mouse, _ =
    Update.step ~now:t1 m_acct_c_again
      (Msg.Mouse_event
         (Keymap.Input.Wheel { dir = Keymap.Input.Wheel_down; col = 10; row = 10 }))
  in
  Alcotest.(check bool) "mouse event disarms Account clear_token_armed" false
    m_acct_mouse.account.clear_token_armed;

  (* #55063 P3-4: Reject empty/whitespace integration ID or API key before submitting MA key modal *)
  let m_blank_add, _ =
    Update.step ~now:t0 m_sel_key (Msg.Key_event (char_key "K"))
  in
  let m_blank_add_ws =
    match m_blank_add.inline_modal with
    | Some md ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) -> { f with value = "   " })
            md.fields
        in
        { m_blank_add with inline_modal = Some { md with fields } }
    | None -> Alcotest.fail "expected Ma_provider_key_add_form modal"
  in
  let m_blank_add_res, cmds_blank_add =
    Update.step ~now:t0 m_blank_add_ws
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "whitespace key add rejected inline with zero HTTP cmds"
    true
    (cmds_blank_add = []
     &&
     match m_blank_add_res.inline_modal with
     | Some { error = Some _; _ } -> true
     | Some _ | None -> false);
  let m_blank_rep, _ =
    Update.step ~now:t0 m_sel_key (Msg.Key_event (char_key "u"))
  in
  let m_blank_rep_ws, _ =
    Update.step ~now:t0 m_blank_rep (Msg.Paste_text "   \t  ")
  in
  let m_blank_rep_res, cmds_blank_rep =
    Update.step ~now:t0 m_blank_rep_ws
      (Msg.Key_event { key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "whitespace key replace rejected inline with zero HTTP cmds"
    true
    (cmds_blank_rep = []
     &&
     match m_blank_rep_res.inline_modal with
     | Some { error = Some _; _ } -> true
     | Some _ | None -> false)

(* 8. Multi-Account Personal Keepers (/api/v1/auth/keepers) Wire, Validation, Lifecycle & 403/503 *)
let test_ma_personal_keepers_wire_and_lifecycle () =
  let t0 = Clock.Mono.of_ns 10_000_000_000L in
  let t1 = Clock.Mono.of_ns 12_000_000_000L in

  (* A. Strict client-side validators matching server rules *)
  Alcotest.(check bool) "valid keeper_id accepted" true
    (Result.is_ok (Wire_personal_keepers.validate_keeper_id "my-keeper_1.2"));
  List.iter
    (fun bad ->
      Alcotest.(check bool) (Printf.sprintf "rejects invalid keeper_id %S" bad)
        true (Result.is_error (Wire_personal_keepers.validate_keeper_id bad)))
    [
      "";
      "   ";
      ".";
      "..";
      "a/b";
      "bad space";
      "MyKeeper";
      String.make 129 'k';
      "tool_usage";
      ".shutdown-operations";
      ".configuration-removals";
    ];
  Alcotest.(check bool) "valid turn message accepted" true
    (Result.is_ok (Wire_personal_keepers.validate_turn_message "hello keeper"));
  Alcotest.(check bool) "blank turn message rejected" true
    (match Wire_personal_keepers.validate_turn_message "  \n\t " with
    | Error Wire_personal_keepers.Message_blank -> true
    | Ok _ | Error (Wire_personal_keepers.Message_too_long _) -> false);
  Alcotest.(check bool) "4097B turn message rejected" true
    (match Wire_personal_keepers.validate_turn_message (String.make 4097 'a') with
    | Error (Wire_personal_keepers.Message_too_long { bytes = 4097; max_bytes = 4096 }) ->
        true
    | Ok _ | Error _ -> false);

  (* B. Strict key order on POST /api/v1/auth/keepers/assign *)
  let assign_str =
    Yojson.Safe.to_string
      (Wire_personal_keepers.encode_assign_keeper ~keeper_id:"alpha"
         ~runtime_id:"rt-1")
  in
  Alcotest.(check string) "assign JSON preserves exact keeper_id-then-runtime_id order"
    {|{"keeper_id":"alpha","runtime_id":"rt-1"}|} assign_str;

  (* C. Strict fail-closed decoders for all 7 endpoints *)
  let keepers_ok =
    Wire_personal_keepers.decode_keepers_list
      (Yojson.Safe.from_string
         {|{"keepers":[{"keeper_id":"k1","runtime_id":"rt-1"},{"keeper_id":"k2","runtime_id":null}]}|})
  in
  Alcotest.(check bool) "decode_keepers_list happy path" true
    (match keepers_ok with
    | Ok [ { keeper_id = "k1"; runtime_id = Some "rt-1" }; { keeper_id = "k2"; runtime_id = None } ] ->
        true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool) "decode_keepers_list rejects duplicate keeper_id" true
    (Result.is_error
       (Wire_personal_keepers.decode_keepers_list
          (Yojson.Safe.from_string
             {|{"keepers":[{"keeper_id":"k1","runtime_id":null},{"keeper_id":"k1","runtime_id":"rt-1"}]}|})));
  Alcotest.(check bool) "decode_made_keeper happy + mismatch rejection" true
    (Result.is_ok
       (Wire_personal_keepers.decode_made_keeper ~expected_keeper_id:"k1"
          (Yojson.Safe.from_string {|{"keeper_id":"k1","record":"made"}|}))
     && Result.is_error
          (Wire_personal_keepers.decode_made_keeper ~expected_keeper_id:"k1"
             (Yojson.Safe.from_string {|{"keeper_id":"k2","record":"made"}|})));
  Alcotest.(check bool) "decode_assigned_keeper happy + mismatch rejection" true
    (Result.is_ok
       (Wire_personal_keepers.decode_assigned_keeper ~expected_keeper_id:"k1"
          ~expected_runtime_id:"rt-1"
          (Yojson.Safe.from_string
             {|{"keeper_id":"k1","runtime_id":"rt-1","record":"assigned"}|}))
     && Result.is_error
          (Wire_personal_keepers.decode_assigned_keeper ~expected_keeper_id:"k1"
             ~expected_runtime_id:"rt-1"
             (Yojson.Safe.from_string
                {|{"keeper_id":"k1","runtime_id":"rt-other","record":"assigned"}|})));

  let conv_json =
    Yojson.Safe.from_string
      {|{
        "keeper_id":"k1",
        "current_conversation_id":"conv-1",
        "conversations":[
          {"conversation_id":"conv-1","provider_account_id":"pa-1","started_at_ms":1000},
          {"conversation_id":"conv-fail","provider_account_id":"pa-1","started_at_ms":500,"deletion":"failed"}
        ],
        "conversation_id":"conv-1",
        "turns":[
          {"message":"hi","asked_at_ms":1001,"outcome":"answered","text":"hello","model":"claude-sonnet-4-6","answered_at_ms":1005},
          {"message":"oops","asked_at_ms":1010,"outcome":"failed","failure":"no_quota","failed_at_ms":1012,"model_may_have_read":true},
          {"message":"lost","asked_at_ms":1020,"outcome":"unrecorded","model_may_have_read":true}
        ]
      }|}
  in
  let conv_snap =
    match Wire_personal_keepers.decode_conversation ~expected_keeper_id:"k1" conv_json with
    | Ok s -> s
    | Error e -> Alcotest.fail ("valid conversation failed: " ^ e)
  in
  Alcotest.(check int) "decoded 2 conversations" 2 (List.length conv_snap.conversations);
  Alcotest.(check int) "decoded 3 turns" 3 (List.length conv_snap.turns);
  Alcotest.(check bool) "rejects null conversation_id with non-empty turns" true
    (Result.is_error
       (Wire_personal_keepers.decode_conversation ~expected_keeper_id:"k1"
          (Yojson.Safe.from_string
             {|{"keeper_id":"k1","current_conversation_id":null,"conversations":[],"conversation_id":null,"turns":[{"message":"x","asked_at_ms":1,"outcome":"unrecorded","model_may_have_read":false}]}|})));
  Alcotest.(check bool) "rejects invalid deletion value" true
    (Result.is_error
       (Wire_personal_keepers.decode_conversation ~expected_keeper_id:"k1"
          (Yojson.Safe.from_string
             {|{"keeper_id":"k1","current_conversation_id":null,"conversations":[{"conversation_id":"c1","provider_account_id":"pa-1","started_at_ms":1,"deletion":"pending"}],"conversation_id":null,"turns":[]}|})));

  (* Turn answer: both recorded and ephemeral valid; unpaired fields fail closed *)
  Alcotest.(check bool) "decode_turn_answer recorded & ephemeral" true
    (Result.is_ok
       (Wire_personal_keepers.decode_turn_answer ~expected_keeper_id:"k1"
          (Yojson.Safe.from_string
             {|{"keeper_id":"k1","runtime_id":"rt-1","model":"m","text":"ok","conversation_id":"c1","continued":false}|}))
     && Result.is_ok
          (Wire_personal_keepers.decode_turn_answer ~expected_keeper_id:"k1"
             (Yojson.Safe.from_string
                {|{"keeper_id":"k1","runtime_id":"rt-1","model":"m","text":"ephemeral"}|})));
  Alcotest.(check bool) "decode_turn_answer rejects unpaired conversation_id/continued"
    true
    (Result.is_error
       (Wire_personal_keepers.decode_turn_answer ~expected_keeper_id:"k1"
          (Yojson.Safe.from_string
             {|{"keeper_id":"k1","runtime_id":"rt-1","model":"m","text":"bad","conversation_id":"c1"}|}))
     && Result.is_error
          (Wire_personal_keepers.decode_turn_answer ~expected_keeper_id:"k1"
             (Yojson.Safe.from_string
                {|{"keeper_id":"k1","runtime_id":"rt-1","model":"m","text":"bad","continued":true}|})));

  (* Deleted conversation vendor_copy states *)
  List.iter
    (fun vc ->
      let raw =
        Printf.sprintf {|{"conversation_id":"conv-1","vendor_copy":%S}|} vc
      in
      Alcotest.(check bool) ("decode_deleted_conversation " ^ vc) true
        (Result.is_ok
           (Wire_personal_keepers.decode_deleted_conversation
              ~expected_conversation_id:"conv-1"
              (Yojson.Safe.from_string raw))))
    [ "removed"; "none"; "may_remain" ];
  Alcotest.(check bool) "decode_deleted_conversation rejects unknown vendor_copy"
    true
    (Result.is_error
       (Wire_personal_keepers.decode_deleted_conversation
          ~expected_conversation_id:"conv-1"
          (Yojson.Safe.from_string
             {|{"conversation_id":"conv-1","vendor_copy":"unknown"}|})));

  (* D. Route isolation: MA Keepers emits ONLY /api/v1/auth/*, SU Keepers emits ZERO /api/v1/auth/keepers* *)
  let m_ma =
    let b =
      Model.initial ~lang:Say.Lang_en ~auth_session:ma_human_worker_pat
        ~cols:140 ~rows:40 ()
    in
    { b with nav = { b.nav with workspace = Nav.Keepers } }
  in
  let ma_paths =
    View_fetches.fetches_for_current_view m_ma
    |> Cmd.flatten
    |> List.filter_map (function
         | Cmd.Http_get { req; _ } -> Some (Cmd.get_request_path req)
         | _ -> None)
  in
  Alcotest.(check bool) "MA Keepers fetches /api/v1/auth/keepers & provider-accounts, zero SU /api/v1/keepers*"
    true
    (List.exists (String.equal "/api/v1/auth/keepers") ma_paths
     && List.exists (String.equal "/api/v1/auth/provider-accounts") ma_paths
     && List.for_all
          (fun p ->
            (not (String.starts_with ~prefix:"/api/v1/keepers" p))
            && (not (String.starts_with ~prefix:"/api/v1/gate/keepers" p))
            && not (String.starts_with ~prefix:"/api/v1/dashboard/keepers" p))
          ma_paths);
  let m_su =
    let b =
      Model.initial ~lang:Say.Lang_en ~auth_session:su_token_admin ~cols:140
        ~rows:40 ()
    in
    { b with nav = { b.nav with workspace = Nav.Keepers } }
  in
  let su_paths =
    View_fetches.fetches_for_current_view m_su
    |> Cmd.flatten
    |> List.filter_map (function
         | Cmd.Http_get { req; _ } -> Some (Cmd.get_request_path req)
         | _ -> None)
  in
  Alcotest.(check bool) "SU Keepers emits ZERO /api/v1/auth/keepers* requests"
    true
    (List.for_all
       (fun p -> not (String.starts_with ~prefix:"/api/v1/auth/keepers" p))
       su_paths);

  (* E. '[p]' shortcut from Account overlay navigates directly to MA Personal Keepers *)
  let m_acct =
    {
      (Model.initial ~lang:Say.Lang_en ~auth_session:ma_human_worker_pat
         ~cols:140 ~rows:40 ())
      with
      nav =
        {
          (Model.initial ~lang:Say.Lang_en ~auth_session:ma_human_worker_pat ()).nav
          with
          overlay = Some Nav.Account;
        };
    }
  in
  let m_from_acct, cmds_from_acct =
    Update.step ~now:t0 m_acct (Msg.Key_event (char_key "p"))
  in
  Alcotest.(check bool) "'p' in MA Account opens Keepers workspace & fetches personal keepers"
    true
    (Option.is_none m_from_acct.nav.overlay
     && Nav.equal_workspace m_from_acct.nav.workspace Nav.Keepers
     && List.exists
          (function
            | Cmd.Http_get { req = Cmd.Get_auth_keepers; _ } -> true
            | _ -> false)
          (Cmd.flatten cmds_from_acct));

  (* F. PAT 403 (Pat_scope_lacks_own_keeper): non-logout, explicit banner, zero retry storm, manual [r] clears *)
  let m_403, _ =
    Update.step ~now:t0 m_ma
      (Msg.Http_reply
         {
           epoch = m_ma.epoch;
           reply =
             Msg.Reply_auth_keepers
               (Error
                  (Msg.Http_error
                     {
                       status = 403;
                       body = {|{"error":"pat lacks manage_own_keeper"}|};
                       api_error = None;
                     }));
         })
  in
  Alcotest.(check bool) "403 own_keeper stays signed-in without Auth_gate" true
    (Rbac.is_authenticated m_403.auth_session
     && Option.is_none m_403.nav.overlay
     && Option.is_some m_403.personal_keepers.own_keeper_forbidden);
  let retry_cmds =
    View_fetches.fetches_for_current_view m_403
    |> Cmd.flatten
    |> List.filter (function
         | Cmd.Http_get { req = Cmd.Get_auth_keepers | Cmd.Get_auth_keeper_conversation _; _ } ->
             true
         | _ -> false)
  in
  Alcotest.(check int) "403 own_keeper prevents background retry storm" 0
    (List.length retry_cmds);
  let txt_403 = render_full_frame m_403 in
  Alcotest.(check bool) "403 own_keeper renders explicit manage_own_keeper banner"
    true
    (contains_ci ~needle:"HTTP 403" txt_403
     && contains_ci ~needle:"manage_own_keeper" txt_403);
  let m_refreshed, cmds_ref =
    Update.step ~now:t1 m_403 (Msg.Key_event (char_key "r"))
  in
  Alcotest.(check bool) "manual 'r' clears own_keeper_forbidden & re-fetches"
    true
    (Option.is_none m_refreshed.personal_keepers.own_keeper_forbidden
     && List.exists
          (function
            | Cmd.Http_get { req = Cmd.Get_auth_keepers; _ } -> true
            | _ -> false)
          (Cmd.flatten cmds_ref));

  (* G. Full lifecycle: load keepers + runtimes + conversation -> turn outcomes -> 2-step delete -> 503 recovery *)
  let pa_with_rt : Wire_account.provider_accounts_snapshot =
    {
      provider_accounts =
        [
          {
            provider_account_id = "pa-1";
            integration_id = "anthropic";
            kind = Wire_account.Provider_key Wire_account.Key_readable;
            removal = None;
            replacement = None;
          };
        ];
      runtimes =
        [
          {
            runtime_id = "rt-1";
            provider_account_id = "pa-1";
            model = Wire_account.Runtime_model "claude-sonnet-4-6";
          };
        ];
    }
  in
  let m_seeded =
    let m1, _ =
      Update.step ~now:t0 m_ma
        (Msg.Http_reply
           {
             epoch = m_ma.epoch;
             reply = Msg.Reply_auth_provider_accounts (Ok pa_with_rt);
           })
    in
    let m2, _ =
      Update.step ~now:t0 m1
        (Msg.Http_reply
           {
             epoch = m1.epoch;
             reply =
               Msg.Reply_auth_keepers
                 (Ok [ { Wire_personal_keepers.keeper_id = "k1"; runtime_id = Some "rt-1" } ]);
           })
    in
    let m3, _ =
      Update.step ~now:t0 m2
        (Msg.Http_reply
           {
             epoch = m2.epoch;
             reply =
               Msg.Reply_auth_keeper_conversation
                 { keeper_id = "k1"; conversation_id = None; result = Ok conv_snap };
           })
    in
    m3
  in
  let txt_conv = render_full_frame m_seeded in
  Alcotest.(check bool) "renders Personal Keepers, Personal Conversation, answered/failed/unrecorded & DELETION FAILED"
    true
    (contains_ci ~needle:"Personal Keepers" txt_conv
     && contains_ci ~needle:"Personal Conversation" txt_conv
     && contains_ci ~needle:"hello" txt_conv
     && contains_ci ~needle:"[FAILED]" txt_conv
     && contains_ci ~needle:"model_may_have_read=true" txt_conv
     && contains_ci ~needle:"[UNRECORDED]" txt_conv
     && contains_ci ~needle:"DELETION FAILED" txt_conv);

  (* Cycling onto Deletion_failed conversation must NOT emit ?conversation_id=<failed_id> *)
  let m_cyc, cmds_cyc =
    Update.step ~now:t0 m_seeded (Msg.Key_event (char_key "]"))
  in
  Alcotest.(check int) "selecting Deletion_failed conversation emits zero conversation GET"
    0 (List.length cmds_cyc);
  Alcotest.(check (option string)) "delete target points at conv-fail"
    (Some "conv-fail")
    (Personal_keepers_store.delete_target_conversation_id m_cyc.personal_keepers);

  (* 2-step delete confirm: first 'd' arms, Esc cancels, 'd'+'d' emits Delete_auth_keeper_conversation *)
  let m_d1, cmds_d1 = Update.step ~now:t0 m_cyc (Msg.Key_event (char_key "d")) in
  Alcotest.(check bool) "first 'd' arms delete without sending DELETE" true
    (Option.equal String.equal m_d1.personal_keepers.delete_armed_conv_id
       (Some "conv-fail")
     && cmds_d1 = []);
  let m_desc, _ =
    Update.step ~now:t0 m_d1
      (Msg.Key_event { key = Keymap.Input.Escape; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Esc disarms delete" true
    (Option.is_none m_desc.personal_keepers.delete_armed_conv_id);
  let m_d2a, _ = Update.step ~now:t0 m_desc (Msg.Key_event (char_key "d")) in
  let m_d2b, cmds_d2 = Update.step ~now:t0 m_d2a (Msg.Key_event (char_key "d")) in
  Alcotest.(check bool) "second 'd' disarms and emits Delete_auth_keeper_conversation"
    true
    (Option.is_none m_d2b.personal_keepers.delete_armed_conv_id
     && List.exists
          (function
            | Cmd.Http_delete
                {
                  req =
                    Cmd.Delete_auth_keeper_conversation
                      { keeper_id = "k1"; conversation_id = "conv-fail" };
                  _;
                } ->
                true
            | _ -> false)
          (Cmd.flatten cmds_d2));

  (* 503 conversation_not_deleted reloads WITHOUT conversation_id *)
  let m_503, cmds_503 =
    Update.step ~now:t1 m_d2b
      (Msg.Http_reply
         {
           epoch = m_d2b.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation_delete
               {
                 keeper_id = "k1";
                 conversation_id = "conv-fail";
                 result =
                   Error
                     (Msg.Http_error
                        {
                          status = 503;
                          body =
                            {|{"error":"could not delete","code":"conversation_not_deleted"}|};
                          api_error =
                            Some
                              {
                                Wire_common.code =
                                  Wire_common.Other_code "conversation_not_deleted";
                                message = "could not delete";
                                field = None;
                                expected_instance = None;
                                observed_instance = None;
                                observed_workspace_sha256 = None;
                              };
                        });
               };
         })
  in
  Alcotest.(check bool) "503 conversation_not_deleted reloads WITHOUT conversation_id"
    true
    (Option.is_none m_503.personal_keepers.requested_conversation_id
     && Option.is_some m_503.personal_keepers.last_delete_notice
     && List.exists
          (function
            | Cmd.Http_get
                {
                  req =
                    Cmd.Get_auth_keeper_conversation
                      { keeper_id = "k1"; conversation_id = None };
                  _;
                } ->
                true
            | _ -> false)
          (Cmd.flatten cmds_503));

  (* Ephemeral unrecorded turn answer renders [UNRECORDED / EPHEMERAL] honestly *)
  let m_eph, _ =
    Update.step ~now:t1 m_seeded
      (Msg.Http_reply
         {
           epoch = m_seeded.epoch;
           reply =
             Msg.Reply_auth_keeper_turn
               {
                 keeper_id = "k1";
                 message = "ephemeral q";
                 result =
                   Ok
                     {
                       keeper_id = "k1";
                       runtime_id = "rt-1";
                       model = "claude-sonnet-4-6";
                       text = "ephemeral answer body";
                       recording = Wire_personal_keepers.Turn_ephemeral;
                     };
               };
         })
  in
  let txt_eph = render_full_frame m_eph in
  Alcotest.(check bool) "ephemeral answer renders [UNRECORDED / EPHEMERAL]" true
    (contains_ci ~needle:"EPHEMERAL" txt_eph
     && contains_ci ~needle:"ephemeral answer body" txt_eph);

  (* POST /turn 403 turn_refused sets turn error WITHOUT locking own_keeper_forbidden *)
  let m_tref, _ =
    Update.step ~now:t1 m_seeded
      (Msg.Http_reply
         {
           epoch = m_seeded.epoch;
           reply =
             Msg.Reply_auth_keeper_turn
               {
                 keeper_id = "k1";
                 message = "hi codex";
                 result =
                   Error
                     (Msg.Http_error
                        {
                          status = 403;
                          body = {|{"error":"codex refused","code":"turn_refused"}|};
                          api_error =
                            Some
                              {
                                Wire_common.code =
                                  Wire_common.Other_code "turn_refused";
                                message = "codex refused";
                                field = None;
                                expected_instance = None;
                                observed_instance = None;
                                observed_workspace_sha256 = None;
                              };
                        });
               };
         })
  in
  Alcotest.(check bool) "turn_refused does NOT set own_keeper_forbidden" true
    (Option.is_none m_tref.personal_keepers.own_keeper_forbidden
     && Option.is_some m_tref.personal_keepers.last_turn_error);

  (* P2-2: Stale/out-of-order Reply_auth_keeper_conversation (Ok, 403, Error) never clobbers active keeper or conversation *)
  let m_two_keepers, _ =
    Update.step ~now:t1 m_seeded
      (Msg.Http_reply
         {
           epoch = m_seeded.epoch;
           reply =
             Msg.Reply_auth_keepers
               (Ok
                  [
                    { keeper_id = "k1"; runtime_id = Some "rt-1" };
                    { keeper_id = "k2"; runtime_id = Some "rt-1" };
                  ]);
         })
  in
  (* Switch from k1 -> k2 *)
  let m_on_k2, _ = Update.step ~now:t1 m_two_keepers (Msg.Key_event (char_key "j")) in
  Alcotest.(check (option string)) "selected keeper moved to k2" (Some "k2")
    (Personal_keepers_store.selected_keeper_id m_on_k2.personal_keepers);
  let k2_snap : Wire_personal_keepers.conversation_snapshot =
    {
      keeper_id = "k2";
      current_conversation_id = Some "conv-k2";
      conversation_id = Some "conv-k2";
      conversations =
        [
          {
            conversation_id = "conv-k2";
            provider_account_id = "pa-1";
            started_at_ms = 1_795_254_000_000;
            deletion = Wire_personal_keepers.Deletion_kept;
          };
          {
            conversation_id = "conv-k2-old";
            provider_account_id = "pa-1";
            started_at_ms = 1_795_250_000_000;
            deletion = Wire_personal_keepers.Deletion_kept;
          };
        ];
      turns = [];
    }
  in
  let m_k2_loaded, _ =
    Update.step ~now:t1 m_on_k2
      (Msg.Http_reply
         {
           epoch = m_on_k2.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               { keeper_id = "k2"; conversation_id = None; result = Ok k2_snap };
         })
  in
  (* Deliver late Ok, 403, and 500 replies for stale keeper k1 *)
  let k1_late_snap = { k2_snap with keeper_id = "k1"; conversation_id = Some "conv-k1-late" } in
  let m_after_late_ok, _ =
    Update.step ~now:t1 m_k2_loaded
      (Msg.Http_reply
         {
           epoch = m_k2_loaded.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               { keeper_id = "k1"; conversation_id = None; result = Ok k1_late_snap };
         })
  in
  let m_after_late_403, _ =
    Update.step ~now:t1 m_after_late_ok
      (Msg.Http_reply
         {
           epoch = m_after_late_ok.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               {
                 keeper_id = "k1";
                 conversation_id = None;
                 result = Error (Msg.Http_error { status = 403; body = "forbidden"; api_error = None });
               };
         })
  in
  let m_after_late_err, _ =
    Update.step ~now:t1 m_after_late_403
      (Msg.Http_reply
         {
           epoch = m_after_late_403.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               {
                 keeper_id = "k1";
                 conversation_id = None;
                 result = Error (Msg.Transport Health.Timeout);
               };
         })
  in
  Alcotest.(check bool) "late k1 Ok/403/Error conversation replies do NOT overwrite k2 pane"
    true
    (Option.is_none m_after_late_err.personal_keepers.conversation_forbidden
     &&
     match Personal_keepers_store.conversation_for_selected m_after_late_err.personal_keepers with
     | Some s -> String.equal s.keeper_id "k2" && s.conversation_id = Some "conv-k2"
     | None -> false);
  (* Cycle ']' to conv-k2-old -> late current (None) reply is ignored; cycle '[' back to current emits conversation_id = None *)
  let m_k2_hist, cmds_hist =
    Update.step ~now:t1 m_k2_loaded (Msg.Key_event (char_key "]"))
  in
  Alcotest.(check (option string)) "cycling to history sets requested_conversation_id"
    (Some "conv-k2-old") m_k2_hist.personal_keepers.requested_conversation_id;
  Alcotest.(check bool) "cycling to history emits GET with Some conv-k2-old" true
    (List.exists
       (function
         | Cmd.Http_get
             {
               req =
                 Cmd.Get_auth_keeper_conversation
                   { keeper_id = "k2"; conversation_id = Some "conv-k2-old" };
               _;
             } -> true
         | _ -> false)
       (Cmd.flatten cmds_hist));
  let m_stale_conv_reply, _ =
    Update.step ~now:t1 m_k2_hist
      (Msg.Http_reply
         {
           epoch = m_k2_hist.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               {
                 keeper_id = "k2";
                 conversation_id = None;
                 result = Error (Msg.Http_error { status = 403; body = "stale"; api_error = None });
               };
         })
  in
  Alcotest.(check bool) "mismatched conversation_id reply is dropped" true
    (Option.is_none m_stale_conv_reply.personal_keepers.conversation_forbidden);
  let m_k2_back, cmds_back =
    Update.step ~now:t1 m_k2_hist (Msg.Key_event (char_key "["))
  in
  Alcotest.(check bool) "cycling back to [current] emits GET with conversation_id = None"
    true
    (Option.is_none m_k2_back.personal_keepers.requested_conversation_id
     && List.exists
          (function
            | Cmd.Http_get
                {
                  req =
                    Cmd.Get_auth_keeper_conversation
                      { keeper_id = "k2"; conversation_id = None };
                  _;
                } -> true
            | _ -> false)
          (Cmd.flatten cmds_back));

  (* P2-5: transient refresh error on loaded keepers and same-keeper conversation retains stale Value *)
  let m_pk_stale_k, _ =
    Update.step ~now:t1 m_k2_loaded
      (Msg.Http_reply
         {
           epoch = m_k2_loaded.epoch;
           reply = Msg.Reply_auth_keepers (Error (Msg.Transport Health.Timeout));
         })
  in
  let m_pk_stale_c, _ =
    Update.step ~now:t1 m_pk_stale_k
      (Msg.Http_reply
         {
           epoch = m_pk_stale_k.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               {
                 keeper_id = "k2";
                 conversation_id = None;
                 result = Error (Msg.Transport Health.Timeout);
               };
         })
  in
  Alcotest.(check bool) "transient keepers & same-keeper conversation refresh failure retains stale Values"
    true
    ((match m_pk_stale_c.personal_keepers.keepers with
     | Observed.Value { stale = true; _ } -> true
     | Observed.Value { stale = false; _ }
     | Observed.Loading _ | Observed.Failed _ | Observed.Absent | Observed.Unreported -> false)
     &&
     match m_pk_stale_c.personal_keepers.conversation with
     | Observed.Value { stale = true; data = ("k2", _); _ } -> true
     | Observed.Value _ | Observed.Loading _ | Observed.Failed _
     | Observed.Absent | Observed.Unreported -> false);

  (* P2-3: delete_armed_conv_id disarms on workspace switch (1 -> 4), Tab, and mouse events *)
  let m_del_arm2, _ = Update.step ~now:t1 m_k2_loaded (Msg.Key_event (char_key "d")) in
  Alcotest.(check (option string)) "[d] arms delete on conv-k2" (Some "conv-k2")
    m_del_arm2.personal_keepers.delete_armed_conv_id;
  let m_ws_pulse, _ = Update.step ~now:t1 m_del_arm2 (Msg.Key_event (char_key "1")) in
  Alcotest.(check (option string)) "switching workspace [1] disarms delete_armed_conv_id"
    None m_ws_pulse.personal_keepers.delete_armed_conv_id;
  let m_ws_back, _ = Update.step ~now:t1 m_ws_pulse (Msg.Key_event (char_key "4")) in
  let m_d_after_ws, cmds_d_after_ws =
    Update.step ~now:t1 m_ws_back (Msg.Key_event (char_key "d"))
  in
  Alcotest.(check bool) "single [d] after returning from workspace switch arms fresh (0 DELETE)"
    true
    (m_d_after_ws.personal_keepers.delete_armed_conv_id = Some "conv-k2"
     && cmds_d_after_ws = []);
  let m_after_tab, _ =
    Update.step ~now:t1 m_d_after_ws
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Tab; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check (option string)) "[Tab] disarms delete_armed_conv_id" None
    m_after_tab.personal_keepers.delete_armed_conv_id;
  let m_del_arm3, _ = Update.step ~now:t1 m_k2_loaded (Msg.Key_event (char_key "d")) in
  let m_del_mouse, _ =
    Update.step ~now:t1 m_del_arm3
      (Msg.Mouse_event
         (Keymap.Input.Wheel { dir = Keymap.Input.Wheel_down; col = 50; row = 10 }))
  in
  Alcotest.(check (option string)) "mouse event disarms delete_armed_conv_id" None
    m_del_mouse.personal_keepers.delete_armed_conv_id;

  (* P2-4: UTF-8 multi-byte Korean turn preview does not split codepoints mid-sequence *)
  let m_turn_modal, _ = Update.step ~now:t1 m_k2_loaded (Msg.Key_event (char_key "s")) in
  let ko_msg = String.concat "" (List.init 35 (fun _ -> "가")) in
  let m_turn_filled =
    match m_turn_modal.inline_modal with
    | Some md ->
        let fields =
          List.map
            (fun (f : Model.modal_form_field) ->
              if String.equal f.key "ma_turn_message" then { f with value = ko_msg }
              else f)
            md.fields
        in
        { m_turn_modal with inline_modal = Some { md with fields } }
    | None -> Alcotest.fail "expected Ma_keeper_turn_form modal"
  in
  let m_turn_sent, _ =
    Update.step ~now:t1 m_turn_filled
      (Msg.Key_event { Keymap.Input.key = Keymap.Input.Enter; mods = Keymap.Input.no_mods })
  in
  Alcotest.(check bool) "Korean >60-byte turn preview is valid UTF-8 and truncated cleanly"
    true
    (match m_turn_sent.personal_keepers.turn_in_flight with
    | Some ("k2", preview) ->
        String.is_valid_utf_8 preview
        && Masc_tui_term.Grapheme.display_width preview <= 60
        && String.length preview < String.length ko_msg
    | Some _ | None -> false);

  (* P3-1: POST /turn HTTP 409 and HTTP 429 trigger conversation reload with conversation_id = None *)
  List.iter
    (fun (status, code) ->
      let m_err, cmds_err =
        Update.step ~now:t1 m_k2_hist
          (Msg.Http_reply
             {
               epoch = m_k2_hist.epoch;
               reply =
                 Msg.Reply_auth_keeper_turn
                   {
                     keeper_id = "k2";
                     message = "hi";
                     result =
                       Error
                         (Msg.Http_error
                            {
                              status;
                              body = Printf.sprintf {|{"error":"%s"}|} code;
                              api_error = None;
                            });
                   };
             })
      in
      Alcotest.(check bool)
        (Printf.sprintf "POST /turn HTTP %d reloads conversation without conversation_id" status)
        true
        (Option.is_none m_err.personal_keepers.requested_conversation_id
         && List.exists
              (function
                | Cmd.Http_get
                    {
                      req =
                        Cmd.Get_auth_keeper_conversation
                          { keeper_id = "k2"; conversation_id = None };
                      _;
                    } -> true
                | _ -> false)
              (Cmd.flatten cmds_err)))
    [ (409, "not_signed_in"); (429, "no_quota") ];

  (* P3-3: transcript_scroll clamps to max_transcript_scroll so scrolling up responds immediately *)
  let long_turns =
    List.init 25 (fun i : Wire_personal_keepers.conversation_turn ->
        {
          message = Printf.sprintf "Question line %d" i;
          asked_at_ms = 1_795_254_000_000 + (i * 1000);
          outcome =
            Wire_personal_keepers.Turn_answered
              {
                text = Printf.sprintf "Answer line %d" i;
                model = "claude-sonnet-4-6";
                answered_at_ms = 1_795_254_000_500 + (i * 1000);
              };
        })
  in
  let m_long_conv, _ =
    Update.step ~now:t1 m_k2_loaded
      (Msg.Http_reply
         {
           epoch = m_k2_loaded.epoch;
           reply =
             Msg.Reply_auth_keeper_conversation
               {
                 keeper_id = "k2";
                 conversation_id = None;
                 result = Ok { k2_snap with turns = long_turns };
               };
         })
  in
  let m_pane1 = { m_long_conv with nav = { m_long_conv.nav with pane_index = 1 } } in
  let m_scrolled_bot =
    let rec loop n cur =
      if n = 0 then cur
      else loop (n - 1) (fst (Update.step ~now:t1 cur (Msg.Key_event (char_key "j"))))
    in
    loop 500 m_pane1
  in
  let bot_scroll = m_scrolled_bot.personal_keepers.transcript_scroll in
  let m_scroll_up_1, _ =
    Update.step ~now:t1 m_scrolled_bot (Msg.Key_event (char_key "k"))
  in
  Alcotest.(check bool) "scrolling down clamps to max_scroll so first [k] decrements immediately"
    true
    (bot_scroll > 0 && bot_scroll < 500
     && m_scroll_up_1.personal_keepers.transcript_scroll = bot_scroll - 1);

  (* Session epoch purge on token swap / revert / identity change completely empties personal_keepers *)
  let m_purged, _ =
    Update_http.apply_runtime_token_swap ~now:t1 ~token:(Some "new-pat") m_eph
  in
  Alcotest.(check bool) "token swap purges personal_keepers completely" true
    (Personal_keepers_store.keepers_list m_purged.personal_keepers = []
     && m_purged.personal_keepers.ephemeral_turns = []
     && Option.is_none m_purged.personal_keepers.own_keeper_forbidden)

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
      ( "account_session_and_own_provider"
      , [
          Alcotest.test_case "account overlay, shortcuts, capability matrix & rendering"
            `Quick test_account_overlay_and_capability_matrix;
          Alcotest.test_case "runtime token/PAT entry, masking, swap, clear & re-bootstrap"
            `Quick test_runtime_token_swap_and_redaction;
          Alcotest.test_case "MA own-provider strict decoders, 403 handling & actions"
            `Quick test_ma_own_provider_wire_and_actions;
          Alcotest.test_case "MA personal keepers wire, validation, lifecycle & 403/503"
            `Quick test_ma_personal_keepers_wire_and_lifecycle;
        ] );
    ]
