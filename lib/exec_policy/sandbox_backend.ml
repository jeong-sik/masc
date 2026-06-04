open Typed_capabilities

type exec_result = {
  stdout : string;
  stderr : string;
  exit_code : int;
}

let run (Safe_IR ir : safe verified_ir) (_env : Eio_unix.Stdenv.base) : exec_result =
  match ir with
  | Masc_exec.Shell_ir.Simple simple ->
      let bin = Masc_exec.Exec_program.to_string simple.bin in
      let rec extract_args = function
        | [] -> []
        | Masc_exec.Shell_ir.Lit (s, _) :: rest -> s :: extract_args rest
        | _ :: rest -> extract_args rest
      in
      let args = extract_args simple.args in
      (* Statically query capability bounds *)
      let _flags = classify_program_flags simple.bin in

      (* structure concurrency with Eio.Switch *)
      Eio.Switch.run (fun _sw ->
        (* Simulated sandboxing behavior *)
        { stdout = "Structured sandbox run of: " ^ bin ^ " " ^ String.concat " " args;
          stderr = "";
          exit_code = 0 }
      )
  | Masc_exec.Shell_ir.Pipeline _ ->
      { stdout = ""; stderr = "Pipeline sandbox execution not implemented"; exit_code = 1 }
