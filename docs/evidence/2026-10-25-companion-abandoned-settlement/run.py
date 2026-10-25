#!/usr/bin/env python3
"""Execute the actual runtime callback and allocation component with explicit ports."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
EXTRACT = r'''
open Parsetree
let () =
  let channel = open_in Sys.argv.(1) in
  let source = really_input_string channel (in_channel_length channel) in
  close_in channel;
  let syntax = Parse.implementation (Lexing.from_string source) in
  let callbacks = ref [] in
  let iterator = {Ast_iterator.default_iterator with expr = (fun self expression ->
    (match expression.pexp_desc with
     | Pexp_apply ({pexp_desc=Pexp_ident {txt=Longident.Ldot
          ({txt=Longident.Lident "Lane_addon_companion_allocation";_},
           {txt="on_finish";_});_};_},
         [Asttypes.Nolabel,_; Asttypes.Nolabel,callback]) ->
         callbacks := callback.pexp_loc :: !callbacks
     | _ -> ());
    Ast_iterator.default_iterator.expr self expression)} in
  iterator.structure iterator syntax;
  match !callbacks with
  | [location] -> print_string (String.sub source location.loc_start.pos_cnum
      (location.loc_end.pos_cnum-location.loc_start.pos_cnum))
  | _ -> failwith "expected one runtime allocation settlement callback"
'''

PORTS = r'''
module Lane_addon_companion_broker = struct
  type completion = Released | Abandoned
  type error = Not_started | Outcome_unknown
  type shutdown_error = Listener_close_unconfirmed
  type t = {fd:Unix.file_descr; socket_path:string; mutable live:bool}
  let create ~sw:_ ~directory ~max_message_bytes:_ =
    let fd=Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let socket_path=Filename.concat directory "s" in
    Unix.bind fd (Unix.ADDR_UNIX socket_path);
    Unix.listen fd 1;
    Ok {fd;socket_path;live=true}
  let revoke t = if t.live then (Unix.close t.fd;t.live<-false)
  let await_stopped t = if t.live then Error Listener_close_unconfirmed else Ok ()
end
module Log = struct
  module Misc = struct let warn format = Printf.ksprintf (fun _ -> ()) format end
end
module C = Lane_addon_companion_broker
module P = struct
  type command = Release of string
  type error = Not_started | Outcome_unknown
end
type browser = {stopping:bool}
'''

CASES = r'''
let failures = ref 0
let cases = ref 0
let check name expected outcome =
  incr cases;
  if outcome=expected then Printf.printf "PASS %s\n%!" name
  else (incr failures;Printf.printf "FAIL %s\n%!" name)
let run_case ~completion ~operation_id ~original ~stopping ~reply ~expected ~calls name =
  let directory = ref None in
  Fun.protect ~finally:(fun () -> Option.iter (fun path ->
      Unix.unlink (Filename.concat path "s");Unix.rmdir path) !directory) (fun () ->
    Eio.Switch.run (fun sw ->
      let allocation=match A.create ~sw ~max_message_bytes:16384 with
        | Ok allocation -> allocation | Error _ -> failwith "allocation port failed" in
      directory:=Some (Filename.dirname (A.broker allocation).C.socket_path);
      let operation=ref operation_id in
      let browser={stopping} in
      let original_browser ()=original in
      let dispatches=ref [] in
      let execute command=dispatches:=command :: !dispatches;reply in
      let settlement=SETTLEMENT_CALLBACK in
      let notify=match A.on_finish allocation settlement with
        | Ok notify -> notify | Error _ -> failwith "settlement registration failed" in
      notify completion;
      let result=A.cleanup allocation in
      let actual=match result with
        | Ok (A.Paths_retained _) -> Ok () | Error detail -> Error detail in
      check (name ^ ": allocation decision") expected actual;
      check (name ^ ": original Release dispatch count") calls (List.length !dispatches);
      check (name ^ ": exact original operation")
        (if calls=0 then [] else [P.Release "original-operation"]) !dispatches;
      check (name ^ ": stable cleanup") result (A.cleanup allocation)))
let () =
 Eio_main.run (fun _ ->
  let released=Ok (`Assoc ["released",`Bool true]) in
  let unavailable=Error "private settlement unconfirmed" in
  let run ?(completion=C.Abandoned) ?(operation_id=Some "original-operation")
      ?(original=true) ?(stopping=false) ?(reply=released) ~expected ~calls name =
    run_case ~completion ~operation_id ~original ~stopping ~reply ~expected ~calls name in
  run ~operation_id:None ~original:false ~stopping:true ~expected:(Ok ()) ~calls:0
    "no extension operation";
  run ~expected:(Ok ()) ~calls:1 "confirmed original Release";
  run ~original:false ~expected:unavailable ~calls:0 "replacement Browser";
  run ~stopping:true ~expected:unavailable ~calls:0 "stopping original Browser";
  run ~original:false ~stopping:true ~expected:unavailable ~calls:0 "lost stopping Browser";
  run ~reply:(Ok (`Assoc ["released",`Bool false])) ~expected:unavailable ~calls:1
    "unconfirmed Release receipt";
  run ~reply:(Error P.Not_started) ~expected:unavailable ~calls:1 "Release pre-effect refusal";
  run ~reply:(Error P.Outcome_unknown) ~expected:unavailable ~calls:1 "Release unknown outcome";
  run ~completion:C.Released ~original:false ~stopping:true ~expected:(Ok ()) ~calls:0
    "broker confirmed Release");
 Printf.printf "assertions=%d failures=%d\n%!" !cases !failures;
 if !failures<>0 then exit 1
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-source", type=Path,
                        default=ROOT / "lib/lane_addon/lane_addon_runtime.ml")
    args = parser.parse_args()
    allocation = ROOT / "lib/lane_addon/lane_addon_companion_allocation.ml"
    for name, path in [("runtime", args.runtime_source), ("allocation", allocation)]:
        print(f"{name} sha256={hashlib.sha256(path.read_bytes()).hexdigest()}", flush=True)
    with tempfile.TemporaryDirectory(prefix="masc-settlement-component-") as temporary:
        temporary = Path(temporary)
        extract = temporary / "extract.ml"
        extract.write_text(EXTRACT)
        subprocess.run(["ocamlfind", "ocamlc", "-package", "compiler-libs.common",
                        "-linkpkg", "-o", str(temporary / "extract"), str(extract)], check=True)
        callback = subprocess.check_output([str(temporary / "extract"),
                                            str(args.runtime_source)], text=True)
        source = PORTS + "\nmodule A = struct\n" + allocation.read_text() + "\nend\n"
        source += CASES.replace("SETTLEMENT_CALLBACK", callback)
        component = temporary / "component.ml"
        component.write_text(source)
        subprocess.run(["ocamlfind", "ocamlopt", "-package", "eio_main,eio.unix,yojson",
                        "-linkpkg", "-o", str(temporary / "component"), str(component)], check=True)
        return subprocess.run([str(temporary / "component")]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
