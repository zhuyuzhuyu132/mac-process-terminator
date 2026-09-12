import Cocoa
import FlutterMacOS
import ApplicationServices

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // 新版 Flutter 模板中 AppDelegate 不再直接持有 window,
    // 需要从 NSApplication 中查找包含 FlutterViewController 的窗口
    guard let controller = NSApplication.shared.windows
        .compactMap({ $0.contentViewController as? FlutterViewController })
        .first else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "com.macappds.process_terminator",
      binaryMessenger: controller.engine.binaryMessenger)

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "listRunningApps":
        self.listRunningApps(result: result)
      case "terminateGracefully":
        self.terminate(call: call, force: false, result: result)
      case "forceQuit":
        self.terminate(call: call, force: true, result: result)
      case "activateApp":
        self.activateApp(call: call, result: result)
      case "systemShutdown":
        self.runSystemCommand(shutdown: true, result: result)
      case "systemRestart":
        self.runSystemCommand(shutdown: false, result: result)
      case "axTrusted":
        result(AXIsProcessTrusted())
      case "openAxSettings":
        self.openAxSettings(result: result)
      case "minimizeAllApps":
        self.minimizeAllApps(result: result)
      case "restoreAllApps":
        self.restoreAllApps(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.applicationDidFinishLaunching(notification)
  }

  /// 图标缓存,key 为应用安装目录(同一应用不重复提取)
  private var iconCache: [String: Data] = [:]

  /// 提取应用图标,缩小到 64x64 再编码 PNG(小尺寸编码极快,配合缓存避免重复提取)
  private func iconData(for app: NSRunningApplication) -> Data? {
    let key = app.bundleURL?.path ?? "pid-\(app.processIdentifier)"
    if let cached = iconCache[key] {
      return cached.isEmpty ? nil : cached
    }
    guard let icon = app.icon else {
      iconCache[key] = Data()
      return nil
    }
    let size = NSSize(width: 64, height: 64)
    let scaled = NSImage(size: size, flipped: false) { rect in
      icon.draw(in: rect,
                from: NSRect(origin: .zero, size: icon.size),
                operation: .copy,
                fraction: 1.0)
      return true
    }
    guard let tiff = scaled.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
      iconCache[key] = Data()
      return nil
    }
    iconCache[key] = png
    return png
  }

  /// 列出正在运行的常规应用(有 bundle 的前台类应用),排除本应用自身
  private func listRunningApps(result: @escaping FlutterResult) {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPid }
      .map { app -> [String: Any] in
        let iconPng = iconData(for: app)
        let dict: [String: Any] = [
          "pid": app.processIdentifier,
          "localizedName": app.localizedName ?? "PID \(app.processIdentifier)",
          "bundleId": app.bundleIdentifier ?? "",
          "isHidden": app.isHidden,
          "path": app.bundleURL?.path ?? "",
          "icon": iconPng ?? Data(),
        ]
        return dict
      }
    result(apps)
  }

  /// 获取指定进程的可执行文件路径(用于诊断与后续按路径匹配)
  private func processExecutablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return nil }
    return String(cString: buffer)
  }

  /// 通过 sysctl 枚举进程表,返回 root 及其全部后代进程的 PID
  /// (沿 PPID 递归,覆盖 Wine/CrossOver 这类多层容器子进程)
  private func processTreePIDs(root: pid_t) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [root] }

    // 进程数随时在变,返回值可能比预估大,失败时扩大缓冲区重试
    let stride = MemoryLayout<kinfo_proc>.stride
    var procList = [kinfo_proc]()
    for _ in 0..<3 {
      procList = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
      var actual = size
      if sysctl(&mib, 4, &procList, &actual, nil, 0) == 0 {
        procList.removeLast((size - actual) / stride)
        break
      }
      guard errno == ENOMEM else { return [root] }
      size *= 2
    }

    // 构建 pid -> ppid 映射,再从 root 沿子链收集后代
    var parentOf: [Int32: Int32] = [:]
    for p in procList {
      parentOf[p.kp_proc.p_pid] = p.kp_eproc.e_ppid
    }
    var tree: [pid_t] = [root]
    var queue: [pid_t] = [root]
    while !queue.isEmpty {
      let current = queue.removeFirst()
      for (pid, ppid) in parentOf where ppid == current && pid != current {
        tree.append(pid)
        queue.append(pid)
      }
    }
    return tree
  }

  /// 按指定方式关闭目标应用
  private func terminate(call: FlutterMethodCall, force: Bool, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let pid = args["pid"] as? Int else {
      result(FlutterError(code: "INVALID_ARGS", message: "缺少 pid 参数", details: nil))
      return
    }

    guard pid != ProcessInfo.processInfo.processIdentifier else {
      result(FlutterError(code: "SELF_TERMINATE", message: "不能关闭本应用自身", details: nil))
      return
    }

    let app = NSRunningApplication(processIdentifier: pid_t(pid))
    if app == nil && kill(pid_t(pid), 0) != 0 {
      // NSRunningApplication 找不到且进程不存在(或无权限)
      result(FlutterError(code: "NOT_FOUND", message: "未找到 PID \(pid) 对应的运行中应用", details: nil))
      return
    }
    // 进程存在但没有 bundle(如 Wine 容器内进程)时,app 为 nil,直接走下面的信号回退

    if force {
      // 优先用 NSRunningApplication,失败时回退到 POSIX SIGKILL
      // (Wine/CrossOver 等容器内的进程 forceTerminate 可能失败)
      var ok = NSRunningApplication(processIdentifier: pid_t(pid))?.forceTerminate() ?? false
      if !ok {
        ok = kill(pid_t(pid), SIGKILL) == 0 || errno == ESRCH
      }
      // 关键补充:杀掉整棵进程树。
      // CrossOver 中运行的 exe 是 Wine 主进程的子进程,只杀单个 PID
      // (尤其是 CrossOver 主程序)会留下孤儿 exe 继续运行,
      // 表现为"强制结束看似成功但 exe 还在",这也是部分机器杀不掉的根因
      if ok {
        let tree = processTreePIDs(root: pid_t(pid))
        for p in tree where p != pid_t(pid) {
          kill(p, SIGKILL) // 子进程尽力杀,失败不影响结果
        }
      }
      ok ? result(true) : result(FlutterError(
        code: "FORCE_QUIT_FAILED",
        message: "强制结束 PID \(pid) 失败(错误码 \(errno)),可能权限不足",
        details: nil))
    } else {
      // 优雅退出:先发正常退出请求,失败时回退到 POSIX SIGTERM
      var delivered = NSRunningApplication(processIdentifier: pid_t(pid))?.terminate() ?? false
      if !delivered {
        delivered = kill(pid_t(pid), SIGTERM) == 0
      }
      guard delivered else {
        result(FlutterError(
          code: "TERMINATE_FAILED",
          message: "发送退出请求失败(错误码 \(errno)),可改用强制结束",
          details: nil))
        return
      }

      // 等待 3 秒确认进程真的退出了;
      // 有些程序(如 Wine 容器内进程)会忽略退出信号,或弹出保存确认框等待用户操作
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if kill(pid_t(pid), 0) == 0 {
          result(FlutterError(
            code: "TERMINATE_TIMEOUT",
            message: "应用未响应退出请求(可能忽略了退出信号或正在等待保存确认),可改用强制结束",
            details: nil))
        } else {
          result(true)
        }
      }
    }
  }

  /// 最小化所有运行中应用的全部窗口(需要辅助功能权限)
  /// 返回成功最小化的窗口数量
  private func minimizeAllApps(result: @escaping FlutterResult) {
    let myPid = ProcessInfo.processInfo.processIdentifier
    // AX 调用较慢,放到后台线程执行,避免阻塞主线程
    DispatchQueue.global(qos: .userInitiated).async {
      var minimized = 0
      let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier != myPid
      }
      for app in apps {
        let appEl = AXUIElementCreateApplication(pid_t(app.processIdentifier))
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = (windowsRef as? NSArray) as? [AXUIElement] else {
          continue
        }
        for w in windows {
          var minRef: CFTypeRef?
          guard AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef) == .success,
                let isMin = minRef as? Bool, !isMin else {
            continue
          }
          if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
            minimized += 1
          }
        }
      }
      DispatchQueue.main.async { result(minimized) }
    }
  }

  /// 恢复所有应用:取消隐藏 + 恢复各应用最小化的窗口
  /// 返回被取消隐藏的应用数量
  private func restoreAllApps(result: @escaping FlutterResult) {
    let myPid = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.processIdentifier != myPid
    }
    // 先在后台恢复各应用最小化的窗口(AX 调用较慢),并统计恢复数量
    DispatchQueue.global(qos: .userInitiated).async {
      var restored = 0
      for app in apps {
        if self.unminimizeWindows(pid: Int(app.processIdentifier)) {
          restored += 1
        }
      }
      // unhide 需在主线程调用
      DispatchQueue.main.async {
        for app in apps where app.isHidden {
          app.unhide()
          restored += 1
        }
        result(restored)
      }
    }
  }

  /// 激活指定应用,将其窗口调到前台
  private func activateApp(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let pid = args["pid"] as? Int else {
      result(FlutterError(code: "INVALID_ARGS", message: "缺少 pid 参数", details: nil))
      return
    }

    let app = NSRunningApplication(processIdentifier: pid_t(pid))
    guard app != nil || kill(pid_t(pid), 0) == 0 else {
      result(FlutterError(code: "NOT_FOUND", message: "未找到 PID \(pid) 对应的运行中应用", details: nil))
      return
    }

    // 第一步:NSRunningApplication 常规激活
    if let app = app {
      // 若应用处于隐藏状态,先取消隐藏
      if app.isHidden {
        app.unhide()
      }
      // 恢复所有最小化的窗口,否则 activate() 只会让 Dock 图标弹一下
      unminimizeWindows(pid: pid)
      let ok: Bool
      if #available(macOS 14.0, *) {
        ok = app.activate()
      } else {
        ok = app.activate(options: [.activateAllWindows])
      }
      if ok {
        // activate() 可能返回成功但实际没到前台(如跨桌面空间),
        // 延迟验证是否真的激活,未激活则降级到 AppleScript 方式
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          if app.isActive {
            result(true)
          } else {
            self.activateViaAppleScript(pid: pid, result: result)
          }
        }
        return
      }
    }

    // 第二步:AppleScript 降级激活
    activateViaAppleScript(pid: pid, result: result)
  }

  /// 恢复指定进程所有最小化的窗口
  /// 依赖辅助功能(Accessibility)权限,未授权时静默失败
  @discardableResult
  private func unminimizeWindows(pid: Int) -> Bool {
    let appEl = AXUIElementCreateApplication(pid_t(pid))
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
          let windows = (windowsRef as? NSArray) as? [AXUIElement] else {
      return false
    }
    var restored = false
    for w in windows {
      var minRef: CFTypeRef?
      if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef) == .success,
         let minimized = minRef as? Bool, minimized {
        let ok = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success
        restored = restored || ok
      }
    }
    return restored
  }

  /// 通过 System Events 设置进程为最前,兼容部分无 bundle 或常规激活无效的进程
  private func activateViaAppleScript(pid: Int, result: @escaping FlutterResult) {
    let script = """
    tell application "System Events"
        tell (first application process whose unix id is \(pid))
            try
                set value of attribute "AXMinimized" of every window to false
            end try
            set frontmost to true
        end tell
    end tell
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let errPipe = Pipe()
    proc.standardError = errPipe
    do {
      try proc.run()
      DispatchQueue.global().async {
        proc.waitUntilExit()
        DispatchQueue.main.async {
          if proc.terminationStatus == 0 {
            result(true)
          } else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            var message = "激活失败(该进程可能是后台类型或没有可激活的窗口):\(err)"
            if !AXIsProcessTrusted() {
              message += "\n提示:请在 系统设置 → 隐私与安全性 → 辅助功能 中授权本应用,以支持恢复最小化窗口"
            }
            result(FlutterError(code: "ACTIVATE_FAILED", message: message, details: nil))
          }
        }
      }
    } catch {
      result(FlutterError(
        code: "ACTIVATE_FAILED",
        message: "无法执行激活命令:\(error.localizedDescription)",
        details: nil))
    }
  }

  /// 执行系统关机/重启(通过 AppleScript 控制系统事件)
  /// 首次使用会弹出"控制系统事件"授权,允许后即可
  private func runSystemCommand(shutdown: Bool, result: @escaping FlutterResult) {
    let script = shutdown
        ? "tell application \"System Events\" to shut down"
        : "tell application \"System Events\" to restart"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let errPipe = Pipe()
    proc.standardError = errPipe
    do {
      try proc.run()
      // 后台等待命令结束,避免阻塞主线程(如首次授权弹窗等待用户操作)
      DispatchQueue.global().async {
        proc.waitUntilExit()
        DispatchQueue.main.async {
          if proc.terminationStatus == 0 {
            result(true)
          } else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            result(FlutterError(
              code: "SYSTEM_CMD_FAILED",
              message: "\(shutdown ? "关机" : "重启")命令执行失败:\(err)",
              details: nil))
          }
        }
      }
    } catch {
      result(FlutterError(
        code: "SYSTEM_CMD_FAILED",
        message: "无法执行系统命令:\(error.localizedDescription)",
        details: nil))
    }
  }

  /// 打开系统设置的辅助功能权限页面
  private func openAxSettings(result: @escaping FlutterResult) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    proc.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
    do {
      try proc.run()
      result(true)
    } catch {
      result(FlutterError(
        code: "OPEN_SETTINGS_FAILED",
        message: "无法打开系统设置:\(error.localizedDescription)",
        details: nil))
    }
  }
}
