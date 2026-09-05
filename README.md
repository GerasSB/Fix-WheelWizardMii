# Fix WheelWizard
Fixes the issue where Miis created with Wheel Wizard appear as deleted in-game when using [Wiicompiled](https://github.com/patchzyy/Wiicompiled) without copying Dolphin save data.

## The issue
Wheel Wizard does not create the necessary RFL_DB.dat file needed for the game to detect Miis in the Wii's "memory". This tool scans for Miis in existing Dolphin databases and .mii files in the `CT-MKWII` folder

## Instructions
**Currently only for Windows.**
1. In Wheel Wizard: `Right click > Export` your Mii(s) into your `CT-MKWII` folder (default found in your `%appdata%` folder).
2. Run the script through Windows Powershell:
    ```ps1
    irm "https://raw.githubusercontent.com/GerasSB/Fix-WheelWizardMii/refs/heads/main/Fix-WheelWizardMii.ps1" | iex
    ```
3. (optional): if your Wheel Wizard data folder is not the default, write the path to it when the script prompts you to do it.
4. You can now run Wiicompiled and your Miis will appear.

> [!WARNING]
> Anytime you edit a Mii, the script needs to be run again to create a new database.

## Credits
* [ACoolerName](https://github.com/ACoolerName): for finding the issue and creating a Python solution.
* `goodgub` on Discord: for most of the Powershell code.