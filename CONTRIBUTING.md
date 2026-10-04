# Contributing

Please run `zsh scripts/test.sh` and `zsh scripts/build_app.sh` before submitting a change.
Keep the standalone project self-contained and the source adapters read-only.

## Privacy checklist

- Use synthetic fixtures only. Never attach a raw personal transcript to an issue or pull request.
- Capture public screenshots with `--demo`.
- Do not commit credentials, local config, real source directories, usage/account output, generated indexes, or exports.
- Review `git diff --cached` and the file list before pushing.
- Run `ruby scripts/privacy_check.rb --self-test`, then `--history` and `--staged`. The last command reads staged blobs, not just the working tree. It reports filenames/rules without printing matched data; it is not a complete audit.
- `ruby scripts/test_privacy_check.rb` tests staged/working/history isolation, ignored versus force-added private files and symlink safety using temporary synthetic repositories.
- Never commit Developer ID private keys, certificates, notarization API keys, signing credentials or Apple account information. Store credentials in Keychain, not a tracked environment file.
- Live model tests are opt-in and must never run in CI.

## Parser changes

Add tests for the observed record shape, mixed content blocks, incomplete final lines, date boundaries, duplicates, and unrelated record types. State the CLI version used to verify the change. Unknown fields should be tolerated; unknown versions must not destroy saved journal data.

Source adapters must not execute commands found in transcripts. Keep prompts bounded and clearly distinguish transcript data from instructions. Preserve edited and confirmed text, and keep source-model information separate from the model used to write a summary.

## Release changes

Follow [RELEASING.md](docs/RELEASING.md) and [the acceptance checklist](docs/RELEASE_CHECKLIST.md). Keep unsigned test builds visibly labeled; do not imply notarization or clean-Mac testing when it has not happened. Default tests/builds must never upload to Apple or call model providers. Use `--demo` for UI verification.
