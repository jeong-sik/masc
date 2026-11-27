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

  (* Multi-account Service Worker: denied Own_provider_manage with Service_cannot_manage_own_provider *)
  Alcotest.(check bool) "MA Service Worker denied Own_provider_manage" true
    (Rbac.equal_access_verdict
       (Rbac.decide ma_service_worker Rbac.Own_provider_manage)
       (Rbac.Denied Rbac.Service_cannot_manage_own_provider));
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
  Alcotest.(check bool) "MA Admin Session allowed [d] (dry-run) on Keeper_config"
    true
    (Rbac_policy.can_run_keymap_action_in_model m_ma_keeper_cfg
       Keymap.Delete_selected);
  let m_ma_pat_keeper_cfg =
    { m_ma_keeper_cfg with auth_session = ma_human_admin_pat }
  in
  Alcotest.(check bool) "MA Admin PAT denied [d] on Keeper_config" false
    (Rbac_policy.can_run_keymap_action_in_model m_ma_pat_keeper_cfg
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
     && not (Rbac.can_admin m_off.auth_session))

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
