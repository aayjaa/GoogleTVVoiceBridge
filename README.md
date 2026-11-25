# GoogleTVVoiceBridge

轻量级 macOS 菜单栏工具：通过 CoreBluetooth 直接连接 **Google TV Remote**（特别是未完成 macOS 蓝牙加密绑定、在系统蓝牙界面一直转圈的 Telink 方案兼容遥控器，例如 `VID 0x18D1 / PID 0x9451`、`ZTKA-IR57`、`V3.4.2.1`），实时解码 Google **ATVV v1.0**（8 kHz / 16 kHz IMA-ADPCM）语音流并送入 **`Remote Buddy Mic`** 虚拟麦克风，同时自动触发语音输入快捷键（适配网易叭哥说、Typeless、macOS 听写等）。

## 为什么需要它？

部分市面上标称「Google TV / Chromecast」的第三方蓝牙语音遥控器（如泰凌微 Telink 芯片、`VID 0x18D1 / PID 0x9451`、`ZTKA-IR57`）：
1. 蓝牙名称为 `Google TV Remote`（而非 `Chromecast Remote`）；
2. 与 macOS 系统蓝牙连接时未完成 SMP 加密绑定（`enc-state: OFF`），导致系统蓝牙设置界面一直转圈；
3. 但其标准 Google **ATVV 语音服务**（`AB5E0001-5A21-4F05-BC7D-AF01F617B664`）在未加密 GATT 下完全可用，支持 `GET_CAPS` 协商（8 kHz IMA-ADPCM、134 字节帧长）及完整语音流推送。

`GoogleTVVoiceBridge` 直接使用 macOS 公开 `CoreBluetooth`、`AVAudioEngine` / `CoreAudio` 和 `CGEvent` API 打通整条链路，无需安装完整 Xcode，仅用 Xcode Command Line Tools (`swiftc`) 即可一键编译。

## 功能特性

- **免系统配对转圈直连**：自动发现并直连 `Google TV Remote` / `Chromecast Remote`，断线自动重连，实时显示电量。
- **ATVV v1.0 实时解码**：支持 8 kHz（134 字节帧）和 16 kHz（160 字节帧）IMA-ADPCM 实时解码并高质量重采样输出到 `Remote Buddy Mic`。
- **多热键 & 触发模式**：
  - 语音热键支持：`Fn`、右 `Option`、右 `Command`、`Option + Space`、`Ctrl + Option + V`、`Ctrl + Shift + V`、`Command + Shift + Space`、或仅传输音频。
  - 触发方式支持：**按住模式（Hold）**、**点按模式（Tap Start / Stop）**、**macOS 听写（双击 Fn）**。
- **可调麦克风增益**：`1.0x` / `1.5x` / `2.0x` / `3.0x`，内置 1 秒测试音便于验证虚拟麦克风通路。

## 前置条件

1. macOS 14+ 与 Xcode Command Line Tools（`xcode-select --install`）。
2. 已安装 `Remote Buddy Mic` 虚拟麦克风驱动（来自开源项目 [zfdang/remote-buddy](https://github.com/zfdang/remote-buddy)）。

## 构建与运行

```bash
chmod +x build.sh
./build.sh
open GoogleTVVoiceBridge.app
```

首次启动时：
1. 允许 **蓝牙** 权限；
2. 点击顶部菜单栏图标，授予 **辅助功能** 权限（用于发送语音触发热键）；
3. 在语音输入工具（如网易叭哥说、Typeless）中将麦克风设为 **`Remote Buddy Mic`**，并将菜单栏中的热键与触发模式调整为与输入工具一致即可使用。

运行日志位于：`~/Library/Logs/GoogleTVVoiceBridge/bridge.log`。
