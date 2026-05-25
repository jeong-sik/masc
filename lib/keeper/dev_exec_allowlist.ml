module Bin = Masc_exec.Bin

let names = List.map Bin.name_of_known

let dev_bins =
  Bin.
    [ Cat
    ; Cargo
    ; Cmake
    ; Cut
    ; Dune_local_sh
    ; Echo
    ; Env
    ; File
    ; Find
    ; Git
    ; Go
    ; Gofmt
    ; Gradle
    ; Grep
    ; Head
    ; Java
    ; Javac
    ; Ls
    ; Make
    ; Mvn
    ; Node
    ; Npm
    ; Ninja
    ; Npx
    ; Opam
    ; Pip
    ; Pnpm
    ; Printf
    ; Pwd
    ; Pyright
    ; Pytest
    ; Python
    ; Python3
    ; Rg
    ; Ruff
    ; Rustc
    ; Sed
    ; Sort
    ; Stat
    ; Tail
    ; Tr
    ; Uniq
    ; Uv
    ; Wc
    ; Which
    ; Yarn
    ]
;;

let code_shell_extra_bins =
  Bin.[ Diff; Patch; Mkdir; Ocamlfind; Tsc ]
;;

let code_shell_bins = dev_bins @ code_shell_extra_bins

let readonly_bins =
  Bin.
    [ Cat
    ; Cut
    ; Echo
    ; Env
    ; File
    ; Find
    ; Grep
    ; Head
    ; Ls
    ; Printf
    ; Pwd
    ; Rg
    ; Sed
    ; Sort
    ; Stat
    ; Tail
    ; Tr
    ; Uniq
    ; Wc
    ; Which
    ]
;;

let dev = names dev_bins
let code_shell = names code_shell_bins
let readonly = names readonly_bins

let is_dev_allowed name = List.mem name dev
let is_readonly_allowed name = List.mem name readonly
