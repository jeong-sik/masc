(* A3 approval_policy — pure decide (Capability.t list -> Verdict.t).

   Fail-closed: the rule runtime never produces [Allow] on an unknown
   construct.  [Ask] is always the default bucket when no explicit
   rule has fired. *)

type t = {
  raw_source : string;
  summary : string;
}

(* Scan the cap list for a Destructive git op.  Returned first because
   it short-circuits the policy — the approval UI cannot "yes" its way
   past this one.

   [@@warning "-4"] (on the function below): the [_ :: rest] arm is a
   find-first scan that *intentionally* skips every non-matching
   capability — including future [Capability.t] ctors and [Git_op.t]
   ctors that are not [Destructive] — notably [Destructive_recoverable]
   (reset --hard, branch -D), which RFC-0255 §4.5 intentionally keeps OUT
   of the floor (reflog-recoverable, graded by the overlay). Forcing an explicit
   enumeration over both nested variants adds friction with no safety
   gain (the answer is always "skip and keep scanning"). RFC-0071
   §3.4.1 — nested find-first scan exemption, not a closed-sum dispatch. *)
let find_destructive_git (caps : Capability.t list) : Git_op.t option =
  let rec scan = function
    | [] -> None
    | Capability.Git (Git_op.Destructive _ as g) :: _ -> Some g
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
    | Outside_workspace _ | Absolute_unknown _ -> true
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
   a keeper regardless of arguments (currently [mkfs]).  Part of the
   trust-independent floor (RFC-0254 §5.4).

   Path-bearing destructive programs ([rm], [dd], [chmod], …) are
   deliberately absent: their danger is a function of the *target path*, which
   is jailed to the workspace by [Exec_policy.validate_shell_ir_paths]
   downstream of the gate (a [rm -rf /] target fails the path whitelist there,
   gate on or off).  This scan is only for binaries denied even with a
   workspace-internal argument.

   [@@warning "-4"] (on the function below): the [_ :: rest] arm and the
   [Some _ | None] arm are a find-first scan that intentionally skips every
   non-matching capability and every non-catastrophic binary, future ctors
   included — RFC-0071 §3.4.1 nested find-first scan exemption (same rationale
   as [find_destructive_git]).  A new catastrophic binary is added as a
   positive arm beside [Some Exec_program.Mkfs]. *)
let find_catastrophic_program (caps : Capability.t list) : Exec_program.t option =
  let rec scan = function
    | [] -> None
    | Capability.Exec_program (bin, _) :: rest ->
      (match Exec_program.known bin with
       | Some Exec_program.Mkfs -> Some bin
       | Some _ | None -> scan rest)
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
        | None -> None))

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
