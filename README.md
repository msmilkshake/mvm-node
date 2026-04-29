# MVM - Mini Version Manager

![Admin Required: No](https://img.shields.io/badge/Admin%20Required-No-brightgreen)
![Platform: Windows](https://img.shields.io/badge/Platform-Windows-blue)

A lightweight, zero-dependency Node.js version manager for Windows. MVM allows you to install and switch between Node versions instantly using PowerShell and directory junctions.

## 🛡️ No Admin Privileges Required
Unlike other version managers that require elevated permissions to modify system-level folders, **MVM works entirely within your User profile.** * **Safe & Fast:** Uses directory junctions (mklink /J) which typically do not require Administrator rights.
* **Non-Intrusive:** Updates the **User PATH** rather than the System PATH, keeping your machine's core settings untouched.

---

## 📁 Folder Structure
When you unzip `mvm.zip`, your structure should look like this:
```text
mvm/
├── bin/
│   └── mvm.cmd        # The command-line wrapper
├── node/              # Where Node versions are stored
└── mvm.ps1            # The core logic script
```

---

## 🚀 Installation

1. **Download & Extract**: 
   Download `mvm.zip` and extract the `mvm` folder to a permanent location (e.g., `C:\Tools\mvm` or `C:\mvm`).

2. **Run Setup**:
   Open a terminal **inside the `bin` folder** and run the following command to configure your User PATH:
   ```powershell
   .\mvm.ps1 setup
   ```
   *This adds the MVM commands and the active Node path to your environment variables.*

3. **Verify**:
   Close your terminal and open a new one. Type `mvm` to ensure it is recognized.

---

## 🛠 Usage

### 1. Add a Node Version
Download and install a specific version of Node.js:
```powershell
mvm add 20.10.0
```

### 2. List Installed Versions
See what you have installed and which one is currently active:
```powershell
mvm list
```

### 3. Switch Versions
Switch to an installed version. You can provide the full version or just the major version:
```powershell
mvm use 20      # Automatically picks the latest installed v20.x.x
mvm use 18.17.1  # Switches to a specific version
```

### 4. Remove a Version
Uninstall a version you no longer need:
```powershell
mvm remove 16.20.2
```

---

## 💡 Notes
* **Moving the Folder**: If you move the `mvm` folder to a new location, simply open the new `bin` folder and run `mvm setup` again to repair the paths.
* **First Time Use**: After running `mvm use` for the first time, you may need to restart your terminal for the `node` command to be recognized globally.

---

## ⚖ License
MIT License - Feel free to use and modify!
