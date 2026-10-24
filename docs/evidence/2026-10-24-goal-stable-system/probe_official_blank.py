"""Actual assembler + selected Host guard statements, not full Host/SDK execution."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
BASE = "d3a242837194e94c435a228228ac0eaab10724aa"


def extract(source, start, end):
    return source[source.index(start):source.index(end)]


def guard(source):
    source = source[source.index("let prepare_turn ~runtime_label"):]
    return extract(source, "  let system_prompt =\n", "  (* No preemptive cut of the seed.")


request = extract((ROOT / "lib/keeper/keeper_run_prompt.ml").read_text(),
                  "let assemble_extra_system_context =", "(* See the mli: a position question")
sanitizer = extract((ROOT / "lib/core/safe_ops.ml").read_text(),
                    "let[@inline] is_disallowed_control_char", "let rec sanitize_json_utf8")
trim = extract((ROOT / "lib/string_util/string_util.ml").read_text(), "let trim_nonempty value =", "(* The .mli says this maps trim_nonempty")
old = subprocess.check_output(["git", "show", BASE + ":lib/keeper/keeper_official_client_host.ml"], cwd=ROOT, text=True)
new = (ROOT / "lib/keeper/keeper_official_client_host.ml").read_text()
probe = r'''
module A = Keeper_context_assembly
module P = Prompt_block_id
module L = Keeper_context_layers
let checks = ref 0
let check label okay = if not okay then failwith label else
  (incr checks; Printf.printf "PASS %s\n" label)
let goal = "Goal observation revision-current measurement-reported-only=1/3"
let refused = function Error (Guard.InvalidConfig {field="system_prompt";_}) -> true | _ -> false
let assembly base with_goal =
  let world = L.singleton L.Active_goals goal in
  Request.assemble_request_context ~base_system_prompt:base ~post_tool_round:false
    ~previous_assembly:None ~dynamic_context_partition:(if with_goal then Some world else None)
    ~existing_extra_system_context:None
    ~blocks:(if with_goal then [P.Dynamic_context,L.text world] else [])
let () =
  List.iter (fun (base,previous) ->
    let selected = Option.value ~default:base previous in
    let issued = assembly selected true in
    let override = A.system_prompt_override ~previous issued in
    let reader = Some (fun () -> Some issued) in
    check "baseline Goal suffix masks blank selected instructions"
      (match Baseline_guard.prepare_guard ~system_prompt:base ~composed_context:reader
        {Baseline_guard.system_prompt_override=override} with Ok _ -> true | Error _ -> false);
    check "repair refuses blank selected instructions beneath Goal observation"
      (refused (Guard.prepare_guard ~system_prompt:base ~composed_context:reader
        {Guard.system_prompt_override=override}));
    let empty = assembly selected false in
    check "generic no-Goal override keeps exact None or Some bytes"
      (A.system_prompt_override ~previous empty = previous);
    check "existing official no-Goal blank refusal is preserved"
      (refused (Guard.prepare_guard ~system_prompt:base ~composed_context:(Some (fun () -> Some empty))
        {Guard.system_prompt_override=previous})))
    ["",None;" \n\t ",None;"VALID",Some "";"VALID",Some " \n\t "];
  let good = assembly "  valid selected instructions  " true in
  let result = Guard.prepare_guard ~system_prompt:"" ~composed_context:(Some (fun () -> Some good))
      {Guard.system_prompt_override=A.system_prompt_override ~previous:(Some "  valid selected instructions  ") good} in
  check "nonblank selected override and exact Goal bytes remain admitted"
    (result = Ok ("  valid selected instructions  \n\n" ^ goal));
  let stale = assembly "" true in
  check "a stale issuer cannot replace a different legitimate override"
    (Guard.prepare_guard ~system_prompt:"" ~composed_context:(Some (fun () -> Some stale))
      {Guard.system_prompt_override=Some "DIFFERENT_VALID_OVERRIDE"} = Ok "DIFFERENT_VALID_OVERRIDE");
  check "final selected System guard remains active"
    (refused (Guard.prepare_guard ~system_prompt:"BASE" ~composed_context:(Some (fun () -> Some good))
      {Guard.system_prompt_override=Some ""}));
  Printf.printf "%d actual-source assembler/Host guard checks passed\n" !checks
'''

with tempfile.TemporaryDirectory(prefix="masc-official-blank-source-") as temporary:
    directory = Path(temporary)
    sources, records = [], []

    def put(name, text, scope):
        (directory / name).write_text(text)
        sources.append(name)
        records.append({"compiled": name, "scope": scope, "sha256": hashlib.sha256(text.encode()).hexdigest()})

    for module in ["lib/types/prompt_block_id", "lib/keeper/keeper_context_layers", "lib/keeper/keeper_context_assembly"]:
        for extension in [".mli", ".ml"]:
            path = module + extension
            put(Path(path).name, (ROOT / path).read_text(), path)
    put("inference_utils.ml", sanitizer, "exact Safe_ops sanitizer fragment")
    put("string_util.ml", trim, "exact trim_nonempty fragment")
    put("request.ml", request, "exact pure request assembler fragment")
    prefix = ('type turn_params = {system_prompt_override:string option}\n'
              'type error = InvalidConfig of {field:string; message:string}\n'
              'let config_error ~field message = InvalidConfig {field;message}\n'
              'let ( let* ) = Result.bind\n'
              'let prepare_guard ~system_prompt ~composed_context turn_params =\n')
    put("baseline_guard.ml", prefix + guard(old) + "  Ok system_prompt\n", "exact baseline selected Host selection/guard; minimal typed ports")
    put("guard.ml", prefix + guard(new) + "  Ok system_prompt\n", "exact repaired selected Host selection/guard; minimal typed ports")
    (directory / "probe.ml").write_text(probe)
    built = subprocess.run(["ocamlfind", "ocamlc", "-package", "yojson,digestif.ocaml", "-linkpkg", *sources,
                            "probe.ml", "-o", "probe"], cwd=directory, capture_output=True, text=True)
    if built.returncode:
        print(built.stdout + built.stderr)
        raise SystemExit(built.returncode)
    ran = subprocess.run([str(directory / "probe")], cwd=directory, capture_output=True, text=True)
    print(ran.stdout + ran.stderr)
    (OUT / "official-blank-check.json").write_text(json.dumps({"scope": "Actual pure assembler + selected Host guard statements with minimal typed ports; not full Host.prepare_turn/hooks/SDK/vendor/default-lane execution",
        "baseline": BASE, "sources": records, "compile_exit": built.returncode,
        "compile_stderr": built.stderr, "run_exit": ran.returncode, "output": ran.stdout + ran.stderr}, indent=2) + "\n")
    raise SystemExit(ran.returncode)
