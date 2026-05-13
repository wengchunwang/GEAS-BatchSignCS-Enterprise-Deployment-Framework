# GEAS BatchSignCS Enterprise Deployment Framework

Enterprise-ready GPO deployment framework for BatchSignCS with Install / Uninstall / Upgrade / DryRun support.

---

## 🔧 Features

- ✅ Install / Uninstall automation
- ✅ WhiteList enforcement (auto remove if not allowed)
- ✅ Version control & auto upgrade
- ✅ VC++ dependency deployment (x86/x64)
- ✅ Hash-based file caching
- ✅ Centralized NAS logging
- ✅ Mutex protection (prevent duplicate execution)
- ✅ Retry & random delay (anti-storm)
- ✅ DryRun simulation mode (no system changes)

---

## 🏗 Architecture

```
GPO Startup (SYSTEM)
        ↓
PowerShell Script
        ↓
 ├─ WhiteList Control
 ├─ Version Check
 ├─ Install / Uninstall
 ├─ Registry State
 └─ Logging (Local + NAS)
```

---

## 🔄 Workflow

### Mode Selection

| Condition | Mode |
|----------|------|
| In WhiteList | Install |
| Not in WhiteList | Uninstall |

---

### Version Control

```
Same Version → Skip
Different Version → Uninstall → Install
```

---

## 📁 File Strategy

**Local Cache:**
```
D:\Temp
```

**Verification:**
- SHA256 hash validation
- Prevent duplicate downloads

---

## 🧠 State Management (Registry)

```
HKLM\SOFTWARE\RPB\GEAS
```

| Key | Purpose |
|----|--------|
| BatchSignCS | Install flag |
| Version | Installed version |
| InstallDate | Timestamp |

---

## 🧪 DryRun Mode

```
-Mode DryRun
```

### Behavior
- Simulates all actions
- No system changes
- Writes full logs

Example log:
```
[DryRun] Copy file
[DryRun] Execute msiexec
[DryRun] Set registry
```

---

## 🧾 Logging

**Local:**
```
D:\Temp\GEAS_yyyyMMdd.log
```

**NAS:**
```
\NAS\LogFiles\GEAS
```

Retention: 30 days

---

## 🚀 Usage

### Install (default)
```
-Mode Install
```

### Uninstall
```
-Mode Uninstall
```

### DryRun (safe testing)
```
-Mode DryRun
```

---

## ✅ Summary

This framework implements **Endpoint Desired State Enforcement**, ensuring:

- Only approved machines have BatchSignCS
- Version consistency is maintained
- Install/Uninstall fully automated
- Safe testing via DryRun

---

## 📌 Version

```
2026.05.13 Enterprise Stable v1.0
```

---

## ⭐ Future Improvements

- AD Group-based control
- Dashboard (log analytics)
- CI/CD package distribution
- Rollback support

---

🚀 Enterprise GPO Deployment + State Enforcement + Simulation Ready
