# Interface Sentinel repository instructions

- Preserve the existing `com.netctl` application and helper identities, allowlist contract, launchd domains, and migration behavior.
- Keep changes uncommitted until the user authorizes a commit; commit, push, PR creation, merge, release, deployment, and privileged installation each require authorization covering that operation.
- Keep the `Native build` PR check emitted for every PR. Run `build.sh`, plist validation, and strict codesign verification as defined in `.github/workflows/ci.yml`.
- CodeQL must trace the explicit Swift compilation in `build.sh`; verify successful Swift analysis at the reviewed revision.
- Hosted CI may compile and verify the bundle but must not launch the application, install a helper, modify launchd, or enforce interface policy.
- Changes to privileged paths, helper lifecycle, allowlists, quoting, launchd, or interface enforcement also require direct local macOS integration evidence on an explicitly authorized noncritical Mac with local recovery access.
