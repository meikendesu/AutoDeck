# AutoDeck

```text
Redmi Note 7 ── USB-C OTG ── DisplayLink 扩展坞 ── HDMI ── 显示器
```

DisplayLink Presenter 把 Android 画面通过 USB 发给扩展坞。AutoDeck 在 Android 16 上使用两个信号确认可以启动自动化：USB 树中出现唯一的匹配扩展坞设备，且 Presenter 持有屏幕捕获会话和处于开启状态的捕获显示。用户解锁并授权镜像后，模块在下一轮检查时启动配置的 HOME Activity，并临时把它设为默认启动器。检查周期约两秒。 [DisplayLink 的 Android OTG 接法](https://support.displaylink.com/knowledgebase/articles/557853) · [DisplayLink Presenter](https://play.google.com/store/apps/details?id=com.displaylink.presenter)

## 能力和兼容限制

| 需求 | 当前行为 |
| --- | --- |
| 识别插拔 | 手机能直接识别 OTG 侧 USB 设备的出现和消失。拔掉 HDMI 后，如果 Presenter 停止镜像，也会触发恢复。 |
| 只拔 HDMI | Presenter 如果仍在捕获，模块看不到这次变动。关屏最多 60 秒，临时启动器和镜像源尺寸会在会话最多 30 分钟后恢复。同一条持续存在的连接不会自动重新应用更改。 |
| 启动指定应用并设为默认启动器 | 配置的应用必须给主用户 0 提供一个可解析的 `MAIN/HOME` Activity。需要先存在一个可识别的原默认启动器。选定的应用显示在手机主显示上，由 Presenter 镜像到外屏。 |
| 分辨率 | 可配置 Android 镜像源的逻辑尺寸，例如竖屏坐标的 `1080x1920`。实际 HDMI 模式、缩放和黑边由 Presenter、芯片和屏幕决定。模块无法通过 AOSP 接口读到这条 USB 镜像路径的 HDMI EDID 或自动同步面板原生分辨率。 |
| 手机关屏 | 默认保留手机面板，避免在外屏尚无信号时同时失去画面。在人眼确认 HDMI 已出画后，可以手动申请 5–60 秒关屏。部分 ROM 关屏后会停止捕获或让 HDMI 变黑，此时使用镜像并保留本地面板。 |

Presenter 的 Play 商店页面与较早的支持文章列出的分辨率上限不同，实际可用模式以扩展坞芯片、应用版本和显示器实测为准。DRM 保护内容可能显示黑屏。扩展坞的 HDMI 口必须由 DisplayLink 芯片驱动，混合扩展坞的原生 DP Alt Mode 视频口无法通过手机 OTG 工作。 [Presenter 商店说明](https://play.google.com/store/apps/details?id=com.displaylink.presenter) · [Android 镜像兼容说明](https://support.displaylink.com/knowledgebase/articles/557862)

## 安装与配置

1. 从可信来源安装官方 DisplayLink Presenter。开启 OTG（如果 ROM 有独立开关），连接扩展坞及 HDMI 显示器。按 Android 提示授权 USB 和屏幕捕获。选择镜像整个屏幕（如果系统提供选项），先确认 HDMI 出画。模块使用系统已有的捕获会话，屏幕捕获授权由系统和 Presenter 完成。 [Android 屏幕捕获授权](https://developer.android.com/media/grow/media-projection)
2. 在开发环境用 Python 3 生成模块。把 `AutoDeck/AutoDeck.zip` 传到手机，在 KernelSU 管理器中安装并重启。

   ```bash
   python3 AutoDeck/Build-Module.py
   ```

3. 在手机终端执行 `su` 并授予该终端 KernelSU root 权限。以下命令均在 root shell 运行。模块需要读取 USB sysfs、查询 Android 服务，并对主用户 0 修改 HOME 角色、可选的镜像源尺寸和临时面板状态。保留 SELinux 的原有模式。诊断也可通过获准 root 的 ADB shell 执行。运行时不依赖 ADB 或其他主机。

   ```sh
   DECK=/data/adb/service.d/90-autodeck.sh
   sh "$DECK" doctor
   cmd package query-activities --components --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME
   ```

4. 从 `doctor` 的 USB 列表取扩展坞的 VID:PID。可先比较拔插前后列表以找出 DisplayLink 芯片。把下例中的组件和 VID:PID 换成实际值。第三个参数省略时匹配 `17e9:*`。第二个参数用 `keep` 保留原逻辑尺寸，也可使用 `1080x1920` 等 Android 坐标尺寸。设备重启后，需要先解锁才能启动会话。

   ```sh
   sh "$DECK" configure com.example.launcher/.HomeActivity keep 17e9:6006
   ```

5. 确认镜像及应用正常后，可选用一个短时关屏测试。确认外屏依旧有画面，再决定是否继续使用该功能。

   ```sh
   sh "$DECK" blank 5
   ```

## 失败回退与恢复

- 在首次改变尺寸和默认启动器前，模块将原启动器组件、原有尺寸覆盖和开机标识写入 `/data/adb/autodeck/session`，并同步到磁盘。没有原尺寸覆盖时恢复为 `wm size reset`。恢复时核对原值，并保留会话期间已明确改变的其他启动器或尺寸。密度设置不参与切换。
- OTG 拔出、投屏停止、手机锁定、模块禁用或会话到期时，先恢复面板，再恢复尺寸和启动器。恢复失败会保留日志并重试。恢复应用被卸载时，可重新安装该应用，或用 Android 的默认应用设置选定新的主屏幕应用。
- 关屏调用 AOSP 的临时电源命令。看门狗和独立限时进程均可解除覆盖，重启也会清除这项临时电源状态。系统可能在锁屏时停止捕获。 [AOSP 显示命令](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/services/core/java/com/android/server/display/DisplayManagerShellCommand.java) · [Android 捕获结束条件](https://developer.android.com/media/grow/media-projection)
- 模块有意使用独立的 KernelSU 启动脚本 `/data/adb/service.d/90-autodeck.sh`，以便模块被禁用或卸载后仍能处理待恢复记录。跨重启的 HOME 与尺寸恢复会等待主用户解锁。若 KernelSU 的启动脚本整体被停用，则在系统设置中手动恢复，或重新启用脚本后运行恢复。升级前先结束会话。 [KernelSU 模块生命周期](https://kernelsu.org/guide/module.html)

如遇异常，先拔掉手机端 OTG，尝试按电源键。如果 root shell 仍可用，执行：

```sh
sh /data/adb/service.d/90-autodeck.sh recover
cmd display power-reset 0
wm size -d 0
cmd role get-role-holders --user 0 android.app.role.HOME
```

## 验证

```bash
# 在仓库根目录执行。测试把 Android 命令和 USB 状态替换为临时文件模拟。
sudo bash AutoDeck/tests/device.sh
python3 AutoDeck/Build-Module.py
python3 -m zipfile -t AutoDeck/AutoDeck.zip
```

真机先记录 `wm size -d 0` 和原默认 HOME，然后连接 OTG、授权 Presenter 镜像。检查应用是否启动及临时设置是否生效。依次测试拔手机端 OTG、停止镜像、仅拔 HDMI、短时关屏和重启。仅拔 HDMI 时关注 Presenter 是否结束会话。保持捕获时，恢复依赖定时上限。暂未在实机 Redmi Note 7 或用户的扩展坞上验收。

## 项目结构

```text
AutoDeck/
├── README.md
├── Build-Module.py
├── module/
│   ├── module.prop
│   ├── customize.sh
│   ├── device.sh
│   └── uninstall.sh
└── tests/
    └── device.sh
```
