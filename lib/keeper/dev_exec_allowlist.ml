module Exec_program = Masc_exec.Exec_program

let names = List.map Exec_program.name_of_known

let dev_programs =
  Exec_program.
    [ Cat
    ; Cargo
    ; Cmake
    ; Cut
    ; Dune_local_sh
    ; Echo
    ; Env
    ; File
    ; Find
    ; Gh
    ; Git
    ; Go
    ; Gofmt
    ; Gradle
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

let code_shell_extra_programs =
  Exec_program.[ Diff; Patch; Mkdir; Ocamlfind; Tsc ]
;;

let code_shell_programs = dev_programs @ code_shell_extra_programs

let readonly_programs =
  Exec_program.
    [ Cat
    ; Cut
    ; Echo
    ; Env
    ; File
    ; Find
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

let dev = names dev_programs
let code_shell = names code_shell_programs
let readonly = names readonly_programs

let is_dev_allowed name = List.mem name dev
let is_readonly_allowed name = List.mem name readonly
