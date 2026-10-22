(** Synthetic Docker CLI transport shared by owned-job feature scenarios and
    the isolated preparation harness. This is not real Docker execution.

    [daemon.json] contains attempted [calls], a [containers] object keyed by
    exact owned-job ID and immutable [original_ids]. Creates allocate distinct
    canonical IDs; unrelated retained containers coexist. Exact-ID commands
    never select a default container.

    [control.json] has [shared] daemon/inventory faults, [jobs] keyed resource
    faults and [armed] pre-handle faults. Each armed entry names an exact
    [base_path], [keeper_name], complete canonical [source] and request digest.
    Only a validated create owner/binding can consume that entry into one
    [jobs] entry. Ambiguous or conflicting targets fail rather than selecting
    an arbitrary resource. Blocked inspect returns its captured snapshot;
    it never republishes stale daemon state after releasing the lock. *)
val source : string
