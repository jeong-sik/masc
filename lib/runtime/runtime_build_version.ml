(** Build version owner shared by runtime adapters and protocol servers.

    The value lives in {!Build_version}, a leaf every layer can reach. It sat
    here first, and the gate connectors — which do not depend on this library —
    could not read it, so they carried a literal that drifted. *)

let current = Build_version.current
