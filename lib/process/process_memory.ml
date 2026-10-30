type source = Mach_task_info | Proc_statm
type sample = { resident_bytes : int64; source : source }

external resident_set : unit -> (sample, string) result = "masc_process_resident_set"
