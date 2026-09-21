# GlowScript CI Monitor

A fork of [Octowatch](https://github.com/hbourget/Octowatch) with a local CI host dashboard for the GlowScript runners.

A lightweight, native macOS menu bar app that monitors your GitHub Actions workflow runs in real time.

Built with SwiftUI. No external dependencies. No tracking. No data collection.

![Octowatch Demo](demo_octowatch.png)

## Features

- **Menu bar status indicator** — see the state of your workflows at a glance
- **Multi-repo monitoring** — track workflow runs across multiple repositories
- **Configurable polling** — set your own refresh interval
- **Native notifications** — get notified when workflow runs complete (with distinct sounds for success and failure)
- **Secure by design** — your GitHub token is stored in the macOS Keychain and never leaves your machine

## Privacy

Octowatch is fully local. It does not collect, store, or transmit any data to external servers. Your GitHub Personal Access Token is stored exclusively in the macOS Keychain. Preferences are saved locally via UserDefaults. There is no analytics, no telemetry, no phone-home behavior of any kind.

## Requirements

- macOS 14.0 or later
- Swift 6.0+ (to build from source)
- A [GitHub Personal Access Token (fine-grained)](https://github.com/settings/tokens?type=beta) with **read-only** access to **Actions**. You can scope it to all repositories or only the ones you want to monitor — Octowatch lets you pick specific repos from within the app

## Installation

### Build from source

Clone the repository and use the provided Makefile:

```bash
git clone https://github.com/hbourget/Octowatch.git
cd Octowatch
make run
```

This builds a release `.app` bundle and launches it. The app lives in your menu bar — there is no Dock icon.

### Other make targets

```bash
make build    # Debug build
make release  # Release build
make bundle   # Build .app bundle (release) without launching
make open     # Launch an existing bundle (no rebuild)
make clean    # Remove build artifacts and .app bundle
```

## Usage

1. Launch Octowatch — it appears in your menu bar
2. Click the icon and sign in with your GitHub Personal Access Token
3. Select the repositories you want to monitor
4. Octowatch will poll GitHub Actions and update the menu bar indicator in real time

## Tech Stack

| | |
|---|---|
| **Language** | Swift 6.0 (strict concurrency) |
| **UI** | SwiftUI |
| **Architecture** | MVVM |
| **Dependencies** | None — stdlib, Foundation, SwiftUI, UserNotifications only |
| **Min. deployment** | macOS 14.0 |

## 🔒 Note on the macOS Keychain Prompt

Because Octowatch is currently a free, open-source project, the downloaded app is not signed with a paid Apple Developer Developer ID.

Because of this built-in macOS security feature, the system will ask for your permission the first time Octowatch tries to retrieve your GitHub token from the Keychain.

**To fix this:**
When the prompt appears, enter your Mac password and click **"Always Allow"**. macOS will remember this preference and the app will run silently in the background from then on.

> **Note:** If this project gets enough traction and users, I plan to purchase an official Apple Developer license to properly code-sign the app, which will prevent this prompt from appearing at all.

## Support

Questions, bug reports, or feature requests? Open an [issue](https://github.com/hbourget/Octowatch/issues).

## License

This project is licensed under the [MIT License](LICENSE).

## Local CI dashboard (Robert's build)

The existing click-to-open menu-bar interaction is preserved. The panel is now
920 × 720 points (clamped to the current display), with three local host cards,
workflow filters for all branches/main/pull requests, and active/failed/all jobs.
Job rows include actual runner location, branch, short revision, current step,
and a direct GitHub link. An unassigned ARM64 job is labeled **ARM64 pool**, since
both Studio and MacBook serve that label.

GitHub still uses the existing read-only Actions token in Keychain. No runner
administration permission is added. Workflow history is bounded to the latest
50 runs per selected repository; job detail refreshes at most every 30 seconds
for up to 12 runs (active runs first), with up to 100 jobs per run. Counts are
explicitly sampled, not repository-wide totals. Failed refreshes retain a visibly
stale snapshot instead of implying an empty queue. This is operational visibility,
not a billing report.

`Scripts/collect-ci-status.py` is a separate read-only collector for the fixed
Studio, SimRig and MacBook configuration. It inspects supervisor health, Docker
runner counts/memory, pause markers and MacBook power state using existing,
host-key-verified SSH identities. It never reads GitHub credentials, job files,
container environment or logs, and cannot register, stop or restart jobs.
`python3 Scripts/install-ci-monitor.py` installs it as the current user's
`com.glowscript.octowatch-ci-status` LaunchAgent, every 30 seconds at login.
The app reads only `~/Library/Application Support/Octowatch/ci-status.json`.
Snapshots older than two minutes are marked stale. A missing SSH response means
**Unreachable**; it does not assert that the machine is powered off.

Validation: `swift test`, `python3 Scripts/test_ci_monitor.py`, and
`bash Scripts/bundle.sh`. Keep a backup of the previous application bundle before
installing a local build. The collector is independent of the CI supervisors;
stopping its LaunchAgent stops monitoring only.
