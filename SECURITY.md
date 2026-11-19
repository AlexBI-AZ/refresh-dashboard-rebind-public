# Security and local data

This repository must not contain access tokens, Power Automate trigger URLs,
workspace/dataset/dataflow IDs, tenant or client IDs, certificate thumbprints,
certificates, PBIP project paths, email recipient lists, real workspace or report
names, or logs. The local files that can contain those values are listed in
`.gitignore`; `*.example.json` and `validation/reports/example.config.json` show the
formats with fictional values.

## Email flow URL

The Power Automate URL used by `REFRESH_EMAIL_WEBHOOK_URL` is a bearer secret:
anyone who obtains it may be able to invoke the flow. `setup.bat` asks for it with
hidden input and stores it only as a user environment variable; never commit it,
put it in a file, or paste it into an issue. Rotate the trigger URL immediately if it
is exposed, then run `setup.bat` again with the new URL.

## Sign-in

- Device code: the sign-in is kept in a cache encrypted for the Windows user
  (`%LOCALAPPDATA%\PowerBIChainedRefresh\msalcache.bin3`). No token is written to the
  project folder.
- Certificate: `setup.bat` creates the key pair inside `Cert:\CurrentUser\My` with a
  non-exportable private key, so the key never leaves that PC. Only the public `.cer`
  is exported, for the app owner to upload to the app registration. Never create,
  copy or send a `.pfx`. Every certificate on one app signs in as that app and sees
  every workspace the app can reach; remove a PC's certificate from the app
  registration when the PC no longer needs it.

## Before publishing

Run `powershell -ExecutionPolicy Bypass -File .\release-check.ps1`, then run
`git status` and review the staged diff. If a secret is committed or pushed, revoke
or rotate it before doing anything else. Do not report a live secret in a public
issue.
