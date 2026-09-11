import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 拦截窗口关闭事件:由本类实现 NSWindowDelegate,点击关闭按钮时先弹确认框
    self.delegate = self

    super.awakeFromNib()
  }
}

extension MainFlutterWindow: NSWindowDelegate {
  /// 点击窗口红色关闭按钮(或 Cmd+W)时调用,返回 false 则不关闭
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "确定要关闭「到点关」吗?"
    alert.informativeText = "关闭后所有未完成的定时任务将被取消。"
    alert.addButton(withTitle: "确定关闭")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
