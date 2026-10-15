# Minimal Update Package Convention

Preferred package contents:

- `PACKAGE_INFO.json`
- `RELEASE_VERSION.txt`
- operator-facing `.bat`, `.cmd` or `.ps1` scripts

Example metadata:

```json
{
  "schema_version": 1,
  "application_id": "PON",
  "application_name": "PON Bikes Automation",
  "release": "1012.0900",
  "type": "Repair",
  "operations": {
    "apply": "02_Apply_Update.bat",
    "rollback": "03_Rollback_Update.bat",
    "verify": "04_Verify_Update.bat",
    "continuity_snapshot": "05_Create_Continuity_Snapshot.bat"
  }
}
```

Exit codes:

- `0` = PASS
- non-zero = FAIL

Preferred output prefixes:

- `[INFO]`
- `[PASS]`
- `[WARN]`
- `[FAIL]`
