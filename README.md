# 到点关 (mac-process-terminator)

一款 Flutter macOS 应用：列出正在运行的程序 → 多选 → 设置定时（倒计时 / 指定时间）自动关闭，同时支持定时关机 / 重启、窗口最小化与恢复。

## 功能特性

- **定时关闭应用**：多选正在运行的应用，支持倒计时或指定时间（时间已过自动顺延到明天），同一 PID 只保留最新定时。
- **两种关闭方式**：
  - **优雅退出**：相当于向应用发送 Cmd+Q，应用可正常保存数据后退出；超时失败时可一键升级为强制结束。
  - **强制结束**：SIGKILL 立即杀掉进程，未保存内容会丢失。
- **定时关机 / 重启**：到点自动执行，执行前有确认弹窗，同类型系统任务只保留最新的一个。
- **窗口管理**：一键最小化所有应用窗口 / 恢复所有应用窗口（恢复最小化窗口需「辅助功能」权限）。
- **应用激活**：可将任意应用的窗口调到前台。
- **其他细节**：应用图标显示、按名称搜索、隐藏应用排在后面、同名多实例用路径区分、剩余时间实时刷新、可随时取消定时（带确认）。

## 关键文件

| 文件 | 说明 |
|---|---|
| `lib/main.dart` | 全部 UI 与定时调度逻辑，`MacChannel` 封装平台通道 |
| `macos/Runner/AppDelegate.swift` | 原生实现：`NSWorkspace` 列出应用、`NSRunningApplication` 退出/杀进程/激活、辅助功能操作 |
| `pubspec.yaml` | 依赖清单（仅 Flutter SDK，无第三方包） |

## 构建步骤（必须在 Mac 上执行）

cd mac_process_terminator_tmp
flutter run -d macos
```

## 发布构建

```bash
flutter build macos --release
# 产物: build/macos/Products/Release/mac_process_terminator.app
```

## 使用流程

1. 启动应用，自动加载正在运行的程序（已排除自身）。
2. 点击「选择应用并设置定时关闭」，搜索并勾选目标应用（可多选）。
3. 选择定时方式：**倒计时** 或 **指定时间**（若时间已过会自动顺延到明天）。
4. 选择关闭方式：**优雅退出**（推荐）或 **强制结束**。
5. 列表中实时显示剩余时间，可随时点 × 取消；到点自动执行并在顶部提示结果。

如需**定时关机 / 重启**或**最小化 / 恢复所有应用窗口**，直接点击首页对应的按钮即可。

## 注意事项

- **沙盒必须关闭**：App Sandbox 下无法操作其他应用，否则 `terminate` 会失败或列表为空。
- **自动化权限**：首次执行退出操作时，macOS 可能要求授予「控制其他应用」权限，同意即可。
- **辅助功能权限**：恢复最小化窗口需要「辅助功能」权限，应用会在需要时引导开启（系统设置 → 隐私与安全性 → 辅助功能）。
- 系统进程（如 Finder、Dock）policy 为非 regular，默认不出现在列表中。
- 若目标应用在到点前已被手动关闭，优雅退出/强杀会返回失败提示，可忽略或移除该定时。

### 重新构建后辅助功能权限失效怎么办

未配置签名团队时，应用每次构建都使用临时 ad-hoc 签名，签名一变 macOS 就会**自动撤销**之前授予的「辅助功能」授权，导致激活窗口 / 最小化全部 / 恢复全部失灵。修复方法：

```bash
# 1. 重置本应用的辅助功能授权记录
tccutil reset Accessibility com.example.macProcessTerminator

# 2. 重新运行应用,点击任一需要权限的功能,按弹窗指引到
#    系统设置 → 隐私与安全性 → 辅助功能 重新添加并开启
```

> 注意：`tccutil reset` 只是恢复授权的手段，**并不能让签名稳定**。要让授权在重新构建后不失效，必须在 Xcode 中给 Runner target 配置签名团队：
>
> 1. 用 Xcode 打开 `macos/Runner.xcworkspace`
> 2. 选中 Runner target → Signing & Capabilities → 勾选 Automatically manage signing，选择你的 Team（免费 Apple ID 也可以）
> 3. 重新构建，签名将基于 团队 ID + Bundle ID，跨构建保持稳定，授权一次即可长期有效

## 版本提交

日常开发提交变更：

```bash
git add .
git commit -m "BUG修复"
git push

git add . && git commit -m "BUG修复" && git push

```
