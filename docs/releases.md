# Lumik releases

The Git remote is `https://github.com/rxtech-lab/lumik.git`.

- **Xcode Build** builds macOS and iOS Simulator on every push. It never runs UI tests.
- **Create Release** is manually dispatched from Actions with a stable `vX.Y.Z` tag. It creates a draft release and explicitly dispatches macOS Release at the tag (GitHub's built-in token cannot trigger another push workflow).
- **macOS Release** also runs for independently pushed `v*` tags. Only stable semantic versions are accepted. It archives a universal Mac app, signs Sparkle helpers, notarizes/staples the app and DMG, validates the Ed25519 feed signature, publishes the GitHub release, and deploys the update site.

XcodeGen (`ios/project.yml`) is the source of truth for the Xcode project. Use `xcodegen generate --spec ios/project.yml` after changes. Sparkle is filtered to macOS. Debug/local builds without a public key do not start the updater.

## GitHub configuration

Set these repository or organization Actions secrets with access to `rxtech-lab/lumik`:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | Base64 Developer ID Application signing certificate, exported as P12 with its private key |
| `P12_PASSWORD` | P12 export password |
| `SIGNING_CERTIFICATE_NAME` | Full Developer ID Application identity name |
| `APPLE_ID` | Apple account for notarization |
| `APPLE_ID_PWD` | App-specific notarization password |
| `APPLE_TEAM_ID` | Apple Developer team ID (`P9KK452K8P` for this project) |
| `SPARKLE_KEY` | Base64 Sparkle Ed25519 signing seed; keep stable across releases |

Set Actions variable `SPARKLE_PUBLIC_KEY` to the matching public key. The release build embeds it in Info.plist, and feed validation rejects a mismatched signing key. Keep a secure backup of the private key. Never replace it casually after distributing an app.

No provisioning profile is needed for the current Developer ID app's sandbox, network, USB, and user-selected file entitlements. Additional restricted capabilities may change that.

## Update hosting

Cloudflare: DNS-only CNAME `update` → `rxtech-lab.github.io`.
GitHub Settings → Pages: source **GitHub Actions**, custom domain **update.lumik.dev**, enforce HTTPS once GitHub issues the certificate. Allow version tags in the `github-pages` environment deployment rules.

The repository is private, so its release assets are not anonymous downloads. Pages intentionally hosts the notarized DMG at `https://update.lumik.dev/vX.Y.Z/Lumik.dmg` alongside `appcast.xml` and release notes. Only generated `output/pages` is deployed; source code is excluded. Each deployment contains the current release only. Public downloads require public Pages access and must fit GitHub Pages size limits.

Commit and push the workflows before using Actions. Configure signing secrets before creating the first tag. The app's first signed release is a manual download; future versions use Sparkle's native update UI and the **Check for Updates…** app-menu command.

## Validation

Local builds: `xcodebuild -project ios/Lumik.xcodeproj -scheme Lumik -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build` (use `generic/platform=iOS Simulator` for iOS).

Feed tests: install Python `cryptography` and run `python3 scripts/ci/test_validate_appcast.py`. Tests cover a valid signature, tampered archive, wrong signing key, and incorrect download URL. Release generation also requires Python `markdown`.
