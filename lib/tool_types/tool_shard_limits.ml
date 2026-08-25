(** SSOT constants for tool schemas and runtime handlers that would
    otherwise form a dependency cycle (Tool_shard ↔ Keeper_tool_filesystem_runtime).

    These integers live in a leaf module with no dependencies so both
    sides can import the same value. *)

let read_file_default_max_bytes = 20_000
(* The most a single Read may return, and the most of one evidence artifact a
   verification snapshot stores. These have to be one number: the completion
   authority reads files live through Read while an operator later reviews the
   snapshot, so a Read ceiling above the snapshot cap lets a verdict rest on
   bytes the recorded evidence does not contain (#27397). Two literals that
   happen to agree are not the same as one value. *)
let read_file_max_max_bytes = 200_000
let verification_evidence_max_bytes = read_file_max_max_bytes
