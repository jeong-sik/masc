# MASC agent core

This directory contains MASC's single-process agent loop, provider codecs,
tool execution, checkpoints, and exact-output primitives.

It is part of the `masc` package and is built in the same Dune project as the
coordinator. It is not a separately released SDK and has no compatibility
contract for external consumers.

The dependency direction is one-way: MASC application modules may depend on
`masc.agent_core`; code in this directory must not import MASC coordinator,
Keeper, Board, Gate, runtime.toml, authentication, or deployment modules.

The code was imported from `jeong-sik/oas` at commit
`7d916a23b8a69d89f3fb39068eeeb989265385d7` and renamed as a hard cut. No
legacy top-level compatibility facade is retained.
