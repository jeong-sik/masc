(* Rows per table. Enough to name the subsystems that matter without
   shipping every one-off call site; the totals cover the rest. *)
let rows_per_table = 30

let report_json () =
  Alloc_profile.report_to_yojson (Alloc_profile.report ~top:rows_per_table)
;;
