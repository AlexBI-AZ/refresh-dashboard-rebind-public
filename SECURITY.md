# Security and local data

This repository must not contain access tokens, Power Automate trigger URLs,
workspace/dataset/dataflow IDs, PBIP project paths, email recipient lists, or
logs. The local files that can contain those values are listed in `.gitignore`.

The Power Automate URL used by `REFRESH_EMAIL_WEBHOOK_URL` is a bearer secret:
anyone who obtains it may be able to invoke the flow. Store it only as a local
user environment variable or an approved secret store; never commit or paste
it into an issue. Rotate the trigger URL immediately if it is exposed.

Before publishing, run `git status` and review the staged diff. If a secret is
committed or pushed, revoke or rotate it before doing anything else. Do not
report a live secret in a public issue.
