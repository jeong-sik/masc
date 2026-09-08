# Browser skill live verification — 2026-09-08

The distributable package is [skills/browser-lanes](../../../skills/browser-lanes/SKILL.md).
The existing native MASC `project-masc/browser-lanes/browser-lanes` skill was updated
through the Skill editor with an exact content-revision precondition and published.
The three referenced resources are installed beside SKILL.md. This package is external
skill data; it is not embedded into the MASC binary.

Keeper request example:

> browser-lanes 스킬을 읽고 MDN WebDriver 문서를 열어 줘. 링크 이동과 뒤로/앞으로,
> 새로고침, 스크롤을 확인하고 화면을 캡처해서 설명해 줘.

## Measured evidence

- [Publication](publication.json): production and scratch effective catalogs contain the
  same revision; all four installed files match the package bytes. Resource hashes are
  recorded separately because the skill content revision does not identify their bytes.
- [Fresh skill-enabled Keeper](skill-live.json): 22 actual calls, 22 successes, zero errors.
  `keeper_skill` loaded the exact body and `references/verification.md` before browser use.
  Observed-selector click, back/forward/reload with reads, 400px scroll, capture, analysis
  of that artifact, final read/capture and own-session close were verified.
  The final Keeper artifact equals the independently retrieved HTTP [PNG](mdn.png).
- [Two earlier guided MDN cases](mdn-guided.json): 44 calls, 42 successes and two initial
  closed-session guards. Both requested workflows completed. No `keeper_skill` read
  occurred; detailed inline instructions were present. Keep these separate from skill use.
- [Owned advanced fixture](advanced-lab.json): 45 calls, 41 successes and four failures
  including the initial session setup failure. A driver launch with `--websocket-port 0`
  recovered BiDi connection without changing the server binary. Nested frames, dialogs,
  input and file transfer were exercised. One image-analysis structured-output error was
  recovered by a later call. Requested content was 51 bytes; Write produced 50 bytes
  without the final LF. Actual 50-byte transport fidelity passed; requested content failed.
  Official Keeper shutdown removed the previously running exact owned VM, verified by
  a successful container inventory, without manual VM stop/delete.

All browser measurements above use source
`9ab0f606e7161ff543bdf3f37b86a18acf1efd23`, server SHA-256
`4e59e4bcb7cf86f1b8be51f4c8f870d6a0d6058950079b15ad161e614081dea6`,
runtime instance `01a07ec0-b09e-7000-bc34-f1d32f363465`, and
`ollama_cloud.ollama-cloud-glm-5-3-flash` on Zen through geckodriver.
The runtime source contains shutdown fix [#34169](https://github.com/jeong-sik/masc/pull/34169).
Later prompt/schema guidance [#34248](https://github.com/jeong-sik/masc/pull/34248)
is not embedded in that measured binary. Driver launcher documentation/probe fix
[#34249](https://github.com/jeong-sik/masc/pull/34249) describes the measured port option.

## Limits

This establishes skill loading and practical usability in one fresh Keeper case, not
causal improvement across models. Downloads and physical TUI rendering were not tested
in this run. Generic CSS unescaping and automatic newline insertion were not introduced.
Metadata retains failed attempts; no full page bodies, private browser data, provider
reasoning, or credentials are included. Trace hashes identify retained local raw evidence;
public JSON supplies the selected call metadata, not the full raw transcripts.
