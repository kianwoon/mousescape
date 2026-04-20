<div align="center">

# Mousecape-swiftUI

<p>
  <!-- GitHub Downloads -->
  <a href="https://github.com/kianwoon/Mousecape-swiftUI/releases">
    <img src="https://img.shields.io/github/downloads/kianwoon/Mousecape-swiftUI/total" alt="GitHub all releases">
  </a>
  <!-- GitHub Release Version -->
  <a href="https://github.com/kianwoon/Mousecape-swiftUI/releases">
    <img src="https://img.shields.io/github/v/release/kianwoon/Mousecape-swiftUI" alt="GitHub release (with filter)">
  </a>
  <!-- GitHub Issues -->
  <a href="https://github.com/kianwoon/Mousecape-swiftUI/issues">
    <img src="https://img.shields.io/github/issues/kianwoon/Mousecape-swiftUI" alt="GitHub issues">
  </a>
  <!-- GitHub Stars -->
  <a href="https://github.com/kianwoon/Mousecape-swiftUI/stargazers">
    <img src="https://img.shields.io/github/stars/kianwoon/Mousecape-swiftUI" alt="GitHub Repo stars">
  </a>
</p>

A free macOS cursor manager that allows you to easily replace Mac system pointers.
<br/>
<br/>
**Compatible with macOS 15+ and macOS 26, featuring a fully liquid glass design. Supports one-click Windows cursor conversion.**
<br/>
</div>

## Interface Display

<img width="895" height="789" alt="Screenshot 2026-04-09 at 12 33 18 AM" src="https://github.com/user-attachments/assets/c6647e24-1d01-4b4a-8d17-759d5f24cedd" />


> The cursor theme "Kiriko" shown in the screenshots is created by [ArakiCC](https://space.bilibili.com/14913641), available in the example files.

## Features

- **Custom Cursors**: Replace Mac system pointers with custom static or animated cursors
- **Windows Cursor Support**: One-click import of Windows cursor formats (.cur / .ani), mapping 85% of macOS cursor types automatically
- **Cursor Scale System**: Choose between Global scale (one size for all) or Custom mode (individual scale per cursor type, up to **96x**)
- **Scale Input**: Use sliders or type exact values for precise control
- **Left-Hand Mode**: Mirror all cursors horizontally for left-handed users
- **Visual Effects**: Add inner shadow and outer glow effects for better visibility
- **High Resolution**: Supports cursors up to 96x scale with high-quality upscaling
- **Hotspot Precision**: Fine-tune cursor hotspots with 2 decimal place accuracy
- **Menu Bar Helper**: Quick access to cursor controls when launched at login
- **Safe & Reliable**: Uses private CoreGraphics API, non-intrusive and stable

## Download & Installation

Download the latest version from the [Releases](https://github.com/kianwoon/Mousecape-swiftUI/releases) section.

If you encounter any problems, we recommend that you first check the [Troubleshooting](#troubleshooting) section.

### System Requirements

- **macOS Sequoia (15)** or later
- **macOS 26 (Tahoe)** fully supported with liquid glass design
- Universal Binary: Intel and Apple Silicon Macs

## Example Cursors

This repository includes an example Kiriko.cape file, available for [download here](Example/Kiriko.cape).

**License:** CC BY-NC-ND 4.0 (Attribution-NonCommercial-NoDerivs 4.0)

This cursor set was created by [ArakiCC](https://space.bilibili.com/14913641).

## Getting Started

<details>
<summary>Set Up Launch at Login</summary>

1. Download and open the Mousecape app
2. Go to **Settings > General** and enable **Launch at Login**

When enabled, Mousecape starts in the background at login and provides a menu bar icon that you can use to:
- Open the Mousecape app
- Apply or reset cursor themes
- View the currently applied theme
- Quit the helper

The menu bar helper also automatically re-applies your cursor when:
- Your display configuration changes (connecting/disconnecting monitors)
- Your Mac wakes from sleep
- You switch user sessions

</details>
<br>
<details>
<summary>Import Windows Format Cursors</summary>

Mousecape supports batch importing Windows cursor themes:

1. Extract the downloaded Windows cursor package
2. Click the "+" button and select "Import Windows Cursors"
3. Select the folder containing the cursor files to import

If the folder contains an `*.inf` file, Mousecape will automatically parse it to map cursor files to the correct cursor types using the `[Scheme.Reg]` section. Otherwise, it will use filename-based matching.

**Supported Encodings**: UTF-8, UTF-16 LE/BE, GBK, GB18030, Big5, Shift_JIS, EUC-KR, ISO-8859-1

**Coverage**: 44 out of 52 macOS cursor types are automatically mapped (85%)

</details>
<br>
<details>
<summary>Create Custom Cursor Sets</summary>

1. Click the "+" button to add a new cursor set
2. Click the "+" button to add pointers to customize
3. Drag and drop image or cursor files into the edit window
4. Adjust hotspot position (with 0.01 pixel precision), scale, and other parameters
5. Save and apply your theme

**Simple / Advanced Editing Modes**

Mousecape offers two editing modes, switchable via the toolbar:

- **Simple Mode**: Displays cursors in 15 Windows cursor groups. Editing one cursor automatically applies changes to all related macOS cursor types in the same group (Auto-Alias).
- **Advanced Mode**: Edit each of the 52 macOS cursor types individually for full control.

**Preview Display Modes**

The home screen preview also supports Simple/Advanced display modes:
- **Simple**: Shows one representative cursor per Windows group (15 cursors max)
- **Advanced**: Shows all cursors in the cape (52 types)

Configure this in **Settings > Appearance > Preview Panel**.

**Image Import**

- **Static Images**: PNG, JPEG, TIFF, HEIC — automatically scaled to 64×64 pixels
- **Animated GIFs**: Auto-downsampled to 24 frames if needed
- **Windows Cursors**: .cur (static) and .ani (animated) with full parsing support
- **Maximum Import Size**: 512×512 pixels

</details>
<br>
<details>
<summary>Customize Cursor Scale</summary>

Mousecape gives you two ways to control cursor size, with **slider or text input** for precise control:

**Global Scale Mode**
- Set one size for all cursors at once (0.5x to 96x)
- Use the slider for quick adjustment, or type an exact value
- All cursors scale together

**Custom Scale Mode**
- Set a different size for each cursor type individually (0.5x to 96x per cursor)
- Perfect for making the text cursor (IBeam) smaller than the arrow cursor
- Configure via **Settings > General > Cursor Scale**

Go to **Settings > General** to choose your mode and adjust sizes.

**In the Editor**: Each cursor also has its own scale control for fine-tuning individual cursors.

</details>
<br>
<details>
<summary>Visual Effects</summary>

Mousecape supports two visual effects for improved cursor visibility:

- **Inner Shadow**: Adds an inset shadow around cursor edges
- **Outer Glow**: Adds a soft glow around the cursor

Both effects can be toggled in **Settings > Appearance > Effects**. They apply to all registered cursors system-wide.

**Note**: These effects work best with high-contrast cursors and may not be visible on all cursor designs.

</details>
<br>
<details>
<summary>Import/Export .cape Format Cursors</summary>

Mousecape uses its own **.cape** format for storing complete cursor themes:

**Import**
- Click the "Import" button, then select the **.cape** format cursor file
- Drag and drop **.cape** files directly onto the app window
- Double-click a **.cape** file in Finder to open it directly in Mousecape

**Export**
- Click the "Export" button to save your cursor theme as a .cape file
- Share your themes with others by exporting the .cape file

**Format Details**
- Cape files contain all cursor data in a single file
- Uses HEIF image format for 60% smaller file sizes (v1.1.0+)
- Cape files saved with v1.1.0+ may not be compatible with older versions
- Existing cape files are automatically upgraded when saved

</details>
<br>
<details>
<summary>Reset System Cursor</summary>

If you want to revert to the default macOS cursor:

- Click **Settings > Reset System Cursor**
- Or use the keyboard shortcut **Cmd+R**
- Or use the menu bar helper's "Reset Cursor" option

This restores the original macOS system cursors immediately.

</details>
<br>
<details>
<summary>Export System Cursors</summary>

You can back up your original Mac cursors:

- Go to **Settings > Advanced > Reset** and click "Dump System Cursors"
- Or use the **File > Export System Cursors** menu item

This saves the current system cursors as a .cape file that can be re-imported later.

</details>
<br>
<details>
<summary>Supported Image Formats</summary>

**Standard Image Formats**
- PNG, JPEG, TIFF, HEIC
- GIF (static and animated, auto-downsampled to 24 frames)

**Windows Cursor Formats**
- .cur — static cursors
- .ani — animated cursors (with full support for multi-frame spritesheets and jiffies timing)

**Maximum Import Size**: 512×512 pixels
**Standard Cursor Size**: 64×64 pixels (all images auto-scaled)

</details>

## Troubleshooting

If you encounter issues, please check the common solutions below first. For more help, please [submit an Issue](https://github.com/kianwoon/Mousecape-swiftUI/issues).

### Cursor Limitations

Due to macOS system limitations, Mousecape has the following restrictions:

**Image Size Limit**

- Maximum import size: **512×512 pixels** (larger images will be rejected)
- All cursor images are automatically scaled to **64×64 pixels** at 1x resolution
- Images larger than 64×64 are scaled down (up to 512×512)
- Images smaller than 64×64 are scaled up (may reduce quality)
- Scaling uses "aspect fit" to preserve the image proportions

**Animation Frame Limit**

- Maximum **24 frames** per animated cursor
- Animated cursors with more than 24 frames are automatically downsampled
- Downsampling preserves animation timing by adjusting frame duration
- Example: A 32-frame GIF becomes 24 frames with longer frame duration

**Hotspot Coordinate Range**

- Valid range: 0.00 to 31.99 (2 decimal precision)
- Hotspot must be within cursor boundaries to prevent errors
- Values are automatically clamped if out of range

### Cursor Animation Only Works in Dock Area

**Symptoms:** Custom cursor animations only appear when hovering over the Dock, but revert to the default system cursor elsewhere.

**Cause:** macOS system settings for custom pointer colors can prevent Mousecape from successfully applying cursors globally.

**Solution:** Reset the system pointer color to the default setting:

1. Open **System Settings > Accessibility > Display**
2. Find the **Pointer** section
3. Click the **Reset Color** button
4. Re-apply your cursor theme in Mousecape

The pointer must use the default color scheme (white outline, black fill) for Mousecape to work properly.

</details>
<br>
<details>
<summary>Animated Cursor Import Failed</summary>

**Symptoms:** Animated cursor files (.ani or .gif) fail to import or are rejected.

**Cause:** Animated cursors with more than 24 frames exceed macOS system limits and require automatic downsampling.

**Solution:**
- Mousecape automatically downsamples animations with more than 24 frames
- The animation speed is preserved by adjusting frame duration
- If import still fails, ensure the file is not corrupted and try re-downloading
- Check that the image dimensions do not exceed 512×512 pixels

</details>
<br>
<details>
<summary>Cursor Theme Display Issues (Non-English)</summary>

**Symptoms:** Non-English cursor themes show garbled filenames or incorrect names.

**Cause:** INF file encoding not detected correctly.

**Solution:**
- Mousecape supports multiple encodings: UTF-8, UTF-16 LE/BE, GBK, GB18030, Big5, Shift_JIS, EUC-KR, ISO-8859-1
- Ensure the INF file is saved in a supported encoding
- If issues persist, try resaving the INF file as UTF-8

</details>
<br>
<details>
<summary>Cursor Image Too Large</summary>

**Symptoms:** Large cursor images are rejected during import.

**Cause:** Image exceeds the maximum supported size of 512×512 pixels.

**Solution:**
- Resize images to 512×512 pixels or smaller before importing
- All imported images are automatically scaled to 64×64 pixels
- Images larger than 512×512 will be rejected with an error message

</details>
<br>
<details>
<summary>Cursor Scale Doesn't Apply</summary>

**Symptoms:** Changing the scale slider doesn't change the cursor size immediately.

**Cause:** As of v1.2.0, settings changes no longer auto-apply cursors to give you control.

**Solution:**
- After adjusting scale, double-click your cape or use the "Apply" button
- The menu bar helper will still auto-reapply on display changes and wake-from-sleep
- This design prevents unwanted re-applications when you're just adjusting settings

</details>

## Support

If you find Mousecape useful, consider buying me a coffee!

<a href="https://ko-fi.com/kianwoon">
  <img src="Screenshot/qrcode.png" width="160" alt="Buy me a coffee on Ko-fi">
</a>

[ko-fi.com/kianwoon](https://ko-fi.com/kianwoon)

## Acknowledgments

- **Original Project**: Created by [Alex Zielenski](https://github.com/alexzielenski)
- **SwiftUI Redesign**: [sdmj76](https://github.com/sdmj76)
- **Coding Assistance**: [Claude Code](https://claude.ai/code)

## Feedback & Issues

If you have questions or suggestions, please submit them on [GitHub Issues](https://github.com/kianwoon/Mousecape-swiftUI/issues).

**PS: This project does not provide support for `any non-compliant third-party cursors`. If you encounter any of these issues, please contact the cursor author for assistance.**
