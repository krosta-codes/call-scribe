# CallScribe build report

- 2026-11-16 icon: app-icons/glyphs/callscribe.swift, preview icon-preview.png (looked at, ok)
- 2026-11-16 pipeline test (say tracks, test vault /private/tmp/callscribe-test/vault): speakers alternate correctly, all summary sections present
- 2026-11-16 app builds, runs, detects calls (log lines in ~/Library/Logs/CallScribe.log)
- 2026-11-16 process tap + mic recording verified via `--record-test` (tap RMS about -51 dB for quiet `say` output, speech transcribes; mic captured room noise only)
