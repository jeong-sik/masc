(** The image build counts one "Closed under the global context" line per
    theorem below: none of them may rest on an axiom. *)
From WkblLaws Require Import Laws.
Print Assumptions check_spec.
Print Assumptions check_reports_exactly.
Print Assumptions rows_bounded.
