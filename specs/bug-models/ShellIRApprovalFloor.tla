---- MODULE ShellIRApprovalFloor ----
\* Bug Model: trust-coupled catastrophic deny in the Shell IR approval policy.
\*
\* Models lib/exec/approval_policy.ml decide (RFC-0254).
\*
\* Old code (pre-RFC-0254): destructive git was denied only when
\* overlay.privileged_trust = Enforced, and mkfs (a Privileged binary) was
\* graded the same way.  Loosening privileged_trust to Observe/Auto_safe to let
\* the keeper run [rm] simultaneously let [git push --force] / [mkfs] reach
\* Allow (defect 2.2.4).  Only a redirect write-escape was an unconditional Deny.
\*
\* Fix (RFC-0254 5.3-5.4): catastrophic_floor (destructive git, redirect
\* write-escape, redirect read-escape, catastrophic-by-identity program) is
\* evaluated BEFORE any trust level, so a catastrophic command is always Deny
\* regardless of overlay.
\*
\* Property: CatastrophicNeverAllowed — for every command class and every trust
\* level, a catastrophic command never reaches a verdict that executes it.

\* Command classes the capability walker (Capability_check.of_ir) can produce.
AllCommands == {"safe", "audited", "destructive_git", "catastrophic_prog", "write_redirect_escape", "read_redirect_escape"}

\* Catastrophic classes: must be denied regardless of trust (RFC-0254 floor).
Catastrophic == {"destructive_git", "catastrophic_prog", "write_redirect_escape", "read_redirect_escape"}

\* Approval_config trust levels for the matching risk class.
AllTrusts == {"enforced", "auto_safe", "observe", "suggest"}

VARIABLES cmd, trust, verdict, phase

vars == <<cmd, trust, verdict, phase>>

\* Verdict produced by the trust-graded path for a non-floor command
\* (Approval_policy.trust_dispatch).  Both "allow" and "suggest" execute the
\* command; "ask" and "deny" do not.
TrustGrade(t) ==
    CASE t = "enforced"  -> "ask"
      [] t = "auto_safe" -> "allow"
      [] t = "observe"   -> "allow"
      [] t = "suggest"   -> "suggest"

Init ==
    /\ cmd \in AllCommands
    /\ trust \in AllTrusts
    /\ verdict = "none"
    /\ phase = "init"

\* ── Clean decide: floor first (RFC-0254 5.3) ───────────────────────────
\* catastrophic_floor is checked before the trust overlay, so every
\* catastrophic command is Deny independent of [trust].
DecideClean ==
    /\ phase = "init"
    /\ phase' = "decided"
    /\ verdict' = IF cmd \in Catastrophic
                  THEN "deny"
                  ELSE TrustGrade(trust)
    /\ UNCHANGED <<cmd, trust>>

NextClean == DecideClean
SpecClean == Init /\ [][NextClean]_vars

\* ── Buggy decide: catastrophic graded by trust (pre-RFC-0254) ──────────
\* Only write_redirect_escape was an unconditional Deny; destructive_git and
\* catastrophic_prog were graded by privileged_trust, so a loosened overlay
\* downgrades them to Allow.  (read_redirect_escape did not exist in the
\* pre-RFC model; adding it here would not change the bug demonstration.)
\* This is the BugAction.
DecideBuggy ==
    /\ phase = "init"
    /\ phase' = "decided"
    /\ verdict' = IF cmd = "write_redirect_escape"
                  THEN "deny"
                  ELSE TrustGrade(trust)
    /\ UNCHANGED <<cmd, trust>>

NextBuggy == DecideBuggy
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Invariants ─────────────────────────────────────────────────────────
TypeOK ==
    /\ cmd \in AllCommands
    /\ trust \in AllTrusts
    /\ verdict \in {"none", "allow", "ask", "suggest", "deny"}
    /\ phase \in {"init", "decided"}

\* Safety: a catastrophic command, once decided, never reaches an executing
\* verdict — independent of the trust overlay.  "allow" and "suggest" both
\* execute the command; "ask" (no resolver in the autonomous lane) and "deny"
\* do not.  The fixed code denies; the property only requires non-execution.
CatastrophicNeverAllowed ==
    (phase = "decided" /\ cmd \in Catastrophic) => verdict \notin {"allow", "suggest"}

====
