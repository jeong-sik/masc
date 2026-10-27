(* Authored portable reproduction adapter; this exact driver was not executed. *)
#use "topfind";;
#require "yojson,digestif.c,mtime.clock";;
#mod_use "reproduction/fixture_carrier.ml";;
#mod_use "reproduction/canonical_list_digest.ml";;
#mod_use "reproduction/old_oracle_carrier.ml";;
#mod_use "reproduction/benchmark.ml";;
Benchmark.run ();;
