(* A3 approval_policy — pure decide (Capability.t list -> Verdict.t).

   Fail-closed: the rule cascade never produces [Allow] on an unknown
   construct.  [Ask] is always the default bucket when no explicit
   rule has fired. *)

type t = {
  raw_source : string;
  summary : string;
}

(* Scan the cap list for a Destructive git op.  Returned first because
   it short-circuits the policy — the approval UI cannot "yes" its way
   past this one.

   [@warning "-4"]: the [_ :: rest] arm is a find-first scan that
   *intentionally* skips every non-matching capability — including
   future [Capability.t] ctors and future [Git_op.t] ctors that are not
   [Destructive]. Forcing an explicit enumeration over both nested
   variants adds friction with no safety gain (the answer is always
   "skip and keep scanning"). RFC-0071 §3.4.1 — nested find-first scan
   exemption, not a closed-sum dispatch. *)
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

(* Scan for a Write_path that escapes the worktree.  Returned next
   because write-outside is the "is this supposed to touch the host?"
   smell.

   [@warning "-4"]: same find-first-scan rationale as
   [find_destructive_git] — the [_ :: rest] arm intentionally skips
   every non-escaping capability, future ctors included.
   RFC-0071 §3.4.1 nested find-first scan exemption. *)
let find_write_escape (caps : Capability.t list) : Path_scope.t option =
  let escapes (ps : Path_scope.t) : bool =
    match Path_scope.scope ps with
    | Outside_worktree _ | Absolute_unknown _ -> true
    | Inside_worktree _ | Inside_sandbox _ -> false
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

(* Highest bin risk observed in the full cap tree. *)
let max_risk (caps : Capability.t list) : Bin.risk_class =
  let bump (acc : Bin.risk_class) (r : Bin.risk_class) : Bin.risk_class =
    match acc, r with
    | `Privileged, _ | _, `Privileged -> `Privileged
    | `Audited, _ | _, `Audited -> `Audited
    | `Safe, `Safe -> `Safe
  in
  let rec scan acc = function
    | [] -> acc
    | Capability.Exec_bin (b, _) :: rest ->
      scan (bump acc (Bin.risk_class b)) rest
    | Capability.Git _ :: rest ->
      (* git is Audited by vocabulary; already classified through
         Bin above for the Exec_bin fallback path.  Kept explicit
         here so a future refactor of Git_op doesn't lose the risk
         contribution. *)
      scan (bump acc `Audited) rest
    | Capability.Pipeline_fold inner :: rest ->
      scan (bump (scan acc inner) `Safe) rest
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
      { risk_class = Bin.risk_class simple.Shell_ir.bin; ttl_sec = 60.0 }
    in
    Verdict.Suggest_confirm (Verdict.trust ~caps simple, token)
  | Approval_config.Observe -> Verdict.Allow (Verdict.trust ~caps simple)

let decide (policy : t)
    ~(overlay : Approval_config.agent_overlay)
    ~(caps : Capability.t list)
    ~(simple : Shell_ir.simple) : Verdict.t =
  match find_destructive_git caps with
  | Some g ->
    (* Destructive git: trust level decides *)
    (match overlay.privileged_trust with
     | Approval_config.Enforced ->
       Verdict.Deny { caps; reason = Destructive_git g }
     | Approval_config.Auto_safe ->
       Verdict.Allow (Verdict.trust ~caps simple)
     | Approval_config.Suggest ->
       let token : Verdict.confirm_token =
         { risk_class = `Privileged; ttl_sec = 60.0 }
       in
       Verdict.Suggest_confirm (Verdict.trust ~caps simple, token)
     | Approval_config.Observe ->
       Verdict.Allow (Verdict.trust ~caps simple))
  | None ->
    match find_write_escape caps with
    | Some ps ->
      Verdict.Deny { caps; reason = Path_escape ps }
    | None ->
      match max_risk caps with
      | `Privileged ->
        trust_dispatch ~trust_level:overlay.privileged_trust
          ~caps ~policy ~bin:simple.bin ~simple
      | `Audited ->
        trust_dispatch ~trust_level:overlay.audited_trust
          ~caps ~policy ~bin:simple.bin ~simple
      | `Safe ->
        trust_dispatch ~trust_level:overlay.safe_trust
          ~caps ~policy ~bin:simple.bin ~simple
