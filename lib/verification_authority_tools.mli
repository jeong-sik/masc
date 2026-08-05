(** Read-only lookup surface for the completion authority (RFC-0361 D1).

    The judge decides whether submitted work is real. Until now its only tool
    was [report_review_verdict], so the submitter's evidence snapshot was the
    upper bound of what could be judged: a reference the submitter did not
    include did not exist as far as the judge was concerned. RFC-0361's live
    case is task-136 — the judge approved an uncommitted working tree and had
    no way to observe that the work was not committed anywhere.

    These tools let the judge look at the producer's tree itself. They are
    read-only by construction. A judge that can write would repair what it
    should reject, and nothing verifies that repair.

    {1 Containment}

    Every path is resolved under
    [Keeper_sandbox_config.host_root_abs_of_agent ~agent_name:producer], the
    same ownership root {!Workspace_verification_store} uses when it
    materializes an [artifact:] reference. The root is computed per producer,
    so it differs from review to review. No isolation logic is introduced here
    — a second containment implementation would be a second truth about which
    bytes a judge may read.

    File reads go through {!Workspace_verification_store.read_regular_file_prefix},
    which is also the snapshot reader. A live read and its snapshot counterpart
    therefore share one byte cap, one UTF-8 policy, and one failure vocabulary,
    and cannot report differently about the same file.

    {1 Git}

    The git tools take no subcommand from the model. Each one runs a fixed
    argv and accepts only a bounded count, so there is no allowlist to parse
    and no string to match: a write subcommand is not rejected, it is
    unexpressible. *)

type t

val create : base_path:string -> producer:string -> t
(** Bind a lookup surface to one producer's ownership root. [base_path] is the
    workspace BasePath the review was started with; the root is derived from it
    exactly as the evidence snapshot derives it. *)

val ownership_root : t -> string
(** The absolute directory every tool in this surface is confined to. Exposed
    so the prompt can name the boundary the judge is looking through. *)

val schemas : t -> Types_core.tool_schema list
(** The tool schemas to hand the evaluator, in a stable order. *)

val dispatch : t -> name:string -> args:Yojson.Safe.t -> (string, string) result
(** Execute one lookup call. [Error] carries a message meant for the model:
    an unknown tool name, a malformed argument, or a containment rejection.
    Every outcome is one of those two constructors — a call never resolves to
    a plausible-looking empty result. *)

val max_directory_entries : int
(** Entry cap for [verification_list_dir]. Exposed for tests. *)

val max_git_log_commits : int
(** Upper bound on the [limit] [verification_git_log] accepts. Exposed for
    tests. *)
