(* Pins the admission argument judgment run_best_effort consults. The
   wildcard-expansion codemod folded the accepting arm into the rejecting one,
   so a standalone Memory maintenance pass with an explicit admission batch
   was refused. *)

module R = Masc.Keeper_librarian_runtime

let check name ~has_admission ~write_scope ~has_continuity ~has_durable_range_id
      ~has_official_range_id expected
  =
  Alcotest.(check bool) name expected
    (R.admission_mode_valid ~has_admission ~write_scope ~has_continuity
       ~has_durable_range_id ~has_official_range_id)
;;

let () =
  check "an explicit batch rides a standalone maintenance pass"
    ~has_admission:true ~write_scope:R.Memory_maintenance
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:false true;
  check "an explicit batch with a context-only scope is rejected"
    ~has_admission:true ~write_scope:R.Context_only
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:false false;
  check "an explicit batch with a context-and-memory scope is rejected"
    ~has_admission:true ~write_scope:R.Context_and_memory
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:false false;
  check "an explicit batch bound to continuity is rejected"
    ~has_admission:true ~write_scope:R.Memory_maintenance
    ~has_continuity:true ~has_durable_range_id:false ~has_official_range_id:false false;
  check "an explicit batch bound to a durable range is rejected"
    ~has_admission:true ~write_scope:R.Memory_maintenance
    ~has_continuity:false ~has_durable_range_id:true ~has_official_range_id:false false;
  check "an explicit batch bound to an official range is rejected"
    ~has_admission:true ~write_scope:R.Memory_maintenance
    ~has_continuity:false ~has_durable_range_id:false ~has_official_range_id:true false;
  check "without an explicit batch every scope is admitted"
    ~has_admission:false ~write_scope:R.Context_and_memory
    ~has_continuity:true ~has_durable_range_id:true ~has_official_range_id:true true
;;
