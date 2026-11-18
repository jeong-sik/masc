(* Goal measures for tests that need a Goal but do not exercise the measure
   itself. A bad label is a broken fixture, so it raises. *)

let label text =
  match Goal_measure.make_label text with
  | Ok label -> label
  | Error reason -> invalid_arg ("Goal_measure_fixture.label: " ^ reason)

let done_when condition = Goal_measure.done_when ~condition:(label condition)

let count ~noun total =
  match Goal_measure.make_count total with
  | Ok total -> Goal_measure.count ~noun:(label noun) ~total
  | Error reason -> invalid_arg ("Goal_measure_fixture.count: " ^ reason)

let measure = done_when "the declared target is reached"
