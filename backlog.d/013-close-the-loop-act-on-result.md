# Close the loop: approved work re-enters the meeting

Priority: P1 · Status: pending · Estimate: L

## Goal
An operator can act on a completed worker result during the live call — copy it, deliver it to a sink, or carry it into a downstream system — with every delivery recorded as an event and a receipt.

## Oracle
- [ ] The result card renders the artifact as legible structured content (headings/lists), not raw machine markdown, with the re-quoted prompt / segment IDs / "fake fixture" lines stripped and long bodies clamped behind an expander.
- [ ] The operator has working primary actions on a result: Copy result, Open artifact (a real link, not `<small>` text).
- [ ] At least one approval-gated "deliver result" action exists (copy-to-meeting-chat as the zero-egress default), emitting an `artifact.delivered` event + receipt, enforced server-side.
- [ ] Cross-meeting follow-up memory v1: open commitments (approved proposals without a delivered/closed artifact) project across meetings and feed the `ProposalAgent` as context.

## Children
1. Make the artifact actionable + legible in the UI: replace the inert `ResultCard` (`ui/src/main.tsx:1200`, `uri` as `<small>`) with a structured body + Copy/Open actions; clamp long results. *(Hours; immediate dogfood value — the evangelism trigger.)*
2. Add an operator-initiated, server-owned, approval-gated "deliver result" action with a zero-egress default (clipboard / meeting chat); every delivery is an `artifact.delivered` event + receipt (reuse the backlog-008 approval pattern).
3. One real downstream connector behind the worker seam (GitHub issues / Linear / calendar — operator's actual stack) as an OpenCode-dispatched, approval-gated action.
4. Cross-meeting follow-up memory v1: project open commitments across meetings from the SQLite ledger; feed to `ProposalAgent` so the next call surfaces "still open from last time."

## Notes
**Why:** Product Strategist + Operator Experience lanes converged independently: the wedge ("it ACTS during the meeting") is built but the loop is OPEN — the worker produces an artifact that renders as a wall of raw markdown in an inert side panel (`ui/src/main.tsx:1200-1211`; `artifact.uri` as `<small>`; `.result-card p` has no clamp, `styles.css:699-705`; see `docs/evidence/ui-visual-qa/completed-desktop.png`). This is the gap between "neat demo" and "I run this every meeting." The evangelism trigger is child #1 alone: the first time the operator pastes a grounded, evidence-cited result into the meeting chat before the call ends. Child #4 (cross-meeting memory from the existing append-only ledger) is the durable moat no notes app has. Backchains from the vision JTBD "reports back with visible status and receipts" — the missing verb is *act on* the report.
