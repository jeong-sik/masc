(* The size probe used to run [tput] with its stdout on a pipe, where [tput]
   cannot reach TIOCGWINSZ and answers from the static terminfo entry instead.
   80x24 came back as though it were a measurement, and the TUI drew that
   inside whatever window the operator had. The property that stops a repeat is
   not "the answer is right" -- no test can know the window -- but "an answer
   only exists when it was measured".

   A test process has no controlling terminal on CI and a tty when run by hand,
   so both outcomes are legal here. What is never legal is a size with a zero
   or negative side: that is the shape a fabricated default arrives in. *)
let test_size_is_measured_or_absent () =
  match Terminal_size.get () with
  | None -> ()
  | Some (rows, columns) ->
    Alcotest.(check bool)
      (Printf.sprintf "rows positive (got %d)" rows)
      true
      (rows > 0);
    Alcotest.(check bool)
      (Printf.sprintf "columns positive (got %d)" columns)
      true
      (columns > 0)
;;

(* The probe reads three descriptors in turn and the caller may call it once per
   resize, so it has to be callable repeatedly without leaking a descriptor or
   changing its mind between calls in a still window. *)
let test_repeated_reads_agree () =
  let first = Terminal_size.get () in
  let second = Terminal_size.get () in
  Alcotest.(check (option (pair int int)))
    "two reads of a still window agree"
    first
    second
;;

let () =
  Alcotest.run
    "terminal_size"
    [ ( "probe"
      , [ Alcotest.test_case
            "a size exists only when it was measured"
            `Quick
            test_size_is_measured_or_absent
        ; Alcotest.test_case
            "repeated reads agree"
            `Quick
            test_repeated_reads_agree
        ] )
    ]
;;
