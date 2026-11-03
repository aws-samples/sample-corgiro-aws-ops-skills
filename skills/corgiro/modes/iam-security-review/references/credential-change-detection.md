# Step 5b: Credential Change Detection

Show the operator which credentials were added, removed, or changed status since the last time each account was reviewed. Everything lives in run directories: this run writes a masked snapshot, and the next run reads it as its baseline. Nothing is written to `~/.corgiro/` — modes other than `setup-corgiro` and `account-coverage` only read state there.

## 1. Write this run's snapshot

Build the credential set from Step 3 — every access key (`access-keys.json`) and every service-specific credential (`service-specific-credentials.json`) — and write `./<run_id>/credential-snapshot.json`.

Key each credential by `h = first 16 hex chars of sha256("<accountId>:<credentialId>")`, computed in Step 3 from the full ID before masking and carried in the per-account files. The hash gives a stable identity across runs without persisting the full credential ID; the masked ID is for display only (masks collide too often to serve as a key).

Include only accounts whose credential listing succeeded. An account marked `partial` with credentials `unknown` (see Error Handling) is left out of `accounts`, so it never produces false "removed" entries.

```json
{
  "runId": "iam-security-review-YYYYMMDD-HHMMSS",
  "generatedAt": "<ISO8601>",
  "accounts": {
    "<accountId>": {
      "accessKeys":   [ { "h": "<16-hex>", "masked": "AKIA****WXYZ", "status": "Active", "created": "<ISO8601>", "user": "<name>" } ],
      "serviceCreds": [ { "h": "<16-hex>", "masked": "ACCA****WXYZ", "status": "Active", "created": "<ISO8601>", "user": "<name>", "service": "bedrock.amazonaws.com", "expires": "<ISO8601 or null>" } ]
    }
  }
}
```

## 2. Pick a baseline per account

List the run directories matching `<baseline_dir>/iam-security-review-*/credential-snapshot.json`, excluding the current run, newest first (the `run_id` timestamp sorts lexically). For **each account** in this run, its baseline is the newest prior snapshot whose `accounts` contains that account.

Choosing per account means a run scoped with `accounts` never erases another account's history: a later org-wide run still finds each account's last full baseline. An account with no baseline is listed as "first reviewed this run" and is not diffed.

Skip a snapshot that fails to parse or lacks `accounts`, and note it in the Methodology.

## 3. Diff and write `credential-diff.json`

For each account that has a baseline, compare by `h`, separately for access keys and service credentials:

- **added**: `h` present now, absent in the baseline
- **removed**: `h` present in the baseline, absent now
- **status changed**: same `h`, different `status` (`Active` / `Inactive` / `Expired`)

```json
{
  "runId": "<this run>",
  "accounts": {
    "<accountId>": {
      "baselineRunId": "<run_id or null>",
      "added":   [ { "type": "accessKey|serviceCred", "masked": "...", "user": "...", "service": "...", "status": "..." } ],
      "removed": [ { "type": "...", "masked": "...", "user": "..." } ],
      "statusChanged": [ { "type": "...", "masked": "...", "user": "...", "from": "Active", "to": "Inactive" } ]
    }
  },
  "noBaseline": [ "<accountId>" ],
  "totals": {
    "accessKeys":   { "now": 0, "active": 0, "added": 0, "removed": 0 },
    "serviceCreds": { "now": 0, "active": 0, "added": 0, "removed": 0 }
  }
}
```

`totals.*.added` / `removed` count only accounts that had a baseline. Record the distinct `baselineRunId` values for the Methodology.

## 4. Secure

Both files are covered by the run directory's `chmod 700` / `chmod 600`. They contain account IDs, user names, and masked credential IDs — no secrets.
