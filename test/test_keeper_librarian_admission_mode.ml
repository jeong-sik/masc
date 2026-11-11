(* Pins the commit run_best_effort gives an explicit admission batch. The
   wildcard-expansion codemod folded the accepting arm into the rejecting one,
   so a standalone Memory maintenance pass with an explicit admission batch
   was refused. *)

module R = Masc.Keeper_librarian_runtime

(* Each scope that writes Memory names the admission pass, the pass an
   admission batch commits under. *)
let admission = Masc.Keeper_memory_commit_pass.Admission

let check name ~write_scope ~has_continuity ~has_durable_range_id
      ~has_official_range_id expected
  =
  Alcotest.(check bool) name true
    (R.admission_commit ~write_scope ~has_continuity ~has_durable_range_id
       ~has_official_range_id
     = expected)
;;

let () =
  check "an explicit batch rides a standalone maintenance pass under its pass"
    ~write_scope:(R.Memory_maintenance admission)
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:false
    (Some (R.Commit_maintenance admission));
  check "an explicit batch with a context-only scope is rejected"
    ~write_scope:R.Context_only
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:false None;
  check "an explicit batch with a context-and-memory scope is rejected"
    ~write_scope:(R.Context_and_memory admission)
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:false None;
  check "an explicit batch bound to continuity is rejected"
    ~write_scope:(R.Memory_maintenance admission)
    ~has_continuity:true ~has_durable_range_id:false ~has_official_range_id:false None;
  check "an explicit batch bound to a durable range is rejected"
    ~write_scope:(R.Memory_maintenance admission)
    ~has_continuity:false ~has_durable_range_id:true ~has_official_range_id:false None;
  check "an explicit batch bound to an official range is rejected"
    ~write_scope:(R.Memory_maintenance admission)
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:true None
;;
