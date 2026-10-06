# MVM - Mini Version Manager

![Admin Required: No](https://img.shields.io/badge/Admin%20Required-No-brightgreen)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows-blue)

A lightweight, zero-dependency Node.js version manager for Windows. MVM allows you to install and switch between Node versions instantly using PowerShell and directory junctions.

## 🛡️ No Admin Privileges Required
Unlike other version managers that require elevated permissions to modify system-level folders, **MVM works entirely within your User profile.**
* **Safe & Fast:** Uses directory junctions (`mklink /J`) which typically do not require Administrator rights.
* **Non-Intrusive:** Updates the **User PATH** rather than the System PATH, keeping your machine's core settings untouched.
* **Portable:** MVM detects its own location automatically — install it anywhere (`C:\Tools\mvm`, `D:\dev\mvm`, etc.), no fixed path required.

---

## 📁 Folder Structure
When you unzip `mvm.zip`, your structure should look like this:
```text
mvm/
├── bin/
│   └── mvm.cmd        # The command-line wrapper
├── node/              # Where Node versions are stored (created automatically)
└── mvm.ps1            # The core logic script
```

---

## 🚀 Installation

1. **Download & Extract**:
   Download `mvm.zip` and extract the `mvm` folder to **any permanent location** you like (e.g., `C:\Tools\mvm`, `C:\mvm`, or even inside your user profile). You will not need to edit any files — MVM figures out its own location at runtime.

2. **Run Setup**:
   Open a terminal **inside the `bin` folder** (e.g., `cd C:\Tools\mvm\bin`) and run:
   ```cmd
   mvm.cmd setup
   ```
   > ⚠️ If you're using **PowerShell**, the current folder isn't searched automatically, so you must run it as `.\mvm.cmd setup`. In classic `cmd.exe`, `mvm.cmd setup` works directly.

   This registers MVM's `bin` folder and the active Node folder in your **User PATH**.

3. **Verify**:
   Close your terminal and open a **new** one. Type:
   ```powershell
   mvm help
   ```
   to confirm it's recognized from any directory.

---

## 🛠 Usage

### 1. Add a Node Version
Install a specific version:
```powershell
mvm add 20.10.0
```
Or let MVM resolve the latest release automatically:
```powershell
mvm add 20        # Latest v20.x.x
mvm add 20.10     # Latest v20.10.x patch
```
If a matching version is already installed and a newer one is available, MVM will ask before downloading again.

### 2. List Installed Versions
```powershell
mvm list
```

### 3. Switch Versions
```powershell
mvm use 20          # Latest installed v20.x.x
mvm use 18.17.1     # Specific version
mvm use             # Reads version from a .nvmrc file in the current or parent folder
```

### 4. Remove a Version
```powershell
mvm remove 16.20.2
```

---

## 💡 Notes
* **Moving the Folder**: If you move the `mvm` folder to a new location after installation, open the new `bin` folder and run `mvm.cmd setup` again to repair the PATH entries.
* **First Time Use**: After running `mvm use` for the first time, restart your terminal so the `node` command is picked up by any already-open shells.
* **.nvmrc support**: `mvm use` with no arguments will search the current directory and its parents for a `.nvmrc` file and switch to the matching installed version automatically.

---

## ⚖ License
MIT License - Feel free to use and modify!
