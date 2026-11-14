# Third-party notices

MASC source code is MIT-licensed. The bundled fonts retain their SIL Open Font
License 1.1 and copyright notices. Complete upstream notice wording ships
beside the font files in the dashboard public assets; Vite copies that directory
into the dashboard release bundle.

| Font family | Bundled notice | Upstream |
|---|---|---|
| EB Garamond | [OFL](dashboard/public/assets/fonts/EBGaramond-OFL.txt) | [EB Garamond](https://github.com/octaviopardo/EBGaramond12) |
| JetBrains Mono | [OFL](dashboard/public/assets/fonts/JetBrainsMono-OFL.txt) | [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) |
| Noto Sans KR | [OFL](dashboard/public/assets/fonts/NotoSansKR-OFL.txt) | [Google Fonts distribution](https://github.com/google/fonts/tree/main/ofl/notosanskr) |
| Cinzel | [OFL](dashboard/public/assets/fonts/Cinzel-OFL.txt) | [Cinzel](https://github.com/NDISCOVER/Cinzel) |

The notices come from Google Fonts `ofl/<family>/OFL.txt`, checked against
copyright metadata in the bundled fonts on 2026-09-08, with trailing whitespace
normalized. Font subset filenames
and CSS weights do not change their license.

## Statically linked OCaml libraries

The server, TUI and companion executables of a release link the OCaml runtime,
its standard library and opam packages statically. Each
`masc-runtime-<platform>.tar.gz` carries their notice files under
`licenses/ocaml/<package>/`, copied byte for byte from the top of its exact
source and from the files the package installed in the opam switch's doc
directory. A notice deeper in the source ships when it covers code vendored
into a linked library, such as libyaml in `yaml`. `licenses/ocaml/packages.json`
records each package's version, pinned commit, the SHA-256 of each file, where
it came from, and the nested notices left out with the reason.

`scripts/collect-ocaml-notices.py` takes the package set from dune's link rule
for each of those executables, so the set follows the build without a
hand-kept list. A linked package without a notice file stops the release, and
so does a nested notice that its `NESTED_NOTICES` table neither ships nor
excludes. The exceptions are the exact versions named in that script's
`NO_UPSTREAM_NOTICE`, whose upstream source has no such file; `packages.json`
lists them with that reason and no file.

## alphaTex terminal companion

`scripts/install-alphatex.sh` installs locked npm packages with their notices:
alphaTab 1.8.4 (MPL-2.0), alphaSkia 3.5.147 and its native platform libraries
(BSD-3-Clause), and alphaTab's Bravura font (SIL OFL-1.1). The optional default
Sonivox SoundFont retains `@coderline/alphatab/dist/soundfont/LICENSE`.
The official-source test examples in `tools/alphatex/test/upstream.test.mjs`
are attributed to the pinned alphaTab v1.8.4 source (MPL-2.0).

## Bundled Skill files

Built-in Skills ship inside the binary and are installed into a workspace's Skill
source. A file adapted from another project carries its notice in the same package.

| File | Notice | Upstream |
|---|---|---|
| `skills/root-cause-first/references/root-cause-tracing.md` | [MIT](skills/root-cause-first/references/superpowers-LICENSE.txt), Copyright (c) 2025 Jesse Vincent | [obra/superpowers](https://github.com/obra/superpowers) `skills/systematic-debugging/root-cause-tracing.md` |
