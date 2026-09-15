module Revision = Builtin_skill_revision

type ownership = Recorded | Untracked | Modified
type bundled_verdict =
  | Install_missing
  | Up_to_date
  | Adopt_identical
  | Adopt_with_release_permissions
  | Permissions_pending of { revision : string }
  | Replace_recorded of { backup : string }
  | Replace_pending of { revision : string }
  | Keep_modified of { revision : string }
  | Keep_untracked_different of { revision : string }
  | Keep_uninspectable of { reason : string }
type retired_verdict =
  | Retire_recorded of { backup : string option }
  | Retire_pending of { revision : string option }
  | Keep_retired_modified of { revision : string }
  | Keep_retired_uninspectable of { reason : string }
type authority = Startup | Installer
type bundled_step =
  | Settled of bundled_verdict
  | Publish
  | Record of { revision : string }
  | Record_with_release_permissions of { revision : string; entries : Revision.entry list }
  | Exchange of { revision : string }
type retired_step =
  | Settled_retired of retired_verdict
  | Remove_receipt
  | Move_aside of { revision : string }

type files_match = Same_tree | Same_files_other_permissions | Different_files

let ownership ~receipt ~revision =
  match receipt with
  | None -> Untracked
  | Some content when String.equal content (Revision.recorded revision) -> Recorded
  | Some _ -> Modified

(* Compare with the release twice: as installed, and with every mode set to
   the release's. The second tells a tree whose files and bytes are this
   release's apart from one whose files differ. *)
let files_match ~installed ~entries ~bundled_revision =
  match String.equal installed bundled_revision,
        String.equal (Revision.revision (Revision.with_release_modes entries)) bundled_revision with
  | true, (true | false) -> Same_tree
  | false, true -> Same_files_other_permissions
  | false, false -> Different_files

(* Server start publishes missing packages and writes receipts for trees that
   already equal its release, and nothing else: binaries with different
   packages start against the same base path, and each would undo the other
   on every start.

   A missing package directory is published by either authority, even when
   another release retired it here. Nothing on disk tells that apart from a
   package this release adds, or one a later release ships again at the same
   revision; the retired tree itself is kept in the backup entry. Two binaries
   whose [masc init] runs alternate therefore retire and publish the package in
   turn, and each run reports it.

   A receipt that does not match its tree is kept whatever the cause. An
   operator edit and a replacement that stopped after publishing but before
   writing its receipt leave the same receipt, tree and backup entry, so the
   verdict does not claim which one happened. *)
let bundled_step authority ~receipt ~installed ~bundled_revision =
  match installed with
  | None -> Publish
  | Some entries ->
    let revision = Revision.revision entries in
    match ownership ~receipt ~revision, files_match ~installed:revision ~entries ~bundled_revision,
          authority with
    | Recorded, Same_tree, (Startup | Installer) -> Settled Up_to_date
    | (Untracked | Modified), Same_tree, (Startup | Installer) -> Record { revision }
    | Untracked, Same_files_other_permissions, Installer ->
      Record_with_release_permissions { revision; entries }
    | Untracked, Same_files_other_permissions, Startup -> Settled (Permissions_pending { revision })
    | Recorded, (Same_files_other_permissions | Different_files), Installer -> Exchange { revision }
    | Recorded, (Same_files_other_permissions | Different_files), Startup ->
      Settled (Replace_pending { revision })
    | Modified, (Same_files_other_permissions | Different_files), (Startup | Installer) ->
      Settled (Keep_modified { revision })
    | Untracked, Different_files, (Startup | Installer) ->
      Settled (Keep_untracked_different { revision })

let retired_step authority ~receipt ~installed =
  match installed, authority with
  | None, Installer -> Remove_receipt
  | None, Startup -> Settled_retired (Retire_pending { revision = None })
  | Some entries, (Startup | Installer) ->
    let revision = Revision.revision entries in
    match ownership ~receipt:(Some receipt) ~revision, authority with
    | Recorded, Installer -> Move_aside { revision }
    | Recorded, Startup -> Settled_retired (Retire_pending { revision = Some revision })
    | (Untracked | Modified), (Startup | Installer) ->
      Settled_retired (Keep_retired_modified { revision })
