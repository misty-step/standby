# AI Execution Security Evidence

This directory stores receipts for backlog item 008:

- unauthenticated local mutation requests fail;
- hostile browser origins cannot approve work;
- same-origin authenticated requests still drive normal proposal approval;
- approval actor identity is bound by the server, not request JSON;
- network-capable workers require a per-job consent event before dispatch;
- cloud/model worker prompts are redacted before launch.

Run:

```sh
scripts/verify-ai-execution-security.sh
```

The default repo gate runs the same script with a temporary evidence directory so
normal verification does not churn these receipts.
