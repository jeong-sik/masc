val classify : Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir_risk.envelope

val with_cwd : raw:string -> cwd:string -> Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir.t

val of_cmd : string -> Masc_exec.Shell_ir.t
