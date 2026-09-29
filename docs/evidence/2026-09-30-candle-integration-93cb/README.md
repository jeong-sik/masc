# Integrated native build failure

Run [36604111016](https://github.com/jeong-sik/masc/actions/runs/36604111016) tested head `93cb21097cb56e4757914db21287d335f5f57e5e`. The Test step failed.

The five TUI aliases failed before their scenarios ran: `bin/masc_tui.ml:10710` assigned a string where `Metrics_tail.load_error` was required. The same error then aborted the executable build. This is not a 46-suite behavioral result. Quiz ran 23 Python cases and the baseline collector ran four; both passed.

The compressed file preserves the entire original suite runner log. No remote portrait, currency or workspace history behavior is claimed from this run.
