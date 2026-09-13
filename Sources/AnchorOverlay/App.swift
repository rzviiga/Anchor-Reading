import AppKit
import ScreenCaptureKit
import Carbon
import AnchorOverlayCore

@main
enum AnchorOverlayApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var item: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var metricItem: NSMenuItem!
    private var resumeItem: NSMenuItem!
    private var keyboardItem: NSMenuItem!
    private let keyboardMonitor = KeyboardMonitor()
    private var hotKey: GlobalHotKey?
    private var pipeline: (any ReadingCapturePipeline)?
    private var panels = [CGDirectDisplayID: OverlayPanel]()
    private var monitor: Any?
    private var localMonitor: Any?
    private var observers = [NSObjectProtocol]()
    private var running = false
    private var transitioning = false
    private var lifecycle: UInt64 = 0
    private var lastInteraction: TimeInterval = -.infinity
    private var mouseButtons = 0
    private var selectionProtected = false
    private var releaseTimer: Timer?
    private var menuOpen = false
    private var pressedKeys = Set<CGKeyCode>()
    private var heldModifiers: CGEventFlags = []
    private var keyboardSettling = false
    private var keyboardWake: Task<Void, Never>?
    private var keyboardRevision: UInt64 = 0
    private let keyboardModifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    private var keyboardBusy: Bool { keyboardSettling || !pressedKeys.isEmpty || !heldModifiers.isEmpty }
    private var suppressPresentation: Bool {
        selectionProtected || mouseButtons != 0 || NSEvent.pressedMouseButtons != 0 || (energySaving && (menuOpen || keyboardBusy))
    }
    private var ratio: Double = UserDefaults.standard.object(forKey:"ratio") as? Double ?? 0.4
    private var captureScale: Double = UserDefaults.standard.object(forKey:"scale") as? Double ?? 2.0
    private var energySaving = UserDefaults.standard.bool(forKey: "energySaving")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "A◦"; item.button?.toolTip = "Anchor Overlay · ⌃⌥⌘B"
        buildMenu()
        keyboardMonitor.onActivity = { [weak self] activity in self?.keyboardInteraction(activity) }
        keyboardMonitor.onInterrupted = { [weak self] in
            guard let self, self.running, self.energySaving else { return }
            self.keyboardWake?.cancel(); self.keyboardWake=nil
            self.pressedKeys.removeAll(); self.heldModifiers=[]
            self.keyboardSettling=true
            self.updateInteraction()
            self.keyboardItem.title="键盘感知：监听中断，点击重试"
        }
        hotKey = GlobalHotKey { [weak self] in Task { @MainActor in self?.toggle() } }
        if hotKey?.register() != noErr { metricItem.title = "快捷键被占用，请使用菜单开关" }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .magnify, .swipe]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.interaction(event) }
        // Observe only: always return the original event to its original target.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.interaction(event); return event }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object:nil, queue:.main) { [weak self] _ in Task { @MainActor in await self?.reconfigure() } })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object:nil, queue:.main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            Task { @MainActor in
                guard let self, self.mouseButtons == 0, NSEvent.pressedMouseButtons == 0 else { return }
                self.resumeReading()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object:nil, queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.energySaving else { return }
                self.resumeReading()
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in await self?.stop() } })
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate=self
        toggleItem = NSMenuItem(title: "开启强调    ⌃⌥⌘B", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self; menu.addItem(toggleItem)
        let energy = NSMenuItem(title:"节能模式（按需截图）",action:#selector(toggleEnergySaving(_:)),keyEquivalent:"")
        energy.target=self; energy.state=energySaving ? .on : .off
        menu.addItem(energy)
        keyboardItem = NSMenuItem(title:"键盘感知：设置输入监控权限…",action:#selector(enableKeyboardMonitoring),keyEquivalent:"")
        keyboardItem.target=self; keyboardItem.isHidden = !energySaving
        menu.addItem(keyboardItem)
        metricItem = NSMenuItem(title: "已暂停 · 滚动时隐藏，停稳后恢复", action:nil,keyEquivalent:"")
        menu.addItem(metricItem)
        resumeItem = NSMenuItem(title:"恢复阅读增强（结束选区保护）",action:#selector(resumeReading),keyEquivalent:"")
        resumeItem.target=self
        menu.addItem(resumeItem)
        let refresh = NSMenuItem(title:"刷新当前画面",action:#selector(refreshSnapshot),keyEquivalent:"")
        refresh.target=self; menu.addItem(refresh); menu.addItem(.separator())
        let ratioMenu = NSMenu()
        for (title, value) in [("仅首字母", 0), ("词首 40%（默认）",40), ("词首 50%",50)] {
            let entry = NSMenuItem(title:title,action:#selector(setRatio(_:)),keyEquivalent:"")
            entry.target=self; entry.tag=value; entry.state = (value == Int(ratio*100)) ? .on : .off; ratioMenu.addItem(entry)
        }
        let ratioRoot=NSMenuItem(title:"强调范围",action:nil,keyEquivalent:""); ratioRoot.submenu=ratioMenu; menu.addItem(ratioRoot)
        let qualityMenu = NSMenu()
        for (title,value) in [("速度优先 · 1×",10),("均衡 · 1.5×",15),("字形清晰 · 2×（默认）",20)] {
            let entry=NSMenuItem(title:title,action:#selector(setScale(_:)),keyEquivalent:"")
            entry.target=self; entry.tag=value; entry.state=value==Int(captureScale*10) ? .on : .off; qualityMenu.addItem(entry)
        }
        let quality=NSMenuItem(title:"识别分辨率",action:nil,keyEquivalent:""); quality.submenu=qualityMenu; menu.addItem(quality)
        menu.addItem(.separator())
        let help=NSMenuItem(title:"权限与使用说明…",action:#selector(showHelp),keyEquivalent:""); help.target=self; menu.addItem(help)
        let quit=NSMenuItem(title:"退出 Anchor Overlay",action:#selector(quitApp),keyEquivalent:"q"); quit.target=self; menu.addItem(quit)
        item.menu=menu
    }

    @objc private func toggle() {
        guard !transitioning else { return }
        Task { if running { await stop() } else { await start() } }
    }

    private func start() async {
        guard !transitioning else { return }
        transitioning=true; defer { transitioning=false }
        lifecycle &+= 1
        let ticket = lifecycle
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            showPermissionHelp(); return
        }
        metricItem.title="正在准备屏幕识别…"
        do {
            // Establish our windows before enumerating, so own-app exclusion is reliable.
            for screen in NSScreen.screens {
                guard let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
                let panel=OverlayPanel(screen:screen, avoidSystemPopups:energySaving); panels[id]=panel
                panel.orderFrontRegardless()
            }
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            guard lifecycle == ticket else { return }
            let next: any ReadingCapturePipeline = energySaving ? SnapshotCapturePipeline() : CapturePipeline()
            next.onInvalidate = { [weak self, weak next] id in
                guard let self, let next, self.pipeline === next else { return }
                self.panels[id]?.clear()
            }
            next.onResult = { [weak self, weak next] id,result,size in
                guard let self, let next, self.pipeline === next, self.running else { return }
                // Main-thread input clears the panel immediately; don't resurrect it
                // while the queue is still learning about the newest scroll event.
                guard !self.suppressPresentation,
                      ProcessInfo.processInfo.systemUptime-self.lastInteraction >= 0.16 else { return }
                self.panels[id]?.present(result.patches,pixelSize:size)
                self.metricItem.title=String(format:"识别 %d 词 · 增强 %d 词 · OCR %.0f ms · 字形 %.0f ms",result.wordCount,result.patches.count,result.ocrMilliseconds,result.maskMilliseconds)
            }
            next.onIdle = { [weak self, weak next] in
                guard let self, let next, self.pipeline === next, self.running,
                      !self.suppressPresentation else { return }
                self.metricItem.title="节能 · 静止休眠 · "+self.metricItem.title
            }
            next.onRetainPatches = { [weak self, weak next] id,patches,size in
                guard let self, let next, self.pipeline === next, self.running,
                      !self.suppressPresentation,
                      ProcessInfo.processInfo.systemUptime-self.lastInteraction >= 0.16 else { return }
                self.panels[id]?.present(patches,pixelSize:size)
            }
            next.onError = { [weak self, weak next] message in
                Task { @MainActor in
                    guard let self, let next, self.pipeline === next else { return }
                    await self.stop(); self.metricItem.title="已暂停："+message
                }
            }
            pipeline=next
            try await next.start(content:content,captureScale:captureScale,policy:ReadingPolicy(ratio:ratio == 0 ? 0.05 : ratio,maxLetters:ratio == 0 ? 1 : 4))
            guard lifecycle == ticket else { await next.stop(); return }
            running=true; item.button?.title="A●"; toggleItem.title="暂停强调    ⌃⌥⌘B"
            metricItem.title=energySaving ? "节能模式 · 等待首次截图…" : "已开启 · 滚动时隐藏强调"
            refreshKeyboardMonitoring()
            mouseButtons = NSEvent.pressedMouseButtons
            if suppressPresentation {
                if mouseButtons != 0 { watchMouseRelease() }
                updateInteraction()
            }
        } catch {
            await pipeline?.stop(); pipeline=nil
            for panel in panels.values { panel.close() }; panels.removeAll()
            metricItem.title="启动失败："+error.localizedDescription
            let alert=NSAlert(); alert.messageText="未能开始屏幕识别"; alert.informativeText=error.localizedDescription+"\n若刚授予屏幕录制权限，请退出并重新打开此应用。"; alert.runModal()
        }
    }

    private func stop() async {
        lifecycle &+= 1
        let alreadyTransitioning = transitioning
        transitioning = true
        defer { if !alreadyTransitioning { transitioning = false } }
        running=false; item.button?.title="A◦"; toggleItem.title="开启强调    ⌃⌥⌘B"
        keyboardMonitor.stop()
        keyboardWake?.cancel(); keyboardWake=nil; keyboardRevision &+= 1
        pressedKeys.removeAll(); heldModifiers=[]; keyboardSettling=false
        releaseTimer?.invalidate(); releaseTimer=nil
        mouseButtons=0; selectionProtected=false
        for panel in panels.values { panel.clear(); panel.close() }; panels.removeAll()
        let previous=pipeline; pipeline=nil; await previous?.stop()
        metricItem.title="已暂停 · 屏幕捕获已停止"
    }

    private func interaction(_ event: NSEvent) {
        guard running else { return }
        // A fresh pointer action can recover a lost key-up without a polling timer.
        if energySaving { recoverReleasedKeys() }
        switch event.type {
        case .leftMouseDown:
            // A plain new click ends the previous selection. Double/triple-click
            // and Shift-click can select text without any dragged events.
            selectionProtected = event.clickCount >= 2 || event.modifierFlags.contains(.shift)
            mouseButtons |= 1
        case .leftMouseDragged:
            mouseButtons |= 1; selectionProtected = true
        case .rightMouseDown, .rightMouseDragged:
            mouseButtons |= 2
        case .otherMouseDown, .otherMouseDragged:
            mouseButtons |= 1 << event.buttonNumber
        case .leftMouseUp:
            mouseButtons &= ~1
        case .rightMouseUp:
            mouseButtons &= ~2
        case .otherMouseUp:
            mouseButtons &= ~(1 << event.buttonNumber)
        case .scrollWheel, .magnify, .swipe:
            if mouseButtons == 0 { selectionProtected = false }
        default: break
        }
        if mouseButtons != 0 { watchMouseRelease() }
        else { releaseTimer?.invalidate(); releaseTimer=nil }
        updateInteraction()
    }

    private func updateInteraction() {
        if mouseButtons == 0, NSEvent.pressedMouseButtons != 0 {
            mouseButtons=NSEvent.pressedMouseButtons
            watchMouseRelease()
        }
        lastInteraction=ProcessInfo.processInfo.systemUptime
        for panel in panels.values { panel.clear() }
        pipeline?.interact(suspended: suppressPresentation)
        if selectionProtected {
            metricItem.title="选区保护 · 可正常复制；单击或滚动后恢复增强"
        } else if energySaving && menuOpen {
            metricItem.title="节能模式 · 关闭菜单后更新"
        } else if energySaving && keyboardBusy {
            metricItem.title="键盘操作中 · 隐藏强调，停止输入后更新"
        } else if suppressPresentation {
            metricItem.title="鼠标操作中 · 暂时隐藏强调"
        } else {
            metricItem.title=energySaving ? "节能模式 · 操作结束后截图一次…" : "等待画面稳定后恢复增强…"
        }
    }

    private func watchMouseRelease() {
        guard releaseTimer == nil else { return }
        // Some apps consume mouse-up inside a modal tracking loop. Observe only
        // button state as a fallback, so a missed release cannot leave us stuck.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.mouseButtons != 0,
                      NSEvent.pressedMouseButtons == 0,
                      ProcessInfo.processInfo.systemUptime-self.lastInteraction >= 0.10 else { return }
                self.mouseButtons=0
                self.releaseTimer?.invalidate(); self.releaseTimer=nil
                self.updateInteraction()
            }
        }
        releaseTimer=timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func resumeReading() {
        guard running else { return }
        if energySaving { recoverReleasedKeys() }
        selectionProtected=false
        mouseButtons=NSEvent.pressedMouseButtons
        if mouseButtons != 0 { watchMouseRelease() }
        else { releaseTimer?.invalidate(); releaseTimer=nil }
        updateInteraction()
    }

    private func reconfigure() async {
        guard running, !transitioning else { return }
        await stop(); await start()
    }
    @objc private func toggleEnergySaving(_ sender: NSMenuItem) {
        guard !transitioning else { return }
        energySaving.toggle()
        UserDefaults.standard.set(energySaving, forKey: "energySaving")
        sender.state=energySaving ? .on : .off
        keyboardItem.isHidden = !energySaving
        if running {
            Task { await reconfigure() }
        } else {
            metricItem.title=energySaving ? "已暂停 · 下次开启使用节能模式" : "已暂停 · 下次开启使用常规模式"
        }
    }
    @objc private func refreshSnapshot() {
        guard energySaving, !transitioning else { return }
        resumeReading()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(refreshSnapshot) { return running && energySaving && !transitioning }
        if menuItem.action == #selector(resumeReading) { return running && !transitioning }
        return !transitioning
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen=true
        refreshKeyboardMonitoring()
        if running && energySaving { recoverReleasedKeys(); updateInteraction() }
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen=false
        if running && energySaving { updateInteraction() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshKeyboardMonitoring()
    }

    private func refreshKeyboardMonitoring() {
        guard keyboardItem != nil else { return }
        if running && energySaving {
            let listening = keyboardMonitor.start()
            keyboardItem.title = listening ? "键盘感知：已开启" :
                (CGPreflightListenEventAccess() ? "键盘感知：不可用，点击重试" : "键盘感知：需要输入监控权限…")
        } else {
            keyboardMonitor.stop()
            keyboardItem.title = CGPreflightListenEventAccess() ? "键盘感知：随节能模式启用" : "键盘感知：需要输入监控权限…"
        }
    }

    @objc private func enableKeyboardMonitoring() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        refreshKeyboardMonitoring()
        if !CGPreflightListenEventAccess(),
           let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func keyboardInteraction(_ activity: KeyboardMonitor.Activity) {
        guard running, energySaving else { return }
        heldModifiers = activity.flags.intersection(keyboardModifierMask)
        switch activity.type {
        case .keyDown:
            pressedKeys.insert(activity.keyCode)
            let navigation: Set<CGKeyCode> = [CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow),
                CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow), CGKeyCode(kVK_Home), CGKeyCode(kVK_End),
                CGKeyCode(kVK_PageUp), CGKeyCode(kVK_PageDown)]
            if (activity.flags.contains(.maskCommand) && activity.keyCode == CGKeyCode(kVK_ANSI_A)) ||
                (activity.flags.contains(.maskShift) && navigation.contains(activity.keyCode)) {
                selectionProtected=true
            } else if !(activity.flags.contains(.maskCommand) && activity.keyCode == CGKeyCode(kVK_ANSI_C)) {
                selectionProtected=false
            }
        case .keyUp: pressedKeys.remove(activity.keyCode)
        default: break
        }
        keyboardSettling=true
        keyboardRevision &+= 1
        keyboardWake?.cancel()
        // Invalidate both the visible patches and any pending/in-flight snapshot.
        updateInteraction()
        let ticket = keyboardRevision
        keyboardWake = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.running, self.energySaving,
                  self.keyboardRevision == ticket else { return }
            self.keyboardWake=nil
            self.recoverReleasedKeys()
            guard !self.keyboardBusy else { return }
            // The snapshot pipeline then applies its existing 0.3 s settle delay.
            self.updateInteraction()
        }
    }

    private func recoverReleasedKeys() {
        guard keyboardBusy else { return }
        pressedKeys = pressedKeys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }
        heldModifiers = CGEventSource.flagsState(.combinedSessionState).intersection(keyboardModifierMask)
        if pressedKeys.isEmpty && heldModifiers.isEmpty {
            keyboardSettling=false
            keyboardWake?.cancel(); keyboardWake=nil
        }
    }
    @objc private func setRatio(_ sender:NSMenuItem) {
        ratio=Double(sender.tag)/100; UserDefaults.standard.set(ratio,forKey:"ratio")
        Task { let wasRunning=running; if wasRunning { await stop() }; buildMenu(); if wasRunning { await start() } }
    }
    @objc private func setScale(_ sender:NSMenuItem) {
        captureScale=Double(sender.tag)/10; UserDefaults.standard.set(captureScale,forKey:"scale")
        Task { let wasRunning=running; if wasRunning { await stop() }; buildMenu(); if wasRunning { await start() } }
    }
    @objc private func quitApp() { Task { await stop(); NSApp.terminate(nil) } }
    @objc private func showHelp() {
        let alert=NSAlert(); alert.messageText="Anchor Overlay"
        alert.informativeText="⌃⌥⌘B 开启或暂停。鼠标与滚轮可直接穿透。按住鼠标期间隐藏强调；选字后保持隐藏，方便复制。普通单击、滚动或「恢复阅读增强」可恢复。\n\n「节能模式」默认关闭。鼠标操作结束约 0.3 秒后截图；开启键盘感知后，输入时隐藏强调，松键并停止输入约 0.8 秒后截图，截图和 OCR 耗时另计。静止时停止捕获和 OCR。\n\n跨应用键盘感知需在菜单「键盘感知」中授权 macOS 输入监控，授权后可能需要重启应用。仅使用按键编号、按下/松开和修饰键状态，不读取输入字符串、不记录键盘历史。节能模式会避开浮动候选窗和菜单；自定义嵌入式候选框可能无法识别。\n\n屏幕录制权限仍然必需。所有 OCR 在本机进行，不保存截图、不上传文字。网页自动更新或安全输入期间可能需要「刷新当前画面」。"
        alert.addButton(withTitle:"知道了"); alert.addButton(withTitle:"屏幕录制设置")
        if alert.runModal() == .alertSecondButtonReturn { openPermissionSettings() }
    }
    private func showPermissionHelp() {
        let alert=NSAlert(); alert.messageText="需要屏幕录制权限"
        alert.informativeText="请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许 Anchor Overlay 读取屏幕。只捕获画面，不录制音频。授予后可能需要退出并重新打开应用。"
        alert.addButton(withTitle:"打开系统设置"); alert.addButton(withTitle:"稍后")
        if alert.runModal() == .alertFirstButtonReturn { openPermissionSettings() }
    }
    private func openPermissionSettings() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}
