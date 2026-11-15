(** Exact gemini/antigravity item in an explicitly named keychain; never searches
    the default account.

    agy saves its login through go-keyring, which runs security(1), so the
    item's decrypt ACL trusts [/usr/bin/security] and no other program. The
    value is therefore read and removed through security(1), as go-keyring's
    own [Get] reads it, and only after a native check with interaction
    disabled has found the item in an unlocked keychain whose decrypt ACL
    admits security(1) without asking for a password. That check serializes
    concurrent calls and restores the previous process setting. A locked
    keychain, or an item security(1) could only read through a dialog, is
    [Unavailable] and security(1) is not run.

    Two dialogs remain possible, both outside the check's reach: the keychain
    locking between the check and security(1), and an item that trusts
    security(1) but whose partition list (which no public API reads) leaves
    out [apple-tool:]. security(1) is ended after a fixed deadline, so either
    one ends as [Unavailable] rather than a wait. *)
type observation = Found of string | Missing | Unsupported | Unavailable

val read : path:string -> observation
(** [Found] holds the text [security find-generic-password -w] prints, less
    its final newline: the stored bytes when all are printable ASCII,
    lowercase hex otherwise. A blank value is [Unavailable]. *)

(** Only callers owning the named private destination may clear its item. *)
val clear : path:string -> (unit, unit) result
