(** The producer's own tool surface, lent to the completion authority
    (RFC-0361 D1).

    The judge decides whether submitted work is real. Until now its only tool
    was [report_review_verdict], so the submitter's evidence snapshot was the
    upper bound of what could be judged: a reference the submitter did not
    include did not exist as far as the judge was concerned. RFC-0361's live
    case is task-136 — the judge approved an uncommitted working tree and had
    no way to observe that the work was not committed anywhere.

    {1 The same instruments, not a smaller set}

    The tools here are the keeper tools the producer itself ran — [tool_read_file],
    [tool_search_files], [tool_execute] — bound to the producer's meta rather
    than to a judge of its own. Nothing is re-implemented.

    A curated read-only surface was the earlier design and it was wrong twice
    over. A hand-written tool answers only the question its author anticipated,
    so every new question costs a release; and the questions that decide a
    verdict are not a fixed set. "Do the tests pass" cannot be answered by
    reading files at all — it needs the build to run. A judge that can only read
    the claim that tests pass is judging the claim, not the work.

    The judge therefore holds the producer's execution authority, writes
    included. That is a deliberate trade: it can repair what it should reject,
    and nothing verifies that repair. What makes the trade payable is that every
    call it makes is recorded — {!Verification_run_registry} keeps the tool
    observations on the run, so a verdict reached after the judge changed the
    tree is visible as such instead of being indistinguishable from one reached
    by reading.

    {1 Containment}

    Paths resolve through the producer's own sandbox jail, which is what the
    keeper runtimes already enforce for the producer. Borrowing the producer's
    meta borrows its jail: the judge reaches exactly the tree the work happened
    in, and nothing outside it.

    This is also why the surface is not rooted at
    [Keeper_sandbox_config.host_root_abs_of_agent]. That root is the bundle
    directory; the checkout the producer commits in lives below it under
    [repos/]. A tool rooted there would answer "not a repository" for every
    producer while looking like a working check. The sandbox jail resolves to
    where the producer actually worked.

    {1 The Gate posture is the producer's}

    [tool_execute] submits through the external-effect Gate, and the Gate reads
    [meta.always_allow] — the producer's switch, since the producer's meta is
    what this surface carries. A producer that runs effects without approval
    gives its judge the same, and a producer whose effects queue for approval
    gives its judge a queued effect too.

    That second case is a dead end, and deliberately so rather than by
    oversight. A queued effect resolves by waking the keeper that submitted it;
    the judge is one review with no wake path, so it receives the deferral as a
    failed call and has to reach a verdict without that answer. Granting the
    judge a bypass would let it run effects on a tree whose owner is not
    allowed to, which is a larger hole than the one it closes.

    {1 Not a keeper}

    Borrowing a producer's meta does not enrol the judge as a keeper: no
    registry entry, no sandbox of its own, no lifecycle, no persona, and none of
    the task, board, memory, or voice tools. It holds three instruments pointed
    at someone else's tree for the length of one review. *)

type t

val create :
  config:Workspace.config -> producer:string -> (t, string) result
(** Bind a surface to one producer by loading that producer's keeper meta.
    [Error] when the producer has no readable meta — a judge with no tree to
    look at is told so rather than handed a surface that fails on every call. *)

val ownership_root : t -> string
(** The producer's bundle root, for naming the boundary in the prompt. Tool
    calls resolve through the sandbox jail rather than this string. *)

val schemas : t -> Types_core.tool_schema list
(** The tool schemas to hand the evaluator, in a stable order.

    These come from [Tool_shard], which documents handler inputs, because
    [dispatch] calls the runtime handlers directly. That is a different entry
    point from a Keeper's, and the two spell the same work differently:
    [Keeper_tool_filesystem_runtime.handle_read_file_with_outcome] reads
    ["path"], while the descriptor a Keeper is shown asks for ["file_path"] and
    offers [cwd], [offset] and [limit] — arguments no caller on this path can
    supply.

    A judge and a Keeper are therefore shown different text for the same tool
    name, and the descriptions differ because the arguments do. Serving these
    from [Keeper_tool_descriptor] instead type-checks and builds; it also makes
    every judge read resolve ["path"] to its [~default:""] and inspect nothing
    (#27563). Read the handler before assuming the two catalogs should agree. *)

val dispatch : t -> name:string -> args:Yojson.Safe.t -> (string, string) result
(** Run one call against the producer's tree. [Error] carries a message meant
    for the model: an unknown tool name, or the runtime's own failure text.
    Every outcome is one of those two constructors — a call never resolves to a
    plausible-looking empty result. *)
