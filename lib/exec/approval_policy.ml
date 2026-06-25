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
  | Some _ | None -> None
[@@warning "-4"]

let arg_lit : Shell_ir.arg -> string option = function
  | Shell_ir.Lit (s, _) -> Some s
  | Shell_ir.Var _ | Shell_ir.Concat _ -> None
;;

(* Pull the SQL string out of a database CLI's argv: the token after a bare
   [-c]/[--command] ([-e]/[--execute]), the value attached to the short flag
   ([-cSELECT…]), or after [--command=] ([--execute=]).  Returns [None] when no
   such flag is present or the value is not a literal (a [Var]/[Concat] value
   cannot be classified syntactically — it is left to graded handling, exactly
   as the substring layer could not see it either). *)
let extract_db_sql ~(short : string) ~(long : string) (args : Shell_ir.arg list)
  : string option
  =
  let long_eq = long ^ "=" in
  let rec go = function
    | [] -> None
    | a :: rest ->
      (match arg_lit a with
       | Some tok when String.equal tok short || String.equal tok long ->
         (match rest with
          | v :: _ -> arg_lit v
          | [] -> None)
       | Some tok
         when String.length tok > String.length short
              && String.starts_with ~prefix:short tok
              && not (String.starts_with ~prefix:"--" tok) ->
         Some (String.sub tok (String.length short) (String.length tok - String.length short))
       | Some tok when String.starts_with ~prefix:long_eq tok ->
         Some (String.sub tok (String.length long_eq) (String.length tok - String.length long_eq))
       | Some _ | None -> go rest)
  in
  go args
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
         (match extract_db_sql ~short ~long args with
          | Some sql ->
            (match Db_op.of_command sql with
             | Ok op when Db_op.is_destructive op -> Some op
             | Ok _ | Error _ -> scan rest)
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
       (match find_catastrophic_program caps with
        | Some bin -> Some (Verdict.Catastrophic_program bin)
        | None ->
          (match find_destructive_db caps with
           | Some op -> Some (Verdict.Destructive_db op)
           | None -> None)))

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
         ~caps ~policy ~bin:simple.bin ~simple)
