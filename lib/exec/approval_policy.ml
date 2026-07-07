(* A3 approval_policy — pure decide (Capability.t list -> Verdict.t).

   Fail-closed: the rule runtime never produces [Allow] on an unknown
   construct.  [Ask] is always the default bucket when no explicit
   rule has fired. *)

type t = {
  raw_source : string;
  summary : string;
}

let git_is_floored : Git_op.t -> bool = function
  | Git_op.Destructive _ -> true
  | Read _ | Mutating _ -> false
;;

(* Scan the cap list for a Destructive git op.  Returned first because
   it short-circuits the policy — the approval UI cannot "yes" its way
   past this one.

   [@@warning "-4"] (on the function below): the [_ :: rest] arm is a
   find-first scan that *intentionally* skips every non-matching
   capability.  Git op membership is decided by [git_is_floored], a closed
   function over [Git_op.t], so adding a new top-level git op forces an explicit
   floor decision instead of silently falling through this scan. *)
let find_destructive_git (caps : Capability.t list) : Git_op.t option =
  let rec scan = function
    | [] -> None
    | Capability.Git g :: _ when git_is_floored g -> Some g
    | Capability.Pipeline_fold inner :: rest ->
      (match scan inner with
       | Some _ as found -> found
       | None -> scan rest)
    | _ :: rest -> scan rest
  in
  scan caps
[@@warning "-4"]

(* Scan for a Write_path that escapes the workspace.  Returned next
   because write-outside is the "is this supposed to touch the host?"
   smell.

   [@@warning "-4"] (on the function below): same find-first-scan
   rationale as [find_destructive_git] — the [_ :: rest] arm
   intentionally skips every non-escaping capability, future ctors
   included. RFC-0071 §3.4.1 nested find-first scan exemption. *)
let find_write_escape (caps : Capability.t list) : Path_scope.t option =
  let escapes (ps : Path_scope.t) : bool =
    match Path_scope.scope ps with
    | Outside_workspace _ | Absolute_unknown _ ->
      (* /dev/null is the canonical discard sink for typed stdout/stderr
         redirection; it is already exempted in path validation and handled
         as a drop target by the native dispatcher. *)
      not (Path_scope.is_discard_sink ps)
    | Inside_workspace _ | Inside_sandbox _ -> false
  in
  let rec scan = function
    | [] -> None
    | Capability.Write_path (ps, _) :: _ when escapes ps -> Some ps
    | Capability.Pipeline_fold inner :: rest ->
      (match scan inner with
       | Some _ as found -> found
       | None -> scan rest)
    | _ :: rest -> scan rest
  in
  scan caps
[@@warning "-4"]

(* Scan for a binary that is catastrophic by identity — never legitimate for
   a keeper regardless of arguments.  Part of the trust-independent floor
   (RFC-0254 §5.4).  Two families:
   - filesystem format ([mkfs] and the [mkfs.<fstype>] helpers, normalized to
     [Mkfs] in [Exec_program.of_string]);
   - system-power control ([shutdown], [reboot], [halt], [poweroff]):
     path-independent, and a keeper has no legitimate argument form for halting
     or rebooting the host.  All four are floored together so encoding only a
     subset would leave a sparse-match bypass (RFC eliminate-substring-
     destructive-classifier §2.3 / §3-A).

   Path-bearing destructive programs ([rm], [dd], [chmod], …) are
   deliberately absent: their danger is a function of the *target path*, which
   is jailed to the workspace by [Exec_policy.validate_shell_ir_paths]
   downstream of the gate (a [rm -rf /] target fails the path whitelist there,
   gate on or off).  [dd] specifically stays out for the same reason: [dd
   of=./out.img] is an ordinary workspace write, only [dd of=/dev/sda] is
   catastrophic, and that is a path question.  This scan is only for binaries
   denied even with a workspace-internal argument.

   [@@warning "-4"] (on the function below): the [_ :: rest] arm and the
   [Some _ | None] arm are a find-first scan that intentionally skips every
   non-matching capability and every non-catastrophic binary, future ctors
   included — RFC-0071 §3.4.1 nested find-first scan exemption (same rationale
   as [find_destructive_git]).  A new catastrophic binary is added as a
   positive arm in the match below. *)
let find_catastrophic_program (caps : Capability.t list) : Exec_program.t option =
  let rec scan = function
    | [] -> None
    | Capability.Exec_program (bin, _) :: rest ->
      (match Exec_program.known bin with
       | Some
           ( Exec_program.Mkfs | Exec_program.Shutdown | Exec_program.Reboot
           | Exec_program.Halt | Exec_program.Poweroff ) -> Some bin
       | Some _ | None -> scan rest)
    | Capability.Pipeline_fold inner :: rest ->
      (match scan inner with
       | Some _ as found -> found
       | None -> scan rest)
    | _ :: rest -> scan rest
  in
  scan caps
[@@warning "-4"]

(* The SQL-carrying flag pair (short, long) for a database CLI, or [None] for
   any other binary.  psql executes [-c]/[--command]; mysql/mariadb/cockroach
   execute [-e]/[--execute]. *)
let db_command_flags (bin : Exec_program.t) : (string * string) option =
  match Exec_program.known bin with
  | Some Exec_program.Psql -> Some ("-c", "--command")
  | Some (Exec_program.Mysql | Exec_program.Mariadb | Exec_program.Cockroach) ->
    Some ("-e", "--execute")
  | Some
      ( Exec_program.Ls | Exec_program.Cat | Exec_program.Pwd | Exec_program.Echo
      | Exec_program.Head | Exec_program.Tail | Exec_program.Rg | Exec_program.Grep
      | Exec_program.Find | Exec_program.Which | Exec_program.Test
      | Exec_program.Basename | Exec_program.Dirname | Exec_program.Stat
      | Exec_program.Du | Exec_program.Df | Exec_program.Sort | Exec_program.Uniq
      | Exec_program.Wc | Exec_program.Cut | Exec_program.Tr | Exec_program.File
      | Exec_program.Printf | Exec_program.Date | Exec_program.Env
      | Exec_program.Printenv | Exec_program.Hostname | Exec_program.Whoami
      | Exec_program.Uname | Exec_program.Ps | Exec_program.Tty | Exec_program.Cp
      | Exec_program.Mv | Exec_program.Ln | Exec_program.Touch | Exec_program.Tee
      | Exec_program.Awk | Exec_program.Xargs | Exec_program.Git
      | Exec_program.Docker | Exec_program.Curl | Exec_program.Wget | Exec_program.Ssh
      | Exec_program.Scp | Exec_program.Tar | Exec_program.Rsync | Exec_program.Make
      | Exec_program.Cmake | Exec_program.Dune_local_sh | Exec_program.Diff
      | Exec_program.Patch | Exec_program.Mkdir | Exec_program.Npm | Exec_program.Node
      | Exec_program.Npx | Exec_program.Yarn | Exec_program.Pnpm | Exec_program.Pip
      | Exec_program.Python | Exec_program.Python3 | Exec_program.Pytest
      | Exec_program.Pyright | Exec_program.Ruff | Exec_program.Opam
      | Exec_program.Ocamlfind | Exec_program.Tsc | Exec_program.Cargo
      | Exec_program.Rustc | Exec_program.Go | Exec_program.Gofmt | Exec_program.Gradle
      | Exec_program.Java | Exec_program.Javac | Exec_program.Mvn | Exec_program.Ninja
      | Exec_program.Sed | Exec_program.Uv | Exec_program.Gh | Exec_program.Glab
      | Exec_program.Terminal_notifier | Exec_program.Osascript | Exec_program.Play
      | Exec_program.Rec | Exec_program.Ffplay | Exec_program.Mpg123 | Exec_program.Open
      | Exec_program.Sudo | Exec_program.Su | Exec_program.Chmod | Exec_program.Chown
      | Exec_program.Rm | Exec_program.Dd | Exec_program.Mkfs | Exec_program.Shutdown
      | Exec_program.Reboot | Exec_program.Halt | Exec_program.Poweroff ) ->
    None
  | None -> None

let arg_lit : Shell_ir.arg -> string option = function
  | Shell_ir.Lit (s, _) -> Some s
  | Shell_ir.Var _ | Shell_ir.Concat _ -> None
;;

let repo_hosting_arg_word : Shell_ir.arg -> string = function
  | Shell_ir.Lit (s, _) -> s
  | Shell_ir.Var _ | Shell_ir.Concat _ -> ""

let repo_hosting_cli_is_floored (bin : Exec_program.t) (args : Shell_ir.arg list)
  : bool
  =
  match Exec_program.known bin with
  | Some Exec_program.Gh ->
    let words = Exec_program.to_string bin :: List.map repo_hosting_arg_word args in
    (* Classify through [repo_hosting_cli_floor_risk], not the word-list
       classifier alone: a leading value-taking global flag ([gh --repo o/r pr
       merge]) shifts the subcommand out of the word-list's position-based
       slot, so the naive classifier misses the destructive verb and the floor
       never fires (issue #23390). The typed lowering consumes value-flags like
       gh does, locating the real subcommand. *)
    let simple : Shell_ir.simple =
      { Shell_ir.bin
      ; args
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Sandbox_target.host ()
      }
    in
    (match Shell_ir_risk.repo_hosting_cli_floor_risk words simple with
     | R2_Irreversible | Destructive_protected -> true
     | R0_Read | R1_Reversible_mutation -> false)
  | Some _ | None -> false
[@@warning "-4"]

(* Scan for irreversible repository-hosting CLI operations.  This reuses the
   Shell IR risk SSOT for gh subcommands instead of maintaining a second command
   table in approval policy.  Non-literal argv is not floored here because the
   policy layer cannot classify values it cannot inspect; those commands remain
   in the normal graded path.

   [@@warning "-4"]: the [_ :: rest] arm is a find-first scan that
   intentionally skips non-matching capabilities, same rationale as
   [find_destructive_git]. *)
let find_destructive_repo_hosting_cli (caps : Capability.t list)
  : Exec_program.t option
  =
  let rec scan = function
    | [] -> None
    | Capability.Exec_program (bin, args) :: rest ->
      if repo_hosting_cli_is_floored bin args then Some bin else scan rest
    | Capability.Pipeline_fold inner :: rest ->
      (match scan inner with
       | Some _ as found -> found
       | None -> scan rest)
    | _ :: rest -> scan rest
  in
  scan caps
[@@warning "-4"]

(* Pull every literal SQL string out of a database CLI's argv: the token after a
   bare [-c]/[--command] ([-e]/[--execute]), the value attached to the short
   flag ([-cSELECT...]), or after [--command=] ([--execute=]).  Non-literal
   values ([Var]/[Concat]) are omitted because they cannot be classified
   syntactically — they are left to graded handling, exactly as the substring
   layer could not see them either. *)
let extract_db_sql ~(short : string) ~(long : string) (args : Shell_ir.arg list)
  : string list
  =
  let long_eq = long ^ "=" in
  let rec go acc = function
    | [] -> List.rev acc
    | a :: rest ->
      (match arg_lit a with
       | Some tok when String.equal tok short || String.equal tok long ->
         (match rest with
          | v :: tail ->
            (match arg_lit v with
             | Some sql -> go (sql :: acc) tail
             | None -> go acc tail)
          | [] -> List.rev acc)
       | Some tok
         when String.length tok > String.length short
              && String.starts_with ~prefix:short tok
              && not (String.starts_with ~prefix:"--" tok) ->
         let sql =
           String.sub tok (String.length short) (String.length tok - String.length short)
         in
         go (sql :: acc) rest
       | Some tok when String.starts_with ~prefix:long_eq tok ->
         let sql =
           String.sub tok (String.length long_eq) (String.length tok - String.length long_eq)
         in
         go (sql :: acc) rest
       | Some _ | None -> go acc rest)
  in
  go [] args
;;

(* Scan for a database CLI ([psql]/[mysql]/[mariadb]/[cockroach]) whose
   [-c]/[-e] SQL contains a destructive statement ([DROP]/[TRUNCATE]/[DELETE],
   classified by {!Db_op}).  Part of the trust-independent floor — the typed
   replacement for the [sql_destructive] substring catalogue (RFC
   eliminate-substring-destructive-classifier §3-A).  Non-destructive SQL
   ([SELECT], [INSERT], …), an unrecognized verb, or a non-literal [-c] value
   floor nothing here and are graded normally (database CLIs are [`Audited]).

   [@@warning "-4"]: the [_ :: rest] arm is a find-first scan that intentionally
   skips every non-matching capability — same rationale as
   [find_destructive_git]. *)
let find_destructive_db (caps : Capability.t list) : Db_op.t option =
  let rec scan = function
    | [] -> None
    | Capability.Exec_program (bin, args) :: rest ->
      (match db_command_flags bin with
       | Some (short, long) ->
         (match
            List.find_map
              (fun sql ->
                 match Db_op.of_command sql with
                 | Ok op when Db_op.is_destructive op -> Some op
                 | Ok _ | Error _ -> None)
              (extract_db_sql ~short ~long args)
          with
          | Some _ as found -> found
          | None -> scan rest)
       | None -> scan rest)
    | Capability.Pipeline_fold inner :: rest ->
      (match scan inner with
       | Some _ as found -> found
       | None -> scan rest)
    | _ :: rest -> scan rest
  in
  scan caps
[@@warning "-4"]

(* Trust-INDEPENDENT catastrophic floor (RFC-0254 §5.3-5.4).  Evaluated
   before any trust level, so loosening an overlay can never re-enable these.
   This is now the {e only} place destructive git is decided: it is no longer
   graded by [privileged_trust], which is the pre-RFC-0254 coupling that let a
   loosened trust level allow [git push --force]. *)
let catastrophic_floor (caps : Capability.t list) : Verdict.deny_reason option =
  match find_destructive_git caps with
  | Some g -> Some (Verdict.Destructive_git g)
  | None ->
    (match find_write_escape caps with
     | Some ps -> Some (Verdict.Path_escape ps)
     | None ->
       (match find_destructive_repo_hosting_cli caps with
        | Some bin -> Some (Verdict.Destructive_repo_hosting_cli bin)
        | None ->
       (match find_catastrophic_program caps with
        | Some bin -> Some (Verdict.Catastrophic_program bin)
        | None ->
          (match find_destructive_db caps with
           | Some op -> Some (Verdict.Destructive_db op)
           | None -> None))))

(* Highest program risk observed in the full cap tree. *)
let max_risk (caps : Capability.t list) : Exec_program.risk_class =
  let rec scan acc = function
    | [] -> acc
    | Capability.Exec_program (b, _) :: rest ->
      scan (Exec_program.risk_class_max acc (Exec_program.risk_class b)) rest
    | Capability.Git _ :: rest ->
      (* git is Audited by vocabulary; already classified through
         Exec_program above for the Exec_program fallback path.  Kept explicit
         here so a future refactor of Git_op doesn't lose the risk
         contribution. *)
      scan (Exec_program.risk_class_max acc `Audited) rest
    | Capability.Pipeline_fold inner :: rest ->
      scan (Exec_program.risk_class_max (scan acc inner) `Safe) rest
    | (Capability.Read_path _ | Capability.Write_path _
      | Capability.Env_set _) :: rest ->
      scan acc rest
  in
  scan `Safe caps

let ask_of policy ~caps ~bin : Verdict.t =
  Verdict.Ask
    {
      caps;
      summary = policy.summary;
      bin;
      raw_source = policy.raw_source;
    }

(* RFC-0309 W3 (G-6/G-8): the capability axis, consulted between the
   catastrophic floor and the risk-graded trust overlay. It is ORTHOGONAL to
   risk and to the overlay: a gh verb whose [Gh_capability_policy.disposition]
   is [Requires_approval] produces [Ask] even under the autonomous (all-Observe)
   overlay, because the non-blocking HITL queue is the resolver the overlay
   comment (approval_config.ml) said did not exist. [Allowed]/[Denied] verbs are
   left to the existing risk grading ([Denied] verbs are R2/Destructive, already
   floored or Ask-graded; [Allowed] verbs fall through to the overlay), so this
   layer only ADDS an approval requirement, never removes one. Non-gh commands
   are unaffected. *)
let gh_capability_of_simple (simple : Shell_ir.simple)
  : Gh_capability_policy.disposition option
  =
  (* [disposition_of_simple], not [disposition_of]: [gh api graphql ...] lowers
     to the body-blind [Gh_verb.Api], so the capability axis must see both the
     literal argv words and any Shell IR opacity in the graphql [query] body. *)
  Gh_capability_policy.disposition_of_simple simple

(* RFC-0309 W3 (pipeline coverage): the capability Ask must fire for a gh
   durable-remote op in ANY pipeline stage, not only the representative (last)
   [simple] the caller extracts via [last_simple_of_ir]. [caps] folds over every
   stage — the same source the catastrophic floor scans — so [gh repo create ...
   | cat] still reaches the capability axis. Without this the trailing read stage
   ([cat]) becomes the representative simple, and the R1 durable-remote create —
   no longer floored after W4 moved it R2->R1 — would auto-run under the
   autonomous overlay. Returns the first gh binary whose stage requires approval
   so the [Ask] reports the real command, not the trailing read.

   [@@warning "-4"]: the [_ :: rest] arm is a find-first scan that intentionally
   skips non-gh capabilities, same rationale as [find_destructive_repo_hosting_cli]. *)
let gh_cap_requiring_approval (caps : Capability.t list) : Exec_program.t option =
  let rec scan = function
    | [] -> None
    | Capability.Exec_program (bin, args) :: rest ->
      (match Exec_program.known bin with
       | Some Exec_program.Gh ->
         let simple : Shell_ir.simple =
           { Shell_ir.bin
           ; args
           ; env = []
           ; cwd = None
           ; redirects = []
           ; sandbox = Sandbox_target.host ()
           }
         in
         (match gh_capability_of_simple simple with
          | Some Gh_capability_policy.Requires_approval -> Some bin
          | Some (Gh_capability_policy.Allowed | Gh_capability_policy.Denied)
          | None -> scan rest)
       | Some _ | None -> scan rest)
    | Capability.Pipeline_fold inner :: rest ->
      (match scan inner with
       | Some _ as found -> found
       | None -> scan rest)
    | _ :: rest -> scan rest
  in
  scan caps
[@@warning "-4"]

let trust_dispatch ~trust_level ~caps ~policy ~bin ~simple : Verdict.t =
  match trust_level with
  | Approval_config.Enforced -> ask_of policy ~caps ~bin
  | Approval_config.Auto_safe -> Verdict.Allow (Verdict.trust ~caps simple)
  | Approval_config.Suggest ->
    let token : Verdict.confirm_token =
      { risk_class = Exec_program.risk_class simple.Shell_ir.bin; ttl_sec = 60.0 }
    in
    Verdict.Suggest_confirm (Verdict.trust ~caps simple, token)
  | Approval_config.Observe -> Verdict.Allow (Verdict.trust ~caps simple)

let decide (policy : t)
    ~(overlay : Approval_config.agent_overlay)
    ~(caps : Capability.t list)
    ~(simple : Shell_ir.simple) : Verdict.t =
  match catastrophic_floor caps with
  | Some reason ->
    (* Trust-independent: denied regardless of [overlay] (RFC-0254 §5.3). *)
    Verdict.Deny { caps; reason }
  | None ->
    (match gh_cap_requiring_approval caps with
     | Some gh_bin ->
       (* RFC-0309 W3: a gh verb the capability axis marks [Requires_approval]
          is escalated to [Ask] regardless of overlay. Additive only — reached
          solely for gh, and only to REQUIRE approval the risk grading would
          not. Scanned over ALL caps so a gh op in any pipeline stage asks, not
          only the representative [simple]. *)
       ask_of policy ~caps ~bin:gh_bin
     | None ->
       (* Non-catastrophic: graded by the per-actor trust overlay.  Under the
          autonomous overlay every level is [Observe] => [Allow] + telemetry;
          under [enforced_all] every level is [Enforced] => [Ask]. *)
       (match max_risk caps with
     | `Privileged ->
       trust_dispatch ~trust_level:overlay.privileged_trust
         ~caps ~policy ~bin:simple.bin ~simple
     | `Audited ->
       trust_dispatch ~trust_level:overlay.audited_trust
         ~caps ~policy ~bin:simple.bin ~simple
     | `Safe ->
       trust_dispatch ~trust_level:overlay.safe_trust
         ~caps ~policy ~bin:simple.bin ~simple))
