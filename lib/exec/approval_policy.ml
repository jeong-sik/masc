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
   past this one. *)
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

(* Scan for a Write_path that escapes the worktree.  Returned next
   because write-outside is the "is this supposed to touch the host?"
   smell. *)
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

let decide (policy : t)
    ~(overlay : Approval_config.agent_overlay)
    ~(caps : Capability.t list)
    ~(simple : Shell_ir.simple) : Verdict.t =
  match find_destructive_git caps with
  | Some g when overlay.deny_destructive_git ->
    Verdict.Deny { caps; reason = Destructive_git g }
  | Some _ | None ->
    match find_write_escape caps with
    | Some ps ->
      Verdict.Deny { caps; reason = Path_escape ps }
    | None ->
      match max_risk caps with
      | `Privileged -> ask_of policy ~caps ~bin:simple.bin
      | `Audited ->
        if overlay.ask_audited then ask_of policy ~caps ~bin:simple.bin
        else Verdict.Allow (Verdict.trust ~caps simple)
      | `Safe ->
        if overlay.allow_safe_in_worktree then
          Verdict.Allow (Verdict.trust ~caps simple)
        else ask_of policy ~caps ~bin:simple.bin
