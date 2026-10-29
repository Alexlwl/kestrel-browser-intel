import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate?

    private var controllers: [BrowserWindowController] = []
    /// URLs can arrive from LaunchServices before the first window exists (clicking a
    /// link while Kestrel is closed), so hold them until the window is up.
    private var isReady = false
    private var pendingURLs: [URL] = []
    private let bookmarksMenu = NSMenu(title: "书签")
    private let historyMenu = NSMenu(title: "历史")

    var front: BrowserWindowController? {
        if let w = NSApp.keyWindow?.windowController as? BrowserWindowController { return w }
        if let w = NSApp.mainWindow?.windowController as? BrowserWindowController { return w }
        return controllers.last
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // Compile the blocklist before the first web view exists: content rules are
        // attached at configuration time, so getting this in first avoids a reload.
        ContentBlocker.load { [weak self] _ in
            self?.openInitialWindow()
        }
    }

    private func openInitialWindow() {
        let c = makeWindow()
        let session = Store.shared.loadSession()
        if Config.shared.restoreSessionOnLaunch, !session.tabs.isEmpty {
            c.restore(saved: session.tabs, activeIndex: session.activeIndex)
            let sleeping = max(0, session.tabs.count - 1)
            if sleeping > 0 {
                c.showStatus("Restored \(session.tabs.count) tabs, \(sleeping) asleep")
            }
        }
        if !pendingURLs.isEmpty {
            // Open every URL, but focus the first, like Safari and Chrome do. Focusing
            // the last would leave whichever page happened to be at the end of the list
            // running in the foreground.
            let firstNew = c.tabs.count
            for u in pendingURLs {
                let tab = c.newTab(url: u, activate: false)
                tab.ensureLoaded()   // explicitly requested by the user, so load it now
            }
            pendingURLs.removeAll()
            c.selectTab(index: firstNew)
        } else if c.tabs.isEmpty {
            c.newTab()
        }
        isReady = true
        rebuildBookmarksMenu()
    }

    @discardableResult
    private func makeWindow(isPrivate: Bool = false) -> BrowserWindowController {
        let c = BrowserWindowController(isPrivate: isPrivate)
        controllers.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        if controllers.count > 1, let w = c.window {
            w.setFrameOrigin(NSPoint(x: w.frame.origin.x + 24, y: w.frame.origin.y - 24))
        }
        return c
    }

    func windowClosed(_ controller: BrowserWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controllers.forEach { $0.saveSessionNow() }
        Store.shared.flush()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { makeWindow().newTab() }
        return true
    }

    /// Links opened from other apps (and from being the default browser).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard isReady else { pendingURLs.append(contentsOf: urls); return }
        let c = front ?? makeWindow()
        for u in urls { c.newTab(url: u) }
        c.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Menu actions

    @objc func newTab() { (front ?? makeWindow()).newTab() }
    @objc func newWindow() { makeWindow().newTab() }
    @objc func newPrivateWindow() { makeWindow(isPrivate: true).newTab() }
    @objc func closeTab() { front?.closeActiveTab() }
    @objc func reopenClosedTab() { front?.reopenClosedTab() }
    @objc func focusAddressBar() { front?.focusURLField() }
    @objc func reload() { front?.reload() }
    @objc func stopLoading() { front?.stopLoading() }
    @objc func goBack() { front?.goBack() }
    @objc func goForward() { front?.goForward() }
    @objc func find() { front?.showFindBar() }
    @objc func findNext() { front?.findNext() }
    @objc func findPrevious() { front?.findPrevious() }
    @objc func bookmark() { front?.toggleBookmark() }
    @objc func zoomIn() { front?.zoomIn() }
    @objc func zoomOut() { front?.zoomOut() }
    @objc func zoomReset() { front?.zoomReset() }
    @objc func sleepBackgroundTabs() { front?.hibernateBackgroundTabsNow() }
    @objc func nextTab() { front?.selectRelativeTab(1) }
    @objc func previousTab() { front?.selectRelativeTab(-1) }
    @objc func openDownloadsFolder() { Downloads.shared.revealFolder() }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let c = front else { return }
        let n = sender.tag
        c.selectTab(index: n == 9 ? max(0, c.tabs.count - 1) : n)
    }

    @objc func openSettings() {
        Config.shared.save()
        NSWorkspace.shared.open(Config.supportDir.appendingPathComponent("config.json"))
    }

    @objc func openBlocklist() {
        if let u = ContentBlocker.domainListURL() { NSWorkspace.shared.open(u) }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let u = URL(string: sender.representedObject as? String ?? "") else { return }
        (front ?? makeWindow()).newTab(url: u)
    }

    @objc func clearHistory() {
        let a = NSAlert()
        a.messageText = "清除浏览历史?"
        a.informativeText = "书签和 Cookie 会保留。"
        a.addButton(withTitle: "清除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.clearHistory()
        rebuildHistoryMenu()
        front?.showStatus("历史已清除")
    }

    @objc func clearWebsiteData() {
        let a = NSAlert()
        a.messageText = "清除 Cookie 和缓存数据?"
        a.informativeText = "你将被登出所有网站。"
        a.addButton(withTitle: "清除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            URLCache.shared.removeAllCachedResponses()
            self?.front?.showStatus("网站数据已清除")
        }
    }

    @objc func makeDefaultBrowser() {
        guard let me = Bundle.main.bundleURL as URL? else { return }
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { [weak self] err in
            DispatchQueue.main.async {
                if let err {
                    self?.front?.showStatus("无法设为默认浏览器:\(err.localizedDescription)")
                } else {
                    NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { _ in }
                    self?.front?.showStatus("Kestrel 现在是默认浏览器")
                }
            }
        }
    }

    @objc func showAbout() {
        let s = MemoryMonitor.sample()
        let a = NSAlert()
        a.messageText = "Kestrel"
        a.informativeText = """
        基于系统 WebKit 引擎的极简浏览器。

        当前:\(s.display),共 \(s.helperCount + 1) 个进程。
        已屏蔽 \(ContentBlocker.ruleCount) 条广告和跟踪规则。
        后台标签页在 \(Int(Config.shared.hibernateAfterMinutes)) 分钟后休眠。
        """
        a.addButton(withTitle: "好")
        a.runModal()
    }

    // MARK: - Menu construction

    func rebuildBookmarksMenu() {
        bookmarksMenu.removeAllItems()
        let add = NSMenuItem(title: "为此页添加书签", action: #selector(bookmark), keyEquivalent: "d")
        add.target = self
        bookmarksMenu.addItem(add)
        bookmarksMenu.addItem(.separator())
        if Store.shared.bookmarks.isEmpty {
            let empty = NSMenuItem(title: "无书签", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            bookmarksMenu.addItem(empty)
        }
        for b in Store.shared.bookmarks {
            let title = b.title.isEmpty ? Store.displayForm(b.url) : b.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = b.url
            bookmarksMenu.addItem(item)
        }
    }

    func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        func add(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            historyMenu.addItem(i)
        }
        add("后退", #selector(goBack), "[")
        add("前进", #selector(goForward), "]")
        historyMenu.addItem(.separator())
        for e in Store.shared.recentHistory(limit: 15) {
            let title = e.title.isEmpty ? Store.displayForm(e.url) : e.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.url
            historyMenu.addItem(item)
        }
        historyMenu.addItem(.separator())
        add("清除历史记录\u{2026}", #selector(clearHistory), "")
        add("清除 Cookie 和缓存\u{2026}", #selector(clearWebsiteData), "")
    }

    private func buildMenu() {
        let main = NSMenu()

        func menu(_ title: String) -> (NSMenuItem, NSMenu) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            item.submenu = m
            main.addItem(item)
            return (item, m)
        }
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            i.tag = tag
            m.addItem(i)
        }

        // App menu
        let (_, app) = menu("Kestrel")
        add(app, "关于 Kestrel", #selector(showAbout), target: self)
        app.addItem(.separator())
        add(app, "设置\u{2026}", #selector(openSettings), ",", target: self)
        add(app, "编辑屏蔽列表\u{2026}", #selector(openBlocklist), target: self)
        add(app, "将 Kestrel 设为默认浏览器", #selector(makeDefaultBrowser), target: self)
        app.addItem(.separator())
        add(app, "隐藏 Kestrel", #selector(NSApplication.hide(_:)), "h")
        add(app, "隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        add(app, "全部显示", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        add(app, "退出 Kestrel", #selector(NSApplication.terminate(_:)), "q")

        // File
        let (_, file) = menu("文件")
        add(file, "新建标签页", #selector(newTab), "t", target: self)
        add(file, "新建窗口", #selector(newWindow), "n", target: self)
        add(file, "新建隐私窗口", #selector(newPrivateWindow), "n", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "打开位置\u{2026}", #selector(focusAddressBar), "l", target: self)
        file.addItem(.separator())
        add(file, "关闭标签页", #selector(closeTab), "w", target: self)
        add(file, "重新打开关闭的标签页", #selector(reopenClosedTab), "t", [.command, .shift], target: self)
        add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        file.addItem(.separator())
        add(file, "打开下载文件夹", #selector(openDownloadsFolder), "j", [.command, .shift], target: self)

        // Edit  (standard responder selectors: required for text editing inside pages)
        let (_, edit) = menu("编辑")
        add(edit, "撤销", Selector(("undo:")), "z")
        add(edit, "重做", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), "x")
        add(edit, "拷贝", #selector(NSText.copy(_:)), "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        add(edit, "粘贴并匹配样式", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        add(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        add(edit, "查找\u{2026}", #selector(find), "f", target: self)
        add(edit, "查找下一个", #selector(findNext), "g", target: self)
        add(edit, "查找上一个", #selector(findPrevious), "g", [.command, .shift], target: self)

        // View
        let (_, view) = menu("显示")
        add(view, "重新加载页面", #selector(reload), "r", target: self)
        add(view, "停止", #selector(stopLoading), ".", target: self)
        view.addItem(.separator())
        add(view, "实际大小", #selector(zoomReset), "0", target: self)
        add(view, "放大", #selector(zoomIn), "+", target: self)
        add(view, "缩小", #selector(zoomOut), "-", target: self)
        view.addItem(.separator())
        add(view, "立即休眠后台标签页", #selector(sleepBackgroundTabs), "h", [.command, .shift], target: self)
        view.addItem(.separator())
        add(view, "进入全屏", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // History
        let (historyItem, _) = menu("历史")
        historyItem.submenu = historyMenu
        historyMenu.delegate = self
        rebuildHistoryMenu()

        // Bookmarks
        let (bmItem, _) = menu("书签")
        bmItem.submenu = bookmarksMenu

        // Window
        let (windowItem, windowMenu) = menu("窗口")
        add(windowMenu, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windowMenu, "缩放", #selector(NSWindow.performZoom(_:)))
        windowMenu.addItem(.separator())
        add(windowMenu, "显示下一个标签页", #selector(nextTab), "\u{0009}", [.control], target: self)
        add(windowMenu, "显示上一个标签页", #selector(previousTab), "\u{0009}", [.control, .shift], target: self)
        // Arrow variants: the shortcut most people reach for first.
        add(windowMenu, "下一个标签页(方向键)", #selector(nextTab), "\u{F703}", [.command, .option], target: self)
        add(windowMenu, "上一个标签页(方向键)", #selector(previousTab), "\u{F702}", [.command, .option], target: self)
        windowMenu.addItem(.separator())
        for n in 1...9 {
            add(windowMenu, "标签页 \(n)", #selector(selectTabByNumber(_:)), "\(n)", target: self, tag: n - 1)
        }
        windowMenu.addItem(.separator())
        add(windowMenu, "前置全部窗口", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = windowMenu
        _ = windowItem

        NSApp.mainMenu = main
    }

    /// Refresh the history submenu lazily when it is opened, not on every page load.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu { rebuildHistoryMenu() }
    }
}
