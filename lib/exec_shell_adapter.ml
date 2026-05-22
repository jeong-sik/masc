(** Shared helpers for shell-like tool frontends after command policy has
    already accepted a command and produced Shell IR. *)

let shell_ir_with_default_cwd cwd ir =
  match cwd with
  | None -> ir
  | Some dir ->
    let default_cwd = Masc_exec.Path_scope.classify ~raw:dir ~cwd:dir in
    let rec map_ir = function
      | Masc_exec.Shell_ir.Simple simple ->
        let simple =
          match simple.cwd with
          | Some _ -> simple
          | None -> { simple with cwd = Some default_cwd }
        in
        Masc_exec.Shell_ir.Simple simple
      | Masc_exec.Shell_ir.Pipeline stages ->
        Masc_exec.Shell_ir.Pipeline (List.map map_ir stages)
    in
    map_ir ir
;;

let output_for_dispatch_status ~(status : Unix.process_status) ~stdout ~stderr =
  match status with
  | Unix.WEXITED 0 -> stdout
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> (
    match stdout, stderr with
    | "", err -> err
    | out, "" -> out
    | out, err -> out ^ "\n" ^ err)
;;
