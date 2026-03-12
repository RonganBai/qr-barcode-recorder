# qr-barcode-recorder

Flutter Android app for QR/barcode logging with structure-based table grouping, note tagging, reminders, and Excel export.

Chinese README: [README.zh-CN.md](README.zh-CN.md)

## Features

- Scan QR and common linear barcodes
- Auto-group records by per-character structure signature (`A`/`N`/`S`)
- Per-table counting with independent reminder step
- Add/edit notes (rows with notes are highlighted)
- Hold-to-scan, pause/resume, torch toggle, and search
- Export selected tables to Excel with custom filenames

## Run

```bash
flutter pub get
flutter run
```

## Export

- Choose one or more tables to export
- Data is centered in Excel cells
- Rows with notes use a yellow background
