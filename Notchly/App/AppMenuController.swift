//
//  AppMenuController.swift
//  Notchly
//
//  Created by n0xbyte on 03.05.2026.
//

import AppKit

@MainActor
final class AppMenuController: NSObject {
    private var statusItem: NSStatusItem?
    private let settingsWindow: SettingsWindow
    private let agentEventManager: AgentEventManager

    init(
        settingsWindow: SettingsWindow,
        agentEventManager: AgentEventManager
    ) {
        self.settingsWindow = settingsWindow
        self.agentEventManager = agentEventManager
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true
            button.image = image
        }

        item.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        let versionItem = NSMenuItem(
            title: "Version \(appVersion)",
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(versionItem)
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }


    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

}
