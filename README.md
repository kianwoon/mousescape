# Mousecape-swiftUI

Cursor Manager for MacOS 15 / 26 with SwiftUI.

> **Note**: This is a placeholder repository. The original repository (sdmj76/Mousecape-swiftUI) has been deleted. This README was reconstructed from the Wayback Machine archive.

## About

A free macOS cursor manager that allows you to easily replace Mac system pointers.

一款免费的 macOS 光标管理器，让你轻松替换 Mac 系统指针。

Built with SwiftUI, fully adapted to Liquid Glass design language, with complete support for macOS Tahoe.

使用 SwiftUI 构建，全面适配液态玻璃设计语言，完整支持 macOS Tahoe。

## Features

- Customize Mac system cursors, supporting both static and animated cursors
- One-click import of Windows cursor formats (.cur / .ani)
- Uses private, non-intrusive CoreGraphics API, safe and reliable
- Runs silently in the background without interfering with the system

## System Requirements

- macOS Sequoia (15) or later
- Support Architectures: Intel and Apple Silicon Macs

## Latest Release (SwiftUI_v1.0.1)

### Major Update: Windows cursor conversion rewritten from Python to native Swift

- Replaced external Python script with pure Swift implementation
- No longer requires bundled Python runtime
- Significantly reduced app size (from ~15MB to ~5MB)
- Faster conversion speed with optimized performance
- Improved parsing reliability for .cur and .ani formats

### New Features

- Add Windows install.inf parser for automatic cursor type mapping
- Add support for legacy Windows cursor formats (16-bit RGB555/RGB565, 8-bit/4-bit/1-bit indexed, RLE compression)
- Add transparent window toggle in appearance settings
- Add GitHub Actions CI workflow for automated builds

### Improvements

- Backport to macOS 15 Sequoia with adaptive styling (Liquid Glass on macOS 26, Material on macOS 15)
- Convert mousecloak helper to ARC for better memory management
- Fix transparent window background for dark mode

## Original Credits

- **Original Author**: @alexzielenski (2013-2025)
- **SwiftUI Redesign**: @sdmj76 (2025)
- **Coding Assistant**: Claude Code (Opus)
- **macOS 15 Backport**: @isandrel
- **Demo and example cursor "Kiriko"**: Created by ArakiCC

## Archive Information

This repository was reconstructed from the Wayback Machine archive:
- Original URL: https://github.com/sdmj76/Mousecape-swiftUI
- Archive Snapshot: January 28, 2026
- Archive Link: https://web.archive.org/web/20260128082537/https://github.com/sdmj76/Mousecape-swiftUI

## Parent Repository

The original Mousecape project by Alex Zielenski may still be available at:
https://github.com/alexzielenski/Mousecape

## License

Please refer to the original repository for license information.

## Restoration

If you have a copy of the source code for the SwiftUI version, please consider contributing it to restore this project.
