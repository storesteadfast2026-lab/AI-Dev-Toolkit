This is the exact PowerShell Core Runner v0.3 source that was manually proven on the target Windows PC on 2026-10-09.

Observed on that PC:
- BAT stdout visible in the GUI: PASS
- STDERR visible in the same log/screen: PASS
- final PAUSE consumed by pre-fed Enter: PASS
- Apply-style script completed: PASS
- exit code 0: PASS

Application Operations Manager PS v1.0 uses the same .NET ProcessStartInfo + CMD wrapper + direct log redirection design inside the full application.
