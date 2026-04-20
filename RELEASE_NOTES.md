### v1.3.1 - Improvement

**This update improves the cursor scale and hotspot editing experience.**

**Improvements:**

- Added text input field next to scale sliders — you can now type an exact scale value or use the slider
- Hotspot coordinates now support 2 decimal places for more precise positioning

---

### v1.3.0 - Bug Fix

**This update fixes the cursor reset feature — "Reset System Cursor" now correctly restores macOS default cursors.**

**Bug Fixes:**

- Fixed "Reset System Cursor" not restoring macOS default cursors after applying a custom cursor theme
- Fixed cursor backups not being created before applying a cape, causing reset to fail
- Cleaned up redundant code in the Helper's session monitor

---

### v1.2.9 - Bug Fix

**This update fixes a bug where the cursor scale could auto-jump to 64x when MousecapeHelper is running.**

**Bug Fixes:**

- Fixed cursor scale auto-jumping to 64x when MousecapeHelper runs in background
- Helper now reads scale from preferences instead of WindowServer to prevent corrupted values

---

### v1.2.8 - Improvement

**This update improves the cursor editing experience and adds onboarding for new users.**

**Improvements:**

- Cursor preview in edit mode is now larger, making thin lines and small details easier to see
- New users are automatically guided to create their first cursor theme
- Per-cursor scale settings now auto-switch to custom mode when adjusted

---

### v1.2.7 - Bug Fix

**This update fixes a bug where the cursor scale could suddenly jump to 64x after a few minutes.**

**Bug Fixes:**

- Fixed cursor scale suddenly jumping to 64x after startup when no custom cursor theme is applied

---

### v1.2.6 - Bug Fix

**This update is a maintenance release with minor improvements.**

---

### v1.2.5 - Bug Fix

**This update fixes a startup cursor scale spike and adds detection for system pointer color conflicts.**

**Bug Fixes:**

- Fixed Arrow cursor suddenly scaling up on startup — the Helper now uses the same gentle apply method as the main app
- Fixed Mousecape silently failing when system pointer colors are customized in Accessibility settings — now shows a clear warning with a button to fix it

**Improvements:**

- Added a warning banner in Settings when pointer colors conflict, with a "Fix" button that opens System Settings directly
- The warning automatically updates when you return from System Settings after resetting pointer colors

---

### v1.2.4 - Bug Fix

**This update fixes system cursor pixelation when applying a cape from the main app.**

**Bug Fixes:**

- Fixed system default cursors (resize, move, link, etc.) appearing pixelated at high scale when applied from the main app
- Fixed inner shadow effect doubling on cape cursors each time settings were changed
- Fixed cursor scale adjustments in Settings triggering an unwanted re-apply of the cape

---

**This update fixes cursor pixelation when changing the cursor scale without a cape applied.**

**Bug Fixes:**

- Fixed system default cursors becoming pixelated when increasing the cursor scale without a custom cape applied
- Fixed cursor pixelation persisting after display reconfiguration or waking from sleep when no cape is applied
- Fixed cursor pixelation on app startup when a non-default scale was saved

---

### v1.2.2 - Bug Fix

**This update fixes cursor images reverting to the old version after editing.**

**Bug Fixes:**

- Fixed cursor image reverting to old version after changing hotspot and re-applying
- Fixed stale image data persisting at unused scales after importing a new cursor image

---

### v1.2.1 - Bug Fix

**This update fixes drag-and-drop image import and cursor hotspot issues.**

**Bug Fixes:**

- Fixed drag-and-drop image import not working in edit mode — you can now drag images onto cursor types to set or replace them
- Fixed cursor hotspot position being incorrect at high scale settings (3x and above)

---

### v1.2.0 - UX Improvement

**This update gives you full control over when cursors are applied.**

**What's Changed:**

- Settings changes (scale, handedness, visual effects) no longer auto-apply cursors — you decide when to apply
- Importing a cape no longer auto-applies — it selects the cape so you can preview it first
- To apply a cape: double-click it, use the toolbar Apply button, or right-click and choose Apply
- The menu bar helper still re-applies your cursor automatically on display changes and wake-from-sleep

---

### v1.1.5 - Bug Fix

**This update significantly improves system cursor quality at high scale settings.**

**Bug Fixes:**

- Fixed cursor pixelation at high scale — now always selects the highest resolution image from cape files
- Fixed system cursors (resize, move, link, etc.) appearing blurry at 3x+ scale — now extracted at 64x resolution directly from macOS

**Improvements:**

- Added Lanczos + sharpen upscaling pipeline (Core Image) for sharper cursor rendering
- Custom scale slider range expanded to 64x (from 16x)
- Fixed memory leak in cursor upscaling pipeline

---

### v1.1.4 - Bug Fix

**This update fixes system default cursor scaling and improves rendering quality.**

**Bug Fixes:**

- Fixed system default cursors (resize, move, link, etc.) not scaling in custom per-cursor mode — they were stuck at 1x regardless of the setting
- Fixed system cursor data not being readable for numbered cursor types after reset

**Improvements:**

- Added high-quality image upscaling for system cursors at 3x+ scale to reduce pixelation

---

### v1.1.3 - Improvement

**This update makes custom cursor scale changes apply instantly.**

**Improvements:**

- Custom per-cursor scale now applies immediately when you release the slider — no need to leave the settings screen first
- "Reset to 1.0x", "Reset All", and "Set All" buttons also apply changes instantly

---

### v1.1.2 - Bug Fix

**This update fixes custom per-cursor scale for system default cursors and improves notification UI.**

**Bug Fixes:**

- Fixed custom per-cursor scale not working for system default cursors (resize, move, etc.) — these now correctly use their individual scale settings
- Fixed synonym cursor expansion overwriting custom cursor images (e.g. ArrowCtx replacing ArrowS)
- Fixed system cursors becoming unreadable after reset, causing them to skip per-cursor scaling

**Improvements:**

- Success notifications (apply, import, export) now use non-intrusive toast messages instead of blocking alert dialogs
- Updated acknowledgments in README

---

### v1.1.0 - Architecture Update

**A major update with improved launch-at-login, smaller file sizes, easier editing, and a polished new look.**

**What's New:**

- **New App Icon** — Redesigned with a liquid glass effect that matches macOS 26's design language

- **Menu Bar Quick Access** — Enable "Launch at Login" in settings to get a menu bar icon
  - See your current cursor theme at a glance
  - Quick actions: Apply cursor, Reset cursor, Open Mousecape
  - More reliable startup experience

- **Better Windows Cursor Support** — Import Windows cursor themes with better accuracy
  - Now supports 85% of macOS cursor types (up from 40%)
  - Most cursors will work correctly after importing

- **Simple & Advanced Editing Modes** — Choose how you want to edit
  - **Simple Mode:** Edit in groups (like Windows), changes apply to related cursors automatically
  - **Advanced Mode:** Fine-tune each cursor individually
  - **Preview Mode:** Choose how many cursors to show on the home screen
  - Switch anytime via the toolbar

- **Double-Click to Open** — Double-click any `.cape` file in Finder to open it

- **Smaller File Sizes** — Cursor files are now 60% smaller

- **Export System Cursors** — Back up your original Mac cursors
  - Find it in Settings > Advanced > Reset, or in the File menu

- **Better Import/Export Warnings** — See what's wrong and choose to continue or cancel

- **Left-Hand Mode** — Switch to left-hand cursor layout in Settings > General
  - Mirrors all cursors horizontally for left-handed users
  - Preview and system cursors both flip instantly when toggled

**Improvements:**

- Faster performance and better stability
- More reliable cursor application
- Compatible with future macOS versions

**Bug Fixes:**

- Fixed Windows cursor transparency rendering — thin lines and edges now look crisp and correct
- Fixed cursor application not working when some cursors were missing
- Fixed menu bar helper stability issues
- Fixed various UI glitches
- Updated documentation links to point to the correct project repository

**Note:** Older versions of Mousecape may not open files saved with v1.1.0. We recommend updating to the latest version.

The transparent window toggle feature has been removed to simplify the codebase.

---

### v1.0.4 - Features & Critical Fix

**New Features:**

- Drag-and-drop sorting — reorder your cursor themes by dragging them in the sidebar
- Drag-and-drop import — drop `.cape` files directly onto the app window to import
- Added "Reset System Cursor" button in Settings (also available via Cmd+R)
- Language now follows your system settings automatically, no more manual switching
- Reorganized menu bar for a cleaner layout
- Auto-rename duplicate cape names on import
- Success notifications for import and export operations

**Optimizations:**

- Smoother cursor zoom preview animation
- Windows cursor conversion is now ~2x faster
- Saved cursor scale is now applied on app startup

**Critical Fix:**

- **Fixed animated cursor frames bleeding into each other during import** — if you previously imported Windows animated cursors and noticed visual glitches, this is the fix. **We recommend re-importing affected cursors after updating!**

**Other Bug Fixes:**

- Improved compatibility with more Windows animated cursor (.ani) files
- Fixed GIF animation playing at wrong speed after import
- Fixed animated cursor frames rendering incorrectly
- Fixed applied cursor theme not being detected on app startup
- Fixed various UI navigation and animation glitches
- Internal code quality improvements for better stability and future macOS compatibility

**Removed:**

- Windows cursor import now requires an INF file in the folder (filename-based guessing has been removed for better accuracy)

**PS: This project does not provide support for `any non-compliant third-party cursors`. If you encounter any of these issues, please contact the cursor author for assistance.**

---

### v1.0.3 - Bug Fix

**This update fixes Windows animated cursor import issues and improves encoding support.**

**Bug Fixes:**

- Fixed animated cursor (.ani) files being rejected due to incorrect size validation
- Fixed multi-frame animated cursors (94, 140, 206 frames) not being imported properly
- Fixed GBK encoding detection for Chinese Windows cursor themes

**Improvements:**

- Automatic downsampling now works correctly for all animated cursors with >24 frames
- Multi-encoding support for INF files: UTF-8, UTF-16 LE/BE, GBK, GB18030, Big5, Shift_JIS, EUC-KR, ISO-8859-1
- Cleaner code: removed redundant validation that served no purpose

**PS: This project does not provide support for `any non-compliant third-party cursors`. If you encounter any of these issues, please contact the cursor author for assistance.**

---

### v1.0.2 - Bug Fixes

**This update focuses on fixing bugs and improving stability.**

**Bug Fixes:**

- Fixed GIF animation import that wasn't working before
- Fixed issues where imported Windows cursors wouldn't apply correctly
- Fixed crashes that could happen when importing certain cursor files
- Fixed a problem where the helper tool might stop working after updating the app
- Fixed animation playback speed being incorrect when importing GIF or ANI files
- Added hotspot validation on import to ensure accurate cursor positioning

**Improvements:**

- Improved compatibility with Windows cursor themes
- Added memory protection to prevent crashes when importing large cursor files (max 4096×4096 pixels)
- Faster CI builds
- (Debug build) Optimized log file cleanup with 100MB total size limit

---

### v1.0.1 - Native Windows Cursor Conversion

**Major Update: Windows cursor conversion rewritten from Python to native Swift**

- Replaced external Python script with pure Swift implementation
- No longer requires bundled Python runtime, unified into single version (previously Premium version included Python)
- Significantly reduced app size (from ~50MB to ~5MB)
- Faster conversion speed with optimized performance
- Improved parsing reliability for .cur and .ani formats

**New Features:**

- Add Windows install.inf parser for automatic cursor type mapping
- Add support for legacy Windows cursor formats (16-bit RGB555/RGB565, 8-bit/4-bit/1-bit indexed, RLE compression)
- Add transparent window toggle in appearance settings
- Add GitHub Actions CI workflow for automated builds

**Improvements:**

- Backport to macOS 15 Sequoia with adaptive styling (Liquid Glass on macOS 26, Material on macOS 15)
- Convert mousecloak helper to ARC (Automatic Reference Counting) for better memory management
- Fix transparent window background for dark mode

**Bug Fixes:**

- Fixed memory alignment crash when parsing certain cursor files
- Fixed cape rename error when saving imported cursors
- Fixed dark mode transparent window showing washed-out colors

---

### v1.0.0 - SwiftUI Redesign for macOS Tahoe

> **Important:** This version requires **macOS Tahoe (26)** or later.

**UI:**

- Completely rebuilt the interface using SwiftUI, fully embracing the new Liquid Glass design language
- Added enlarged cursor preview on the home screen for better visibility
- Replaced TabView with page-based navigation and improved toolbar layout
- Full Dark Mode support with automatic system appearance switching
- Added localization support with Chinese language option

**Features:**

- Windows cursor import (Premium version only): One-click import from Windows cursor files
  - Supports `.cur` (static) and `.ani` (animated) formats
  - Automatically detects frame count and imports hotspot information
- Unified cursor size to 64px × 64px for consistency
- Updated CoreGraphics API for macOS Tahoe compatibility
- Improved helper daemon with better session change handling

**Other:**

- Removed Sparkle update framework (updates now via GitHub Releases)
- Cleaned up legacy Objective-C code and unused assets
- Fixed multiple UI display and preview issues
- Fixed edit function stability
- Security vulnerability fixes

---

### Known Limitations

Due to macOS system limitations, Mousecape has the following restrictions:

- **Image Size:** Maximum import size is 512×512 pixels. All images are automatically scaled to 64×64 pixels.
- **Animation Frames:** Maximum 24 frames per animated cursor. Animations with more frames are automatically downsampled.

---

### Version Selection Guide

The Debug version has no functional differences from the regular version, it only includes logging for error tracking.
For normal use, download the regular version.

---

## Credits

- **Original Author:** @AlexZielenski (2013-2025)
- **SwiftUI Redesign:** @sdmj76 (2025)
- **Coding Assistant:** Claude Code (Opus)
