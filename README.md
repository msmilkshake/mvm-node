# MVM - Mini Version Manager

![Admin Required: No](https://img.shields.io/badge/Admin%20Required-No-brightgreen)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows-blue)

A lightweight, zero-dependency Node.js version manager for Windows. MVM allows you to install and switch between Node versions instantly using PowerShell and directory junctions.

## 🛡️ No Admin Privileges Required
Unlike other version managers that require elevated permissions to modify system-level folders, **MVM works entirely within your User profile.**
* **Safe & Fast:** Uses directory junctions (`mklink /J`) which typically do not require Administrator rights.
* **Non-Intrusive:** Updates the **User PATH** rather than the System PATH, keeping your machine's core settings untouched.
* **Portable:** MVM detects its own location automatically — install it anywhere (`C:\Tools\mvm`, `D:\dev\mvm`, etc.), no fixed path required.
* **Secure Downloads:** Every Node.js download is verified against official SHA256 checksums before installation.
* **ARM64 Ready:** Automatically detects your CPU architecture and installs the correct build (x64 or ARM64).

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
mvm add 20          # Latest v20.x.x
mvm add 20.10       # Latest v20.10.x patch
mvm add lts/*       # Latest Active LTS release
mvm add lts/iron    # Latest release of a specific LTS line (e.g. "iron" = Node 20)
mvm add node        # Latest Current release
```
If a matching version is already installed and a newer one is available, MVM will ask before downloading again. Every download is verified against Node's official SHA256 checksums before being installed.

### 2. List Installed Versions
```powershell
mvm list
```
```text
v16.20.2
v18.20.5 <- Active
v20.10.0
```

Add `-v` or `--verbose` to also see each version's bundled npm version and Corepack status (slower, as it queries Corepack directly):
```powershell
mvm list -v
```
```text
v16.20.2  [npm v8.19.4, corepack: v0.17.0 (available)]
v18.20.5  [npm v10.8.2, corepack: v0.24.1 (enabled)] <- Active
v20.10.0  [npm v10.2.3, corepack: v0.24.1 (available)]
```

### 3. Switch Versions
```powershell
mvm use 20          # Latest installed v20.x.x
mvm use 18.17.1     # Specific version
mvm use lts/*       # Latest installed Active LTS
mvm use             # Reads version from .mvmrc or .nvmrc in the current or parent folder
```
If the requested version isn't installed yet, MVM will offer to download and install it automatically before switching.

### 4. Remove a Version
```powershell
mvm remove 16.20.2
```

### 5. Check the Active Version
```powershell
mvm current
```
```text
v18.20.5
  npm v10.8.2
  corepack v0.24.1 (enabled)
```

### 6. Locate node.exe
```powershell
mvm which          # Active version
mvm which 20       # A specific version
```

### 7. Browse Available Remote Releases
```powershell
mvm ls-remote 20        # All v20.x.x releases available for download
mvm ls-remote 20.10     # All v20.10.x patch releases
```

### 8. Check MVM's Own Version
```powershell
mvm -v
mvm --version
```

### 9. Self-Update MVM
```powershell
mvm update
```
Checks the latest release on GitHub and updates `mvm.ps1`/`bin/mvm.cmd` in place if a newer version is available. MVM also checks for updates automatically (cached for 24h) and will print a warning banner on any command if a newer version exists.

---

## 📄 Project Version Files (`.mvmrc` / `.nvmrc`)

Running `mvm use` with no arguments looks for a version in the current directory or any parent directory, checking `.mvmrc` first and falling back to `.nvmrc`.

**`.nvmrc`** — simple, shared with `nvm` users on your team:
```text
20.10.0
```

**`.mvmrc`** — supports a bare version (like `.nvmrc`), or explicit `version=` / `proxy=` keys:
```text
version=20.10.0
proxy=http://proxy.company.com:8080
```

This lets `.mvmrc` and `.nvmrc` coexist on mixed nvm/mvm teams — for example, a shared, committed `.nvmrc` for the team's Node version, plus a personal, uncommitted `.mvmrc` containing only a `proxy=` line for corporate network configuration. If `.mvmrc` specifies no version, `mvm use` automatically falls back to `.nvmrc`.

---

## 💡 Notes
* **Moving the Folder**: If you move the `mvm` folder to a new location after installation, open the new `bin` folder and run `mvm.cmd setup` again to repair the PATH entries.
* **First Time Use**: After running `mvm use` for the first time, restart your terminal so the `node` command is picked up by any already-open shells.
* **Global npm packages don't carry over**: Packages installed with `npm install -g` live inside each Node version's own folder. Switching versions with `mvm use` means those global packages won't be available until reinstalled for the new version. The same applies to Corepack's enabled state — run `corepack enable` again after switching if needed.
* **Aliases**: `lts/*`, `lts/<codename>`, `node`, and `stable` are resolved live against nodejs.org and are supported by both `add` and `use`.

---

## ⚖ License
MIT License - Feel free to use and modify!
