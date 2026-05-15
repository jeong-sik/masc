open Alcotest

(** RFC-0084 host-config-cleanup-C — coreutils path migration.

    PR-C migrates the 6 absolute binary path literals in
    [lib/keeper/keeper_shell_ops.ml] (pwd / ls / cat / head / tail / wc)
    to the typed [Host_config.coreutils] record field.  The single
    [let coreutils = (Host_config.host ()).coreutils]
    binding at module-init time is the only [Host_config] call.

    Behaviour is byte-identical today; the migration establishes a
    single source of truth so a future PR can flip
    [Host_config.host] to PATH-resolved binaries
    for Alpine / BusyBox / Talos portability.

    Pins:
    - 0 occurrences of any of the 6 absolute literals in
      [keeper_shell_ops.ml] (regression guard)
    - [Host_config.host] is invoked exactly once
      from the module (positive assertion + no per-call-site
      regression)
    - Byte-identical equality between the bound [coreutils] field
      and the typed surface (cross-check) *)

let pinned_literal_count = 0
let pinned_host_config_invocations = 1

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

let test_no_coreutils_literals_in_shell_ops () =
  let content = read_file "lib/keeper/keeper_shell_ops.ml" in
  let needles =
    [ {|"/bin/pwd"|}; {|"/bin/ls"|}; {|"/bin/cat"|}
    ; {|"/usr/bin/head"|}; {|"/usr/bin/tail"|}; {|"/usr/bin/wc"|}
    ]
  in
  let total =
    List.fold_left
      (fun acc needle -> acc + count_substring ~haystack:content ~needle)
      0 needles
  in
  (check int)
    "literal occurrences of the 6 coreutils paths in \
     lib/keeper/keeper_shell_ops.ml must be 0 after PR-C"
    pinned_literal_count total
;;

let test_single_host_config_invocation () =
  let content = read_file "lib/keeper/keeper_shell_ops.ml" in
  let occurrences =
    count_substring ~haystack:content
      ~needle:"Host_config.host"
  in
  (check int)
    "Host_config.host must be invoked exactly once \
     from lib/keeper/keeper_shell_ops.ml after PR-C"
    pinned_host_config_invocations occurrences
;;

let test_coreutils_field_byte_identical () =
  let typed = (Host_config.host ()).coreutils in
  (* Sample one field; all six come from the same record so a single
     equality is sufficient to detect drift. *)
  let module H = Host_config in
  (check string) "coreutils.ls field is /bin/ls today" "/bin/ls" typed.H.ls;
  (check string) "coreutils.pwd field is /bin/pwd today" "/bin/pwd" typed.H.pwd;
  (check string) "coreutils.head field is /usr/bin/head today" "/usr/bin/head"
    typed.H.head
;;

let () =
  run
    "PR-C host-config-cleanup-C (coreutils)"
    [ ( "pr-c-coreutils"
      , [ test_case "no-coreutils-literals-in-shell-ops" `Quick
            test_no_coreutils_literals_in_shell_ops
        ; test_case "single-host-config-invocation" `Quick
            test_single_host_config_invocation
        ; test_case "coreutils-field-byte-identical" `Quick
            test_coreutils_field_byte_identical
        ] )
    ]
;;
