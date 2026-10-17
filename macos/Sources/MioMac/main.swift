// MioMac 入口：纯 AppKit 生命周期（没有 storyboard / nib，菜单和窗口都在代码里建）
import AppKit

let app = NSApplication.shared
let appDelegate = MioMacAppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
