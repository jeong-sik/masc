(* RFC-0054 POC — synthetic GADT mirroring the shell_ir_typed.ml shape.

   Same 4-parameter ('input, 'output, 'risk, 'sandbox) structure that
   broke under [@@deriving tla] in PR-1 / PR-1b. We declare the type
   here and let bin/poc_shell_ir_gen emit the walkers into a sibling
   .ml file via a dune (rule ...). *)

type (_, _, _, _) command =
  | C_ls :
      { path : string option }
      -> (unit, string, [ `Safe ], [ `Host ]) command
  | C_git_status :
      { short : bool }
      -> (unit, string, [ `Audited ], [ `Host ]) command
  | C_rm :
      { path : string }
      -> (unit, unit, [ `Privileged ], [ `Host ]) command
