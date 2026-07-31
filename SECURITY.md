# Security Policy

## Never publish secrets

Do not include real passwords, access tokens, cookies, private keys, server IP allowlists, database dumps, or `.env` files in issues or pull requests.

Use placeholders such as:

```text
<REDACTED>
YOUR_TOKEN_HERE
YOUR_PASSWORD_HERE
```

## Reporting a vulnerability

Report security-sensitive defects privately through GitHub's private vulnerability reporting feature when available. Do not publish a working exploit or real credentials in a public issue.

## Supported branch

Security fixes target the latest `main` branch.
