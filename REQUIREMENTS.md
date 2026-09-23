# Power BI Dashboard Control Panel Requirements

This document defines the required behavior for the local Power BI Refresh & Rebind dashboard. It is the acceptance specification for version 0.3.0 and later.

## 1. Product boundaries

The dashboard contains three independent functions:

- **Rebind** edits GUID references in local PBIP project files. It must work without Microsoft authentication, an access token, MSAL.PS, or internet access.
- **Refresh** calls the Power BI REST API. It requires MSAL.PS, internet access, and an authenticated Microsoft account with the necessary Power BI permissions.
- **Partition Refresh** submits an enhanced refresh for exact historical partitions and monitors the accepted request by ID. It shares Refresh authentication but has independent profiles, status, polling, and logs.

Authentication required by Refresh must never block access to Rebind.

### Partition Refresh contract

- The request body must contain `type: full`, `commitMode: transactional`, Boolean `applyRefreshPolicy: false`, and one exact table/partition object per requested partition. It must not contain `notifyOption`.
- Workspace and dataset IDs must be valid GUIDs; table and partition names must be nonblank; duplicate partition names are rejected.
- The UI must show a final real-refresh confirmation and prevent double submission. The server must independently reject concurrent submission.
- Accepted request state must persist without tokens. Status and history routes use GET only and must never resubmit the refresh.
- Display request ID, timestamps, general and extended status, attempts, object statuses, and engine messages when returned. `Unknown` plus `InProgress` is a normal active state.
- Authentication, semantic-model permissions, and supported Premium/PPU/Embedded capacity are required. An accepted request continues server-side after dashboard disconnection.

## 2. Startup and authentication

The following behavior is required:

1. `launch.bat` starts the local server without installing MSAL.PS or requesting authentication.
2. The HTTP listener starts and the dashboard opens in the browser without waiting for a token or device-code login.
3. Rebind is fully usable when the authentication state is `Not Authenticated`.
4. Authentication warnings and status badges are hidden while the Rebind tab is active.
5. Authentication is requested only after the user selects **Authenticate for Refresh** on the Refresh tab.
6. A cached MSAL token or valid `.token` file may be reused for Refresh.
7. If no valid token exists, the device-code flow is shown in the server console.
8. If MSAL.PS is unavailable, Refresh explains how to install it while Rebind remains available.

## 3. Rebind input requirements

Before Scan can start, the user must provide:

- An existing local PBIP project folder.
- At least one mapping with a supported type: `Workspace`, `Dataflow`, or `Dataset`.
- A valid old GUID and a valid new GUID for every submitted mapping.

The server must reject:

- A missing or non-directory report path.
- A folder with no `.pbip`, `.Report`, or `.SemanticModel` item.
- Malformed GUIDs.
- A mapping whose old and new GUIDs are identical.
- Duplicate old GUID mappings.
- Chained mappings where one mapping's new GUID is another mapping's old GUID. These can cause sequential replacement contamination and must be split into separate runs.

Client-side validation is for usability only. The server must enforce the same safety rules independently.

## 4. Scan behavior

Scan is a read-only operation.

It must:

1. Recursively inspect `.tmdl` and `.json` files under the selected PBIP folder.
2. Exclude `.pbi` cache content and generated cache files.
3. Match GUIDs case-insensitively.
4. Record each mapping's occurrence count, affected files, line context, and ambiguity warnings.
5. Detect when a proposed new GUID already exists in the project.
6. Store a signature of the scanned path and normalized mappings.
7. Preserve the existing technical log and complete all final log entries before marking Scan complete.
8. Never modify PBIP project files.

Apply must remain disabled if Scan finds no old-GUID occurrences.

## 5. Plain-language Scan summary

The technical Rebind log must remain available as the detailed diagnostic record. A separate plain-language summary must appear after Scan.

The summary must show:

- Files inspected.
- Files containing old GUIDs.
- Proposed replacement count.
- Number of items requiring review.
- Clear explanations for zero-hit mappings, existing new GUIDs, or ambiguous JSON matches.

The user must receive two explicit choices:

- **Continue with Apply** — proceed with replacement and verification.
- **Do not continue** — stop without changing files.

Choosing **Do not continue** must:

- Clearly state that nothing was changed.
- Disable Apply in the UI.
- Invalidate the scan signature on the server.
- Require a new Scan before any later Apply request.

## 6. Apply behavior

Apply is permitted only when:

- The latest server state is a completed Scan.
- The Scan found at least one occurrence.
- The current path and mappings exactly match the signed Scan request.
- No other Rebind operation is running.

If the user edits the folder path, mapping type, old GUID, or new GUID after Scan, the Scan is invalid and must be repeated.

Apply must:

1. Replace old GUIDs case-insensitively in the targeted `.tmdl` and `.json` files.
2. Prevent concurrent Scan or Apply workers from sharing and overwriting the same worker/status files.
3. Pass worker parameters through encoded structured data rather than interpolating user-controlled paths into executable PowerShell source.
4. Count replacements by mapping and file.
5. Re-scan all target files after replacement.
6. Mark verification successful only when every old GUID is absent.
7. Report any remaining old GUID with its file and line number.

## 7. Plain-language Apply summary

After Apply, a separate summary must show:

- Whether Rebind completed and verification passed.
- Files changed.
- Replacements made.
- Mappings processed.
- Remaining old-GUID locations.

On success, the user must be told to open the PBIP project in Power BI Desktop and verify live connectivity.

On failure, the user must be told that no automatic retry occurred and that the technical log should be reviewed before running a fresh Scan.

## 8. Local API and security

- The server must listen on `localhost`, not on external network interfaces.
- The UI must use `window.location.origin` so a configured non-default port continues to work.
- Cross-origin requests must be rejected.
- API responses must not advertise wildcard CORS access.
- Mutation endpoints must enforce their HTTP method and validate their request body.
- The server must reject a second Rebind operation while one is running.

## 9. Profiles and local state

- Refresh and Rebind profiles remain independent.
- Profile names and values displayed in generated HTML must not be executable as inline JavaScript.
- Selecting, creating, deleting, or editing a Rebind profile invalidates any previous Scan decision.
- Deleting a Rebind profile must reset the form to a safe blank mapping.
- `.token`, local profile files, status files, logs, generated worker scripts, and `.env*` files must remain excluded from Git.

## 10. Acceptance checks

The implementation is acceptable only when all of the following pass:

- The PowerShell server parses without syntax errors.
- The JavaScript embedded in `index.html` parses without syntax errors.
- The dashboard root returns HTTP 200 while unauthenticated.
- The Rebind tab and controls are visible and usable while unauthenticated.
- Scan is read-only and produces the plain-language decision summary.
- **Do not continue** leaves the fixture unchanged and causes a later Apply request to be rejected.
- An Apply with parameters changed after Scan is rejected.
- A valid Apply replaces the expected GUIDs and verification reports zero remaining old GUIDs.
- Two near-simultaneous Rebind requests result in exactly one worker starting.
- Chained mappings and non-PBIP folders are rejected.
- A cross-origin mutation request receives HTTP 403.
- The original cloned repository remains unchanged when development is performed in the isolated copy.

## 11. Project files implementing these requirements

- `launch.bat` — starts the dashboard without authentication setup.
- `server.ps1` — local HTTP API, optional Refresh authentication, Rebind validation, worker coordination, replacement, and verification.
- `index.html` — Refresh/Rebind UI, authentication action, technical logs, and plain-language summaries.
- `README.md` — user instructions.
- `setup-auth.ps1` — optional Refresh authentication helper.

