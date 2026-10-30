from pathlib import Path
import hashlib
import json
import sys
root = Path.cwd()
artifact = Path(sys.argv[1]).resolve()
artifact.mkdir(parents=True, exist_ok=False)
plan = (root / 'lib/keeper/keeper_microvm_build_plan.ml').read_text()
source = (root / 'lib/keeper/keeper_sandbox_microvm.ml').read_text()
runtime = (root / 'lib/keeper/keeper_turn_sandbox_runtime.ml').read_text()
tests = (root / 'test/test_keeper_sandbox_microvm.ml').read_text()
def extract(s, start, end):
    pos = s.index(start)
    return s[pos:s.index(end, pos)]
warning = extract(source, 'let build_link_warning plan =', '(** Input paths are passed on stdin')
marker = extract(source, 'let build_keep_marker =', 'let trim_guest_root')
warning_test = extract(tests, 'let test_build_link_warning_is_static_and_state_aware () =', "(* The boot helper's removal")
unit = ('module M = struct\n' + plan + '\n' + marker + warning +
        '\nend\n' + warning_test + '\nlet () = Alcotest.run "warning" ["static", [Alcotest.test_case "state and secrecy" `Quick test_build_link_warning_is_static_and_state_aware]]\n')
(artifact / 'warning_check.ml').write_text(unit)
route = extract(runtime, 'let rows = Keeper_sandbox_microvm.build_link_rows_of_scan scanned in',
                '       let actions = Keeper_sandbox_microvm.build_link_actions rows in')
header = '''module Keeper_sandbox_microvm = struct\n''' + plan + '\n' + marker + warning + '''
end
module Log = struct
  module Keeper = struct
    let messages = ref []
    let warn ~keeper_name:_ fmt = Printf.ksprintf (fun message -> messages := message :: !messages) fmt
  end
end
type meta = {name:string}
type runtime = {meta:meta}
let route (t : runtime) scanned =
'''
checks = '''  ()
let contains needle haystack = Astring.String.is_infix ~affix:needle haystack
let () =
  let cases = ["private-valid", "real", "", true;
               "private:invalid-real", "real", "", true;
               "private:invalid-absent", "absent", "", false;
               "private:invalid-link", "symlink", "/private-target", false] in
  List.iter (fun (checkout, kind, target, risk) ->
    Log.Keeper.messages := [];
    let raw = checkout ^ "\\000" ^ kind ^ "\\000" ^ target ^ "\\000" in
    let scanned = match Keeper_sandbox_microvm.build_scan_rows_of_output raw with
      | Ok rows -> rows | Error detail -> failwith detail in
    route {meta={name="fixture"}} scanned;
    match !(Log.Keeper.messages) with
    | [message] ->
      assert (contains "was not changed" message);
      assert (contains ".masc-keep-build" message = risk);
      assert (contains "can stage and delete it" message = risk);
      assert (not (contains checkout message));
      assert (not (contains "/private-target" message))
    | _ -> failwith "expected exactly one warning") cases;
  print_endline "PASS: extracted runtime warning route handles four states without guest path leakage"
'''
(artifact / 'runtime_warning_check.ml').write_text(header + route + checks)
files = ['lib/keeper/keeper_microvm_build_plan.ml', 'lib/keeper/keeper_sandbox_microvm.ml',
         'lib/keeper/keeper_turn_sandbox_runtime.ml', 'test/test_keeper_sandbox_microvm.ml']
print(json.dumps({name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}, sort_keys=True))
