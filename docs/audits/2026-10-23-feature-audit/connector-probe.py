from pathlib import Path
import subprocess
import re
import argparse
import tempfile

parser = argparse.ArgumentParser(description="Source-slice policy reproduction with local filesystem/lock/registration adapters; not a live gateway test.")
parser.add_argument("--before", required=True)
parser.add_argument("--after", required=True)
parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
args = parser.parse_args()
root = args.repo
scratch = tempfile.TemporaryDirectory(prefix="masc-policy-probe-")
out = Path(scratch.name)

def read(path):
    return subprocess.check_output(['git', '-C', str(root), 'show', args.after + ':' + path], text=True)

def before(path):
    return subprocess.check_output(['git', '-C', str(root), 'show', args.before + ':' + path], text=True)

def between(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]

script = r'''
#directory "+unix";;
#load "unix.cma";;
#directory "__YOJSON_DIR__";;
#load "yojson.cma";;
module Eio = struct
  module Mutex = struct
    let create () = ()
    let use_rw ~protect:_ _ f = f ()
  end
  module Cancel = struct exception Cancelled of exn end
end;;
module Eio_guard = struct
  let with_mutex _ f = f ()
  let with_mutex_ro _ f = f ()
end;;
module Common = struct let masc_dir_from_base_path ~base_path = Filename.concat base_path ".masc" end;;
module Log = struct
 module Config = struct let error fmt = Printf.ksprintf ignore fmt let warn fmt = Printf.ksprintf ignore fmt end
 module Server = Config
 module Keeper = Config
end;;
module Json_util = struct let kind_name _ = "non-string" end;;
(* Local filesystem adapters. No Eio scheduler or append-handle cache here. *)
module Fs_compat = struct
 let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)
 let save_file_atomic path contents =
  let tmp = path ^ ".candidate" in
  Out_channel.with_open_bin tmp (fun oc -> output_string oc contents);
  Unix.rename tmp path; Ok ()
 let load_file path = In_channel.with_open_bin path In_channel.input_all
 let load_jsonl path =
  if Sys.file_exists path then In_channel.with_open_bin path (fun ic ->
   In_channel.input_lines ic |> List.map Yojson.Safe.from_string) else []
 let append_jsonl path value =
  let oc = open_out_gen [Open_wronly;Open_append;Open_creat;Open_binary] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
   output_string oc (Yojson.Safe.to_string value ^ "\n"))
end;;
'''
script += 'module Runtime_params = struct\n' + read('lib/runtime_params.ml') + '\nend;;\n'
for name in ['discord', 'slack']:
    source = read(f'lib/gate/{name}_gateway_state.ml')
    policy = between(source, 'type trigger_policy =', 'type config =')
    if name == 'discord':
        policy += between(source, 'let parse_trigger_policy s =', '(* ── Opaque state')
    script += 'module ' + name.capitalize() + '_gateway_state = struct\n' + policy + '\nend;;\n'

settings = read('lib/runtime_settings.ml')
script += 'module Runtime_settings = struct\n'
script += between(settings, 'let register_enum ', 'let dashboard_max_path_length')
script += between(settings, 'let discord_trigger_policy_configured =', '(* ── schedule retention')
script += '''
let keeper_keepalive_interval_sec = Runtime_params.register ~key:"keeper.interval" ~default:(fun () -> 10)
 ~validate:(fun _ -> Ok ()) ~serialize:(fun n -> `Int n) ~deserialize:(function `Int n -> Ok n | _ -> Error "int") ()
end;;
'''

for name in ['discord', 'slack']:
    path = f'lib/gate/channel_gate_{name}_state.ml'
    original = before(path)
    end = 'let bot_token_opt' if name == 'discord' else '(* Outbound REST'
    script += 'module Channel_gate_' + name + '_state = struct\n'
    script += between(original, 'let trigger_policy_ref ', end) + '\nend;;\n'
    expression = re.search(r'trigger_policy = (Runtime_params.get Runtime_settings\.[a-z_]+);', read(path)).group(1)
    script += f'let {name}_projection () = {expression};;\n'

activity = 'lib/server/server_routes_http_routes_activity.ml'
for variant, source in [('Before', before(activity)), ('After', read(activity))]:
    script += 'module ' + variant + ' = struct\nlet keeper_cadence_effect_mu = Eio.Mutex.create ()\n'
    script += between(source, 'type param_effect =', 'let wake_keepers_after_runtime_param_change')
    script += 'let wake_keepers_after_runtime_param_change ~base_path:_ ~param_key:_ ~previous_interval_s:_ ~new_interval_s:_ = None\n'
    script += between(source, 'let runtime_param_effect_fields', 'let respond_board_reaction_result') + '\nend;;\n'

for name in ['discord', 'slack']:
    gateway = name.capitalize() + '_gateway_state'
    state = 'Channel_gate_' + name + '_state'
    for variant in ['Before', 'After']:
        display = f'Option.get ({state}.get_trigger_policy ())' if variant == 'Before' else f'{name}_projection ()'
        expected = 'Mention_or_thread' if variant == 'Before' else 'Mention_only'
        script += f'''
let () =
 let module G = {gateway} in
 let param = Runtime_settings.{name}_trigger_policy in
 let root = Filename.temp_dir "connector-{name}-{variant.lower()}-" "" in
 Runtime_settings.set_{name}_trigger_policy_configured G.Mention_or_thread;
 Runtime_params.clear param;
 {state}.set_trigger_policy G.Mention_or_thread;
 let key = Runtime_params.key param in
 let mutate ~base_path fn = match {variant}.mutate_runtime_param_with_effects ~base_path ~param_key:key fn with Ok _ -> () | Error e -> failwith e in
 mutate ~base_path:root (fun () -> Runtime_params.set_by_key_with_change ~base_path:root key (`String "all"));
 let retained = {display} in
 assert (retained = G.All);
 mutate ~base_path:root (fun () -> Runtime_params.clear_by_key_with_change ~base_path:root key);
 assert ({display} = G.Mention_or_thread);
 assert (retained = G.All);
 let failing_base = Filename.concat root "audit-failure" in
 Fs_compat.mkdir_p (Filename.concat (Common.masc_dir_from_base_path ~base_path:failing_base) "param_audit.jsonl");
 let failed = try mutate ~base_path:failing_base (fun () -> Runtime_params.set_by_key_with_change ~base_path:failing_base key (`String "mention_only")); false with Sys_error _ | Unix.Unix_error _ -> true in
 assert failed;
 let runtime = Runtime_params.get param in
 let display = {display} in
 assert (runtime = G.Mention_only);
 assert (display = G.{expected});
 Printf.printf "{name} {variant}: audit_failed=%b runtime=%s display=%s retained=%s\\n" failed (G.trigger_policy_to_string runtime) (G.trigger_policy_to_string display) (G.trigger_policy_to_string retained)
;;
'''

script = script.replace('__YOJSON_DIR__', subprocess.check_output(['ocamlfind', 'query', 'yojson'], text=True).strip())
probe = out / 'policy-proof.ml'
probe.write_text(script)
result = subprocess.run(['ocaml', '-noinit', str(probe)], capture_output=True, text=True)
(out / 'policy-proof.txt').write_text(result.stdout + result.stderr)
print(result.stdout + result.stderr)
raise SystemExit(result.returncode)
