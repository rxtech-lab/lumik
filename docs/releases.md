# Lumik releases

The Git remote is `https://github.com/rxtech-lab/lumik.git`.

- **Xcode Build** builds macOS and iOS Simulator on every push. It never runs UI tests.
- **Create Release** previews the next version on pushes to `main`. Manually dispatch it on `main` to have semantic-release analyze commits since the last release, select the version, generate release notes, and create a `vX.Y.Z` tag and draft release. No version input is needed. It explicitly dispatches macOS Release at the new tag (GitHub's built-in token cannot trigger another push workflow). Other branches cannot publish through this workflow.
- **macOS Release** also runs for independently pushed `v*` tags. Only stable semantic versions are accepted. It archives a universal Mac app, signs Sparkle helpers, notarizes/staples the app and DMG, validates the Ed25519 feed signature, publishes the GitHub release, and deploys the update site.

XcodeGen (`ios/project.yml`) is the source of truth for the Xcode project. Use `xcodegen generate --spec ios/project.yml` after changes. Sparkle is filtered to macOS. Debug/local builds without a public key do not start the updater.

## Commit-driven versions

The root `.releaserc` configures commit analysis, release notes, and draft GitHub releases. Use conventional commit messages:

- `fix: correct PDF import` produces a patch release.
- `feat: add scanner discovery` produces a minor release.
- A `BREAKING CHANGE:` footer produces a major release.
- `docs:`, `chore:`, and `ci:` alone do not produce a release.

The highest applicable change determines the next version. Without an existing release tag, semantic-release starts at `1.0.0`; the unreleased `0.1.0` in project/package metadata does not establish a release baseline. If there are no releasable commits, no tag, draft, or distribution run is created.

The macOS workflow stamps `MARKETING_VERSION` from the selected tag and uses its run number for `CURRENT_PROJECT_VERSION`. It publishes the draft only after signing, notarization, and feed verification. Version bumps are not committed back to the source tree. If distribution fails after creating the draft, rerun the failed macOS Release run, or manually dispatch macOS Release at that existing tag.

This flow uses the built-in `GITHUB_TOKEN` with contents/actions write permissions; `RELEASE_TOKEN` is not required. Issue and pull-request release comments are disabled.

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
