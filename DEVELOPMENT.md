# Development checklist

For every change, read this file before editing and check it again before calling the work complete. This applies to people and AI assistants, including changes to code, prompts, settings, and documentation.

Check each item below. If an item does not apply, leave it unchanged and say why when relevant.

- [ ] **Check the impact.** Read [AGENTS.md](AGENTS.md) and identify which parts are affected: MacHelper, extensions, shared APIs, installers, or the marketplace. Keep the same behavior consistent wherever it appears. Remove proven unused code; preserve published interfaces and necessary compatibility paths.
- [ ] **Update the explanation.** Update related UI labels/help, [README](README.md), [project design](PROJECT_DESIGN.md), [AI extension guide](AI_EXTENSION_GUIDE.md), detailed `docs/`, SDK examples, and [website](ExtensionMarket-website/README.md) descriptions, instructions, or previews. Removed controls must not remain in current instructions. Change only material affected by the task.
- [ ] **Keep languages consistent.** For interface text changes, update every supported language catalog and preserve format parameters. Extension labels belong in extension source. Never translate or rewrite user prompts, settings values, model IDs, or selected text just because the interface language changes.
- [ ] **Check release details.** When preparing a release, keep app/tool versions and website download metadata consistent. Check current-version statements too; minimum supported versions and historical examples have different purposes.
- [ ] **Keep downloads consistent.** When packaging changed extension files for release, use a new version and regenerate its full catalog inventory, sizes, and hashes. Preserve previously published files and ZIPs. If bundled/downloadable documentation or SDK files change, rebuild the affected app/site packages using the documented commands; never edit generated output directly.
- [ ] **Verify the change.** Run the relevant existing checks from the [README](README.md) or website guide. Check local documentation links. Verify changed UI in the installed app when installation is part of the task. A documentation-only change does not require unrelated tests.
- [ ] **Protect private files.** Keep `AI_DEPLOYMENT.md`, credentials, and user data out of Git, logs, and downloads. Follow the existing project rules in `AGENTS.md`.
- [ ] **Report the actual result.** State what changed and what was checked. Distinguish source changes, local builds, installed apps, GitHub pushes, and live website deployments. Building or pushing does not deploy the website; install or publish only within the user's authorized scope.

Do not mark a change complete while a related update or required check is still missing. Fix it, or clearly report the remaining blocker.
