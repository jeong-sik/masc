# Dashboard Goal Pipeline Overflow

- Date: 2026-03-24
- Issue: #2724
- URL: http://127.0.0.1:8935/dashboard#workspace?section=planning

## Symptom

Long goal titles in the planning dashboard goal pipeline cards overlap the right-side status badge area.

## Reproduction

1. Open the planning dashboard.
2. Expand the goal pipeline section.
3. Observe a long-title goal such as `QA-LONG-DESC-TEST ...`.

## Suspected Cause

The title/content column is not constrained against the status badge column, so wrapping spills horizontally into the badge area.

## Tried

This pass fixed the backlog task card CSS contract and kanban clipping. The goal pipeline overflow remained visible after the patch and was split out as a separate issue.
