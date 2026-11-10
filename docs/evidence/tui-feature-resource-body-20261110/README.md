# Narrow Resources report reading

These are unchanged native PTY text/ANSI captures at 36 columns by 20 rows,
not GUI screenshots. Both display the same private, API-published Markdown
fixture. Its visible text identifies it as an isolated sample, not Keeper work.

- [Before](before-36x20.txt): source
  `d58145cf97b6c47fa81d1aa4d9723f98022a7185`, captured after the report opened.
  Confirmation, private sharing and part selection fill the page; no report
  title or body is visible.
- [After](after-36x20.txt): source
  `6157b06b2b2c6b4f5ac1bfeb6a1c62c362e73005`. The same state information
  remains, followed by the report title and first body line. Only generated
  empty status/part-selection spacing was removed; original text was not trimmed.

[manifest.json](manifest.json) records the original capture times and SHA-256
values. The copied plain and ANSI files retain their capture bytes. This is a
curated provenance record derived from the local observation ledgers.

Both matching server/TUI pairs came from `Minimal manual checks`
(`pr-check.yml`, `main`, `resource-reading`):

- [Run 42782496683](https://github.com/jeong-sik/masc/actions/runs/42782496683):
  workflow head `111e082eba119ab2b0291bd02667392ef8a2d019`, selected source d581,
  completed successfully.
- [Run 42789874637](https://github.com/jeong-sik/masc/actions/runs/42789874637):
  workflow head `f587687402c8f1fd10f631f260eb76626fdfd98d`, selected source 6157,
  completed successfully. Its four existing targeted suites were
  `test_tui_published_reports`, `test_tui_resource_document_search`,
  `test_tui_resource_image_admission` and `test_tui_resource_images`.

The later documentation commit does not change executable inputs. These results
are not full regression, production installation, installed GUI, the separate
save-result change, or completion of the 23-surface audit. Longer required
unknown/uncertain/recovery warnings may still precede the body.
