//
//  AppsPIPApp.swift
//  AppsPIP
//
//  Created by H on 20/05/2026.
//

import SwiftUI
import AppKit

@main
struct AppsPIPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = AppCoordinator()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(coordinator: coordinator)
    }
}

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var pendingDeactivateWorkItem: DispatchWorkItem?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pip", accessibilityDescription: "AppsPIP")
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        popover.animates = false
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ContentView(closeMenuBarExtra: { [weak self] in
                self?.closePopover()
            })
            .environmentObject(coordinator)
        )
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(relativeTo: sender)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        pendingDeactivateWorkItem?.cancel()
        pendingDeactivateWorkItem = nil
        coordinator.refreshPermissions()
        button.highlight(true)
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        popover.close()
        statusItem.button?.highlight(false)
        pendingDeactivateWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            NSApp.deactivate()
        }
        pendingDeactivateWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
    }
}
