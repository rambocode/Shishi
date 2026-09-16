import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class SettingsPaneTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testGeneralControlsPersistAndKeepSettingsWindowFontStable() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let domain = "Shishi.SettingsPaneTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: dir) }
            let preferences = GeneralPreferences(defaults: defaults)
            let store = TaskStore(fileURL: dir.appendingPathComponent("library.json"), preferences: preferences)
            let pane = GeneralSettingsPane(store: store, preferences: preferences)
            let controls = descendants(pane.view)
            let archive = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "将完成的项移到日志簿" })
            archive.selectItem(withTitle: "手动")
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(archive.action), to: archive.target, from: archive))
            XCTAssertEqual(preferences.archiveTiming, .manually)
            let dock = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Dock 计数" })
            dock.selectItem(at: DockCountMode.allCases.firstIndex(of: .inbox)!)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(dock.action), to: dock.target, from: dock))
            XCTAssertEqual(preferences.dockCount, .inbox)
            let slider = try XCTUnwrap(controls.compactMap { $0 as? NSSlider }.first)
            slider.integerValue = 20
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
            XCTAssertEqual(preferences.textSize, 20)
            let reset = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "默认" })
            reset.performClick(nil); XCTAssertEqual(preferences.textSize, 14)
            let grouping = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title.contains("分组") })
            grouping.performClick(nil); XCTAssertFalse(preferences.groupToday)
            let reloaded = GeneralPreferences(defaults: defaults)
            XCTAssertEqual(reloaded.archiveTiming, .manually)
            XCTAssertEqual(reloaded.dockCount, .inbox)
            XCTAssertFalse(reloaded.groupToday)
        }
    }

    func testArchiveButtonMovesPendingCompletionAndUndoRestoresIt() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let domain = "Shishi.SettingsArchiveTests." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: dir) }
            let preferences = GeneralPreferences(defaults: defaults); preferences.archiveTiming = .manually
            let store = TaskStore(fileURL: dir.appendingPathComponent("library.json"), preferences: preferences)
            let task = Todo(title: "设置归档验证")
            XCTAssertTrue(store.save(task)); store.toggle(task.id)
            XCTAssertEqual(store.items(for: .inbox).count, 1)
            let pane = GeneralSettingsPane(store: store, preferences: preferences)
            let button = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSButton }.first { $0.title == "立即归档已完成项" })
            button.performClick(nil)
            XCTAssertTrue(store.items(for: .inbox).isEmpty)
            XCTAssertEqual(store.items(for: .logbook).map(\.id), [task.id])
            store.undo(); XCTAssertEqual(store.items(for: .inbox).map(\.id), [task.id])
        }
    }

    func testCloudPageDoesNotPretendToHaveAccountOrSyncControls() async {
        await MainActor.run {
            _ = NSApplication.shared
            let page = CloudSettingsPane(); let views = descendants(page.view)
            XCTAssertTrue(views.compactMap { $0 as? NSButton }.isEmpty)
            XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("不能登录或复用 Things Cloud") })
        }
    }
}
