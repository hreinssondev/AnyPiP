//
//  ContentView.swift
//  AppsPIP
//
//  Created by H on 20/05/2026.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var permissionsExpanded = false
    @State private var autoPiPQuery = ""
    @State private var highlightedAutoPiPAppID: String?
    @FocusState private var isAutoPiPSearchFocused: Bool
    var closeMenuBarExtra: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                hotkeyCard
                hoverSwitchCard
                autoPiPAppsCard
                if shouldShowPermissionsCard {
                    permissionsCard
                }
                footer
            }
            .padding(12)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(InitialPopoverFocusView())
        .background(EscapeCloseView(closeMenuBarExtra: closeMenuBarExtra))
        .onAppear {
            coordinator.refreshPermissions()
            isAutoPiPSearchFocused = false
        }
        .onChange(of: shouldShowPermissionsCard) { _, shouldShow in
            if !shouldShow {
                permissionsExpanded = false
            }
        }
    }

    private var hotkeyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            shortcutRow(
                title: "Start / Stop PiP",
                mode: primaryShortcutModeBinding,
                text: primaryShortcutTextBinding,
                save: savePrimaryShortcut
            )
            shortcutRow(
                title: "Restore or Exit Last PiP",
                mode: doubleTapShortcutModeBinding,
                text: doubleTapShortcutTextBinding,
                save: saveDoubleTapShortcut
            )
        }
        .padding(12)
        .background(cardBackground)
    }

    private var hoverSwitchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: hoverSwitchBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hover to switch")
                        .font(.system(size: 13, weight: .semibold))
                    Text("When enabled, moving the pointer into the PiP window switches modes instantly.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func shortcutRow(
        title: String,
        mode: Binding<ShortcutTriggerMode>,
        text: Binding<String>,
        save: @escaping () -> Void
    ) -> some View {
        let recordsModifiers = mode.wrappedValue == .modifierKey

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.top, 6)
                .padding(.bottom, 0)

            Picker("", selection: mode) {
                ForEach(ShortcutTriggerMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                HotkeyField(
                    text: text,
                    onBeginRecording: { coordinator.setHotKeyRecordingActive(true) },
                    onEndRecording: { coordinator.setHotKeyRecordingActive(false) },
                    onSubmit: save,
                    allowsEscapeKey: true,
                    recordsModifiers: recordsModifiers
                )
                .frame(height: 29)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.vertical, 1)
            }
        }
    }

    private var permissionsCard: some View {
        DisclosureGroup(isExpanded: $permissionsExpanded) {
            VStack(spacing: 0) {
                PermissionRow(
                    title: "Screen Recording",
                    isGranted: coordinator.isScreenRecordingTrusted,
                    action: coordinator.openScreenRecordingSettings
                )
                Divider().padding(.leading, 32)
                PermissionRow(
                    title: "Accessibility",
                    isGranted: coordinator.isAccessibilityTrusted,
                    action: coordinator.openAccessibilitySettings
                )
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(permissionColor)
                    .frame(width: 24, height: 24)
                    .background(permissionColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(permissionSummary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 5) {
                    permissionDot(coordinator.isScreenRecordingTrusted)
                    permissionDot(coordinator.isAccessibilityTrusted)
                }
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var autoPiPAppsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
                CardHeader(icon: "square.stack.3d.up", title: "Auto PiP Apps", detail: "Automatically goes into PiP when unfocused")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search apps", text: $autoPiPQuery)
                        .textFieldStyle(.plain)
                        .focused($isAutoPiPSearchFocused)
                        .background(
                            AutoPiPSearchKeyHandler(
                                isActive: isAutoPiPSearchFocused && shouldShowAutoPiPSuggestions,
                                onMoveSelection: moveAutoPiPHighlight,
                                onCommitSelection: commitHighlightedAutoPiPApp
                            )
                        )
                        .onTapGesture {
                            if coordinator.availableAutoPiPApps.isEmpty && !coordinator.isRefreshingAutoPiPApps {
                                coordinator.refreshAvailableAutoPiPApps()
                            }
                        }

                    if coordinator.isRefreshingAutoPiPApps {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )

                if shouldShowAutoPiPSuggestions {
                    autoPiPAppSuggestions
                }
            }

            if !coordinator.autoPiPAppSelections.isEmpty {
                selectedAutoPiPAppsList
            }
        }
        .padding(14)
        .background(cardBackground)
        .onAppear {
            if coordinator.availableAutoPiPApps.isEmpty && !coordinator.isRefreshingAutoPiPApps {
                coordinator.refreshAvailableAutoPiPApps()
            }
        }
        .onChange(of: isAutoPiPSearchFocused) { _, isFocused in
            if isFocused,
               coordinator.availableAutoPiPApps.isEmpty,
               !coordinator.isRefreshingAutoPiPApps {
                coordinator.refreshAvailableAutoPiPApps()
            }
        }
        .onChange(of: autoPiPQuery) { _, newValue in
            let normalizedQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedQuery.isEmpty,
               coordinator.availableAutoPiPApps.isEmpty,
               !coordinator.isRefreshingAutoPiPApps {
                coordinator.refreshAvailableAutoPiPApps()
            }
            highlightedAutoPiPAppID = autoPiPDropdownApps.first?.id
        }
    }

    @ViewBuilder
    private var selectedAutoPiPAppsList: some View {
        if coordinator.autoPiPAppSelections.count > 6 {
            ScrollView {
                selectedAutoPiPAppsRows
            }
            .frame(height: selectedAutoPiPAppsListMaxHeight)
        } else {
            selectedAutoPiPAppsRows
        }
    }

    private var selectedAutoPiPAppsRows: some View {
        VStack(alignment: .leading, spacing: selectedAutoPiPAppsRowSpacing) {
            ForEach(coordinator.autoPiPAppSelections) { app in
                selectedAutoPiPAppRow(app)
            }
        }
    }

    private func selectedAutoPiPAppRow(_ app: AutoPiPAppSelection) -> some View {
        HStack(spacing: 10) {
            AppIconView(bundleIdentifier: app.bundleIdentifier)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(app.bundleIdentifier)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                coordinator.removeAutoPiPAppSelection(bundleIdentifier: app.bundleIdentifier)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                coordinator.refreshPermissions()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                coordinator.quitApp()
            } label: {
                Label("Quit", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }

    private var permissionSummary: String {
        if areAllPermissionsGranted {
            return "All access granted"
        }
        return "Action required"
    }

    private var permissionColor: Color {
        areAllPermissionsGranted ? Color(nsColor: .systemGreen) : .orange
    }

    private var shouldShowPermissionsCard: Bool {
        !areAllPermissionsGranted
    }

    private var areAllPermissionsGranted: Bool {
        coordinator.isScreenRecordingTrusted && coordinator.isAccessibilityTrusted
    }

    private var selectedAutoPiPAppsListMaxHeight: CGFloat {
        selectedAutoPiPAppsRowHeight * 6 + selectedAutoPiPAppsRowSpacing * 5
    }

    private var selectedAutoPiPAppsRowHeight: CGFloat { 45 }

    private var selectedAutoPiPAppsRowSpacing: CGFloat { 8 }

    private func savePrimaryShortcut() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        coordinator.setHotKeyRecordingActive(false)
        DispatchQueue.main.async {
            self.coordinator.applyPrimaryShortcutFromInput()
        }
    }

    private func saveDoubleTapShortcut() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        coordinator.setHotKeyRecordingActive(false)
        DispatchQueue.main.async {
            self.coordinator.applyDoubleTapActionShortcutFromInput()
        }
    }

    private var primaryShortcutModeBinding: Binding<ShortcutTriggerMode> {
        Binding(
            get: { coordinator.primaryShortcutMode },
            set: { coordinator.setPrimaryShortcutMode($0) }
        )
    }

    private var doubleTapShortcutModeBinding: Binding<ShortcutTriggerMode> {
        Binding(
            get: { coordinator.doubleTapShortcutMode },
            set: { coordinator.setDoubleTapShortcutMode($0) }
        )
    }

    private var primaryShortcutTextBinding: Binding<String> {
        Binding(
            get: {
                switch coordinator.primaryShortcutMode {
                case .modifierKey:
                    return coordinator.hotkeyInput
                case .doublePress:
                    return coordinator.primaryDoubleTapKeyInput
                case .singleKey:
                    return coordinator.primarySingleKeyInput
                }
            },
            set: { newValue in
                switch coordinator.primaryShortcutMode {
                case .modifierKey:
                    coordinator.hotkeyInput = newValue
                case .doublePress:
                    coordinator.primaryDoubleTapKeyInput = newValue
                case .singleKey:
                    coordinator.primarySingleKeyInput = newValue
                }
            }
        )
    }

    private var doubleTapShortcutTextBinding: Binding<String> {
        Binding(
            get: {
                switch coordinator.doubleTapShortcutMode {
                case .modifierKey:
                    return coordinator.doubleTapHotkeyInput
                case .doublePress:
                    return coordinator.doubleTapKeyInput
                case .singleKey:
                    return coordinator.doubleTapSingleKeyInput
                }
            },
            set: { newValue in
                switch coordinator.doubleTapShortcutMode {
                case .modifierKey:
                    coordinator.doubleTapHotkeyInput = newValue
                case .doublePress:
                    coordinator.doubleTapKeyInput = newValue
                case .singleKey:
                    coordinator.doubleTapSingleKeyInput = newValue
                }
            }
        )
    }

    private var hoverSwitchBinding: Binding<Bool> {
        Binding(
            get: { coordinator.hoverSwitchEnabled },
            set: { coordinator.setHoverSwitchEnabled($0) }
        )
    }

    private var autoPiPDropdownApps: [AutoPiPAppSelection] {
        let selectedBundleIdentifiers = Set(coordinator.autoPiPAppSelections.map(\.bundleIdentifier))
        let availableApps = coordinator.availableAutoPiPApps.filter { !selectedBundleIdentifiers.contains($0.bundleIdentifier) }
        let normalizedQuery = normalizedAutoPiPQuery
        guard !normalizedQuery.isEmpty else { return [] }

        return availableApps.filter { app in
            app.displayName.localizedCaseInsensitiveContains(normalizedQuery)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(normalizedQuery)
        }
        .prefix(8)
        .map { $0 }
    }

    private var autoPiPAppSuggestions: some View {
        Group {
            if autoPiPDropdownApps.isEmpty {
                Text(autoPiPEmptyStateText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(autoPiPDropdownApps) { app in
                            Button {
                                addAutoPiPAppSelection(app)
                            } label: {
                                HStack(spacing: 10) {
                                    AppIconView(bundleIdentifier: app.bundleIdentifier)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.displayName)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(app.bundleIdentifier)
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(app.id == highlightedAutoPiPAppID ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovering in
                                if isHovering {
                                    highlightedAutoPiPAppID = app.id
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(height: 176)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private var normalizedAutoPiPQuery: String {
        autoPiPQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowAutoPiPSuggestions: Bool {
        !normalizedAutoPiPQuery.isEmpty
    }

    private var autoPiPEmptyStateText: String {
        if coordinator.isRefreshingAutoPiPApps {
            return "Loading apps..."
        }

        if coordinator.availableAutoPiPApps.isEmpty {
            return "No apps found yet."
        }

        if autoPiPQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "All discovered apps are already selected."
        }

        return "No apps match your search."
    }

    private func addAutoPiPAppSelection(_ app: AutoPiPAppSelection) {
        coordinator.addAutoPiPAppSelection(app)
        autoPiPQuery = ""
        highlightedAutoPiPAppID = nil
        isAutoPiPSearchFocused = true
    }

    private func moveAutoPiPHighlight(_ offset: Int) {
        let apps = autoPiPDropdownApps
        guard !apps.isEmpty else { return }

        let currentIndex = highlightedAutoPiPAppID.flatMap { id in
            apps.firstIndex { $0.id == id }
        }
        let nextIndex: Int

        if let currentIndex {
            nextIndex = (currentIndex + offset + apps.count) % apps.count
        } else {
            nextIndex = offset > 0 ? 0 : apps.count - 1
        }

        highlightedAutoPiPAppID = apps[nextIndex].id
    }

    private func commitHighlightedAutoPiPApp() {
        let apps = autoPiPDropdownApps
        guard !apps.isEmpty else { return }

        let selectedApp = highlightedAutoPiPAppID.flatMap { id in
            apps.first { $0.id == id }
        } ?? apps[0]

        addAutoPiPAppSelection(selectedApp)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private func permissionDot(_ isGranted: Bool) -> some View {
        Circle()
            .fill(isGranted ? Color(nsColor: .systemGreen) : Color.orange)
            .frame(width: 7, height: 7)
    }

    private struct InitialPopoverFocusView: NSViewRepresentable {
        func makeNSView(context: Context) -> FocusCatcherView {
            FocusCatcherView()
        }

        func updateNSView(_ nsView: FocusCatcherView, context: Context) {
            nsView.focusWhenReady()
        }

        final class FocusCatcherView: NSView {
            override var acceptsFirstResponder: Bool { true }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                focusWhenReady()
            }

            func focusWhenReady() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    window.makeFirstResponder(self)
                }
            }
        }
    }

    private struct EscapeCloseView: NSViewRepresentable {
        var closeMenuBarExtra: (() -> Void)?

        func makeNSView(context: Context) -> EscapeCatcherView {
            let view = EscapeCatcherView()
            view.closeMenuBarExtra = closeMenuBarExtra
            view.installMonitor()
            return view
        }

        func updateNSView(_ nsView: EscapeCatcherView, context: Context) {
            nsView.closeMenuBarExtra = closeMenuBarExtra
        }

        final class EscapeCatcherView: NSView {
            var closeMenuBarExtra: (() -> Void)?
            private var monitor: Any?

            deinit {
                removeMonitor()
            }

            func installMonitor() {
                removeMonitor()
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self,
                          event.keyCode == 53,
                          let window = self.window,
                          window.isVisible else {
                        return event
                    }
                    if window.firstResponder is HotkeyField.HotkeyRecorderView {
                        return event
                    }
                    if window.firstResponder is NSTextView {
                        return event
                    }
                    self.close()
                    return nil
                }
            }

            func removeMonitor() {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }

            private func close() {
                window?.makeFirstResponder(nil)
                closeMenuBarExtra?()
            }
        }
    }

    private struct AutoPiPSearchKeyHandler: NSViewRepresentable {
        var isActive: Bool
        var onMoveSelection: (Int) -> Void
        var onCommitSelection: () -> Void

        func makeNSView(context: Context) -> KeyHandlerView {
            let view = KeyHandlerView()
            view.isActive = isActive
            view.onMoveSelection = onMoveSelection
            view.onCommitSelection = onCommitSelection
            view.installMonitor()
            return view
        }

        func updateNSView(_ nsView: KeyHandlerView, context: Context) {
            nsView.isActive = isActive
            nsView.onMoveSelection = onMoveSelection
            nsView.onCommitSelection = onCommitSelection
        }

        final class KeyHandlerView: NSView {
            var isActive = false
            var onMoveSelection: ((Int) -> Void)?
            var onCommitSelection: (() -> Void)?
            private var monitor: Any?

            deinit {
                removeMonitor()
            }

            func installMonitor() {
                removeMonitor()
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self,
                          self.isActive,
                          self.window?.firstResponder is NSTextView else {
                        return event
                    }

                    switch event.keyCode {
                    case 125:
                        self.onMoveSelection?(1)
                        return nil
                    case 126:
                        self.onMoveSelection?(-1)
                        return nil
                    case 36, 76:
                        self.onCommitSelection?()
                        return nil
                    default:
                        return event
                    }
                }
            }

            private func removeMonitor() {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }
        }
    }

    private struct HotkeyField: NSViewRepresentable {
        @Binding var text: String
        var onBeginRecording: () -> Void
        var onEndRecording: () -> Void
        var onSubmit: () -> Void
        var allowsEscapeKey = false
        var recordsModifiers = true

        func makeNSView(context: Context) -> HotkeyRecorderView {
            let view = HotkeyRecorderView()
            view.value = text
            view.onChange = { newValue in
                self.text = newValue
            }
            view.onBeginRecording = onBeginRecording
            view.onEndRecording = onEndRecording
            view.onSubmit = onSubmit
            view.allowsEscapeKey = allowsEscapeKey
            view.recordsModifiers = recordsModifiers
            return view
        }

        func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
            nsView.value = text
            nsView.allowsEscapeKey = allowsEscapeKey
            nsView.recordsModifiers = recordsModifiers
        }

        final class HotkeyRecorderView: NSView {
            var value = "" {
                didSet { label.stringValue = value }
            }
            var onChange: ((String) -> Void)?
            var onBeginRecording: (() -> Void)?
            var onEndRecording: (() -> Void)?
            var onSubmit: (() -> Void)?
            var allowsEscapeKey = false
            var recordsModifiers = true

            private let label = NSTextField(labelWithString: "")
            private var monitor: Any?
            private var isRecording = false {
                didSet { updateAppearance() }
            }

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer?.cornerRadius = 11
                layer?.masksToBounds = true
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
                label.lineBreakMode = .byTruncatingTail
                addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                    label.centerYAnchor.constraint(equalTo: centerYAnchor)
                ])
                value = ""
                updateAppearance()
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            deinit {
                removeMonitor()
            }

            override var acceptsFirstResponder: Bool { true }

            override func hitTest(_ point: NSPoint) -> NSView? {
                self
            }

            override func mouseDown(with event: NSEvent) {
                window?.makeFirstResponder(self)
            }

            override func becomeFirstResponder() -> Bool {
                isRecording = true
                installMonitor()
                onBeginRecording?()
                return true
            }

            override func resignFirstResponder() -> Bool {
                isRecording = false
                removeMonitor()
                label.stringValue = value
                onEndRecording?()
                return true
            }

            override func keyDown(with event: NSEvent) {
                guard isRecording else { return }
                handle(event)
            }

            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                guard isRecording else { return false }
                handle(event)
                return true
            }

            override func flagsChanged(with event: NSEvent) {
                guard isRecording else { return }
                guard recordsModifiers else { return }
                let display = displayString(modifiers: normalizedFlags(event.modifierFlags))
                if !display.isEmpty {
                    label.stringValue = display
                }
            }

            private func installMonitor() {
                removeMonitor()
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    guard let self, self.isRecording, self.window?.firstResponder === self else { return event }
                    if event.type == .keyDown {
                        self.handle(event)
                    } else {
                        self.flagsChanged(with: event)
                    }
                    return nil
                }
            }

            private func removeMonitor() {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }

            private func handle(_ event: NSEvent) {
                guard isRecording else { return }
                if event.keyCode == 53 && !allowsEscapeKey {
                    cancelRecordingAndClear()
                    return
                }
                if event.keyCode == 36 {
                    stopRecordingAndSubmit()
                    return
                }
                if event.keyCode == 51 {
                    value = ""
                    onChange?("")
                    return
                }
                let key = keySymbolFor(event: event)
                guard !key.isEmpty else { return }
                let display = (recordsModifiers ? displayString(modifiers: normalizedFlags(event.modifierFlags)) : "") + key
                value = display
                onChange?(display)
            }

            private func stopRecordingAndSubmit() {
                removeMonitor()
                isRecording = false
                onEndRecording?()
                window?.makeFirstResponder(nil)
                DispatchQueue.main.async { [onSubmit] in
                    onSubmit?()
                }
            }

            private func cancelRecordingAndClear() {
                value = ""
                onChange?("")
                window?.makeFirstResponder(nil)
            }

            private func updateAppearance() {
                label.textColor = isRecording ? NSColor.controlAccentColor : NSColor.labelColor
                layer?.borderWidth = isRecording ? 1.5 : 0
                layer?.borderColor = isRecording ? NSColor.controlAccentColor.cgColor : nil
            }

            private func normalizedFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
                var result: NSEvent.ModifierFlags = []
                if flags.contains(.command) { result.insert(.command) }
                if flags.contains(.option) { result.insert(.option) }
                if flags.contains(.shift) { result.insert(.shift) }
                if flags.contains(.control) { result.insert(.control) }
                return result
            }

            private func displayString(modifiers: NSEvent.ModifierFlags) -> String {
                var parts: [String] = []
                if modifiers.contains(.command) { parts.append("⌘") }
                if modifiers.contains(.option) { parts.append("⌥") }
                if modifiers.contains(.shift) { parts.append("⇧") }
                if modifiers.contains(.control) { parts.append("⌃") }
                return parts.joined()
            }

            private func keySymbolFor(event: NSEvent) -> String {
                guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return "" }
                switch event.keyCode {
                case 49: return "Space"
                case 53: return "⎋"
                default:
                    return chars.uppercased()
                }
            }
        }
    }

}

private struct CardHeader: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(isGranted ? Color(nsColor: .systemGreen) : .orange)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if isGranted {
                Text("Allowed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
            } else {
                Button("Open Settings") { action() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct AppIconView: View {
    let bundleIdentifier: String

    var body: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var appIcon: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }
}

#Preview {
    ContentView()
        .environmentObject(AppCoordinator())
}
