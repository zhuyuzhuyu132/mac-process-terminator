# mac-process-terminator

Flutter macOS 应用:列出正在运行的程序 → 多选 → 设置定时(倒计时 / 指定时间)自动关闭。

支持两种关闭方式:
- **优雅退出**:相当于向应用发送 Cmd+Q,应用可正常保存数据后退出。
- **强制结束**:SIGKILL 立即杀掉进程,未保存内容会丢失。

## 关键文件

| 文件 | 说明 |
|---|---|
| `lib/main.dart` | 全部 UI 与定时调度逻辑,`MacChannel` 封装平台通道 |
| `macos/Runner/AppDelegate.swift` | 原生实现:`NSWorkspace` 列出应用、`NSRunningApplication` 退出/杀进程 |
| `pubspec.yaml` | 依赖清单(仅 Flutter SDK,无第三方包) |

## 构建步骤(必须在 Mac 上执行)

本工程是"源码注入式"项目:`macos/` 目录只包含需要替换的 `AppDelegate.swift`。
先由 `flutter create` 生成完整工程,再用本仓库文件覆盖:

```bash
# 1. 生成 Flutter 工程(注意 --platforms 只含 macos,项目名必须保持 mac_process_terminator)
flutter create --platforms=macos --project-name mac_process_terminator mac_process_terminator_tmp

# 2. 把本目录的 lib/ 覆盖到生成工程
cp -R mac-process-terminator/lib mac_process_terminator_tmp/

# 3. 用本仓库的 AppDelegate.swift 覆盖生成的文件
cp mac-process-terminator/macos/Runner/AppDelegate.swift mac_process_terminator_tmp/macos/Runner/AppDelegate.swift

# 4. 关闭沙盒(访问其他应用进程必需)
#    编辑 mac_process_terminator_tmp/macos/Runner/DebugProfile.entitlements 和 Release.entitlements,
#    将 com.apple.security.app-sandbox 的值改为 false,或直接删除该键值对:
#    <key>com.apple.security.app-sandbox</key>
#    <false/>

# 5. 运行
cd mac_process_terminator_tmp
flutter run -d macos
```

## 发布构建

```bash
flutter build macos --release
# 产物: build/macos/Products/Release/mac_process_terminator.app
```

## 使用流程

1. 启动应用,自动加载正在运行的程序(已排除自身)。
2. 点击「选择应用并设置定时关闭」,搜索并勾选目标应用(可多选)。
3. 选择定时方式:**倒计时** 或 **指定时间**(若时间已过会自动顺延到明天)。
4. 选择关闭方式:**优雅退出**(推荐)或 **强制结束**。
5. 列表中实时显示剩余时间,可随时点 × 取消;到点自动执行并在顶部提示结果。

## 注意事项

- **沙盒必须关闭**:App Sandbox 下无法操作其他应用,否则 `terminate` 会失败或列表为空。
- **自动化权限**:首次执行退出操作时,macOS 可能要求授予"控制其他应用"权限,同意即可。
- 系统进程(如 Finder、Dock)policy 为非 regular,默认不出现在列表中。
- 若目标应用在到点前已被手动关闭,优雅退出/强杀会返回失败提示,可忽略或移除该定时。


git add .
git commit -m "描述这次改了什么"
git push
