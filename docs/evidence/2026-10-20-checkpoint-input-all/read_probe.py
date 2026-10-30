"""Compare actual checkpoint byte readers using real regular-file I/O.

Only Eio offload and the file-identity adapter are stubbed. Requires git and
OCaml 5.5; does not invoke Dune or validate the native MASC dependency graph.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--before', required=True)
parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[3])
args = parser.parse_args()
relative = 'lib/keeper/keeper_checkpoint_store.ml'
before = subprocess.check_output(['git', 'show', args.before + ':' + relative], cwd=args.repo, text=True)
after = (args.repo / relative).read_text()


def reader(source):
    return source.split('let load_canonical_bytes_strict path =', 1)[1].split(
        'let load_canonical_bytes_and_checkpoint_strict path =', 1)[0]


stubs = r'''
type error = Io_error of string
module Eio = struct module Cancel = struct exception Cancelled of exn end end
module Eio_guard = struct let run_in_systhread ~label:_ read = read () end
let canonical_identity_of_stats stat =
  stat.Unix.st_dev, stat.Unix.st_ino, stat.Unix.st_size,
  stat.Unix.st_mtime, stat.Unix.st_ctime
'''
checks = r'''
let path = Sys.argv.(1)
let write bytes = Out_channel.with_open_bin path (fun channel -> output_string channel bytes)
let content reader = match reader path with
 | Ok (Some (_, bytes)) -> bytes
 | _ -> failwith "expected canonical bytes"
let () =
 List.iter (fun length ->
  let bytes = String.init length (fun index -> Char.chr (index mod 256)) in
  write bytes;
  assert(content Old.load_canonical_bytes_strict = bytes);
  assert(content New.load_canonical_bytes_strict = bytes);
  assert(Old.load_canonical_bytes_strict path = New.load_canonical_bytes_strict path)
 ) [0; 1; 65535; 65536; 65537; 1048593; 8388608; 33554432];
 write "한글\n\000\"tail";
 assert(content Old.load_canonical_bytes_strict = content New.load_canonical_bytes_strict);
 Sys.remove path;
 assert(Old.load_canonical_bytes_strict path = Ok None);
 assert(New.load_canonical_bytes_strict path = Ok None);
 Unix.mkdir path 0o700;
 assert(Old.load_canonical_bytes_strict path = New.load_canonical_bytes_strict path);
 Unix.rmdir path;
 Unix.symlink (path ^ ".missing") path;
 assert(Old.load_canonical_bytes_strict path = New.load_canonical_bytes_strict path);
 Sys.remove path;
 Printf.printf "exact_bytes_cases=9 missing_directory_symlink=equal\n%!"
let bench label reader =
 Gc.full_major ();
 let before = Gc.allocated_bytes () and started = Unix.gettimeofday () in
 let bytes = content reader in
 let allocated = Gc.allocated_bytes () -. before in
 assert(String.length bytes = 33554432);
 Printf.printf "%s elapsed_ms=%.3f allocated_bytes=%.0f\n%!"
  label ((Unix.gettimeofday () -. started) *. 1000.) allocated
let () =
 write (String.make 33554432 'x');
 bench "before-32MiB" Old.load_canonical_bytes_strict;
 bench "after-32MiB" New.load_canonical_bytes_strict;
 Sys.remove path
'''
source = stubs
for name, original in [('Old', before), ('New', after)]:
    source += '\nmodule ' + name + ' = struct\nlet load_canonical_bytes_strict path =' + reader(original) + '\nend\n'
source += checks
with tempfile.TemporaryDirectory(prefix='masc-checkpoint-read-') as directory:
    script = Path(directory) / 'read.ml'
    script.write_text(source)
    result = subprocess.run(['ocaml', '-noinit', '-I', '+unix', 'unix.cma', str(script), str(Path(directory) / 'canonical')], text=True, capture_output=True)
print(result.stdout + result.stderr)
raise SystemExit(result.returncode)
