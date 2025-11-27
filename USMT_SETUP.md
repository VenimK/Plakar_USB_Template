# USMT Setup Guide

## Quick Start

This tool automatically detects your system architecture (32-bit or 64-bit) and uses the appropriate USMT binaries.

## Getting USMT Files

### Step 1: Download Windows ADK
Download the latest Windows Assessment and Deployment Kit (ADK):
- **Direct link**: https://go.microsoft.com/fwlink/?linkid=2243390
- **Alternative**: Search for "Windows ADK" on Microsoft's website

### Step 2: Install USMT Component Only
1. Run the ADK installer
2. **UNCHECK** all components except:
   - ✅ **User State Migration Tool (USMT)**
3. Complete the installation

### Step 3: Copy USMT Files to USB

After installation, copy the USMT files to your USB drive:

**For 64-bit systems (most common):**
```
From: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\USMT\amd64\
To:   [USB_DRIVE]\USMT\amd64\
```

**For 32-bit systems (legacy):**
```
From: C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\USMT\x86\
To:   [USB_DRIVE]\USMT\x86\
```

**Pro tip:** Copy both architectures to support all systems:
```
[USB_DRIVE]\
├── menu.ps1
├── plakar.exe
└── USMT\
    ├── amd64\
    │   ├── scanstate.exe
    │   ├── loadstate.exe
    │   ├── miguser.xml
    │   ├── migapp.xml
    │   └── migdocs.xml
    └── x86\
        ├── scanstate.exe
        ├── loadstate.exe
        ├── miguser.xml
        ├── migapp.xml
        └── migdocs.xml
```

## Supported Architectures

- ✅ **AMD64/x86_64** (64-bit Intel/AMD) - Most modern systems
- ✅ **x86** (32-bit) - Legacy systems
- ❌ **ARM64** - Not officially supported by USMT yet

## Troubleshooting

### "USMT files not found" error
1. Ensure you copied files to the correct architecture folder (`amd64` or `x86`)
2. Check that `scanstate.exe` and `loadstate.exe` are present
3. Verify XML files (`miguser.xml`, `migapp.xml`, `migdocs.xml`) are included

### Architecture detection
The script automatically detects your system:
- 64-bit Windows → uses `USMT\amd64\`
- 32-bit Windows → uses `USMT\x86\`

### Multiple locations supported
The script searches in this order:
1. `[ScriptDir]\USMT\[arch]\`
2. `[ScriptDir]\USMT\X64\` (legacy compatibility)
3. `[DriveLetter]:\USMT\[arch]\`

## File Size Reference

Each architecture folder is approximately:
- **amd64**: ~25-30 MB
- **x86**: ~20-25 MB
- **Both**: ~50-55 MB total

## Legal Note

USMT is part of the Windows Assessment and Deployment Kit (ADK) and is provided by Microsoft. Ensure you comply with Microsoft's licensing terms when using USMT.
