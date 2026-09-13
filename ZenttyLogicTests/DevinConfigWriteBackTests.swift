import Foundation
import XCTest
@testable import Zentty

final class DevinConfigWriteBackTests: XCTestCase {
    func test_merged_propagates_leaf_change_and_preserves_unrelated_target_edits() {
        let base: [String: Any] = ["theme_mode": "dark"]
        let current: [String: Any] = ["theme_mode": "dark", "attribution": false]
        // Externally changed while the session ran — untouched by the diff.
        let target: [String: Any] = ["theme_mode": "light"]

        let result = DevinConfigWriteBack.merged(base: base, current: current, target: target)

        let merged = try? XCTUnwrap(result)
        XCTAssertEqual(merged?["attribution"] as? Bool, false)
        XCTAssertEqual(merged?["theme_mode"] as? String, "light")
    }

    func test_merged_changes_only_the_differing_nested_leaf() {
        let base: [String: Any] = ["agent": ["model": "swe-1", "preferred_family_models": ["a", "b"]]]
        let current: [String: Any] = ["agent": ["model": "swe-2", "preferred_family_models": ["a", "b"]]]
        let target: [String: Any] = [
            "agent": ["model": "swe-1", "preferred_family_models": ["x"]],
            "other": true,
        ]

        let result = try? XCTUnwrap(DevinConfigWriteBack.merged(base: base, current: current, target: target))
        let agent = try? XCTUnwrap(result?["agent"] as? [String: Any])
        XCTAssertEqual(agent?["model"] as? String, "swe-2")
        XCTAssertEqual(agent?["preferred_family_models"] as? [String], ["x"])
        XCTAssertEqual(result?["other"] as? Bool, true)
    }

    func test_merged_ignores_top_level_hooks() throws {
        let base: [String: Any] = [
            "hooks": ["SessionStart": [["matcher": "", "hooks": [["command": "old"]]]]],
            "attribution": true,
        ]
        let current: [String: Any] = [
            "hooks": ["SessionStart": [["matcher": "", "hooks": [["command": "rewritten-by-devin"]]]]],
            "attribution": false,
        ]
        let targetHooks: [String: Any] = ["SessionStart": [["matcher": "", "hooks": [["command": "target-hooks"]]]]]
        let target: [String: Any] = ["hooks": targetHooks, "attribution": true]

        let result = try XCTUnwrap(DevinConfigWriteBack.merged(base: base, current: current, target: target))
        XCTAssertEqual(result["attribution"] as? Bool, false)

        let resultHooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: resultHooks, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: targetHooks, options: [.sortedKeys])
        )
    }

    func test_merged_removes_key_deleted_from_overlay() {
        let base: [String: Any] = ["attribution": true, "keep": 1]
        let current: [String: Any] = ["keep": 1]
        let target: [String: Any] = ["attribution": true, "keep": 1, "external": "yes"]

        let result = try? XCTUnwrap(DevinConfigWriteBack.merged(base: base, current: current, target: target))
        XCTAssertNil(result?["attribution"])
        XCTAssertEqual(result?["keep"] as? Int, 1)
        XCTAssertEqual(result?["external"] as? String, "yes")
    }

    func test_merged_returns_nil_when_base_and_current_are_identical() {
        let base: [String: Any] = ["a": 1, "nested": ["b": [1, 2]], "hooks": ["x": 1]]
        let current: [String: Any] = ["nested": ["b": [1, 2]], "a": 1, "hooks": ["x": 1]]
        let target: [String: Any] = ["a": 2]

        XCTAssertNil(DevinConfigWriteBack.merged(base: base, current: current, target: target))
    }

    func test_sync_writes_diff_to_jsonc_source_and_refreshes_snapshot() throws {
        let directory = try makeTemporaryDirectory(named: "devin-writeback-sync")
        let overlayURL = directory.appendingPathComponent("config.json")
        let snapshotURL = directory.appendingPathComponent(DevinConfigWriteBack.snapshotFileName)
        let sourceURL = directory.appendingPathComponent("real-config.json")

        try """
        {
          // user comment — dropped on first write-back
          "theme_mode": "dark",
          "devin": {"org_id": "org-123",},
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let snapshot: [String: Any] = ["theme_mode": "dark", "devin": ["org_id": "org-123"], "hooks": ["h": 1]]
        let overlay: [String: Any] = [
            "theme_mode": "dark",
            "devin": ["org_id": "org-123"],
            "hooks": ["h": 2],
            "attribution": false,
        ]
        try writeJSON(snapshot, to: snapshotURL)
        try writeJSON(overlay, to: overlayURL)

        XCTAssertTrue(try DevinConfigWriteBack.sync(
            overlayURL: overlayURL,
            snapshotURL: snapshotURL,
            sourceURL: sourceURL
        ))

        let source = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any]
        )
        XCTAssertEqual(source["attribution"] as? Bool, false)
        XCTAssertEqual(source["theme_mode"] as? String, "dark")
        XCTAssertEqual((source["devin"] as? [String: Any])?["org_id"] as? String, "org-123")
        // `hooks` is owned by the overlay and never written back.
        XCTAssertNil(source["hooks"])

        XCTAssertEqual(try Data(contentsOf: snapshotURL), try Data(contentsOf: overlayURL))

        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let sourceBytes = try Data(contentsOf: sourceURL)
        XCTAssertFalse(try DevinConfigWriteBack.sync(
            overlayURL: overlayURL,
            snapshotURL: snapshotURL,
            sourceURL: sourceURL
        ))
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date,
            sourceAttributes[.modificationDate] as? Date
        )
    }

    func test_sync_creates_missing_source_containing_only_the_diff() throws {
        let directory = try makeTemporaryDirectory(named: "devin-writeback-missing-source")
        let overlayURL = directory.appendingPathComponent("config.json")
        let snapshotURL = directory.appendingPathComponent(DevinConfigWriteBack.snapshotFileName)
        let sourceURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("real-config.json")

        try writeJSON(["theme_mode": "dark"], to: snapshotURL)
        try writeJSON(["theme_mode": "dark", "attribution": false], to: overlayURL)

        XCTAssertTrue(try DevinConfigWriteBack.sync(
            overlayURL: overlayURL,
            snapshotURL: snapshotURL,
            sourceURL: sourceURL
        ))

        let source = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any]
        )
        XCTAssertEqual(source.count, 1)
        XCTAssertEqual(source["attribution"] as? Bool, false)
    }

    func test_sync_returns_false_without_writes_when_snapshot_is_missing() throws {
        let directory = try makeTemporaryDirectory(named: "devin-writeback-no-snapshot")
        let overlayURL = directory.appendingPathComponent("config.json")
        let snapshotURL = directory.appendingPathComponent(DevinConfigWriteBack.snapshotFileName)
        let sourceURL = directory.appendingPathComponent("real-config.json")
        try writeJSON(["attribution": false], to: overlayURL)

        XCTAssertFalse(try DevinConfigWriteBack.sync(
            overlayURL: overlayURL,
            snapshotURL: snapshotURL,
            sourceURL: sourceURL
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func test_syncIfNeeded_noops_without_environment_keys() throws {
        let directory = try makeTemporaryDirectory(named: "devin-writeback-noenv")
        DevinConfigWriteBack.syncIfNeeded(environment: [:])
        DevinConfigWriteBack.syncIfNeeded(environment: [
            DevinConfigWriteBack.overlayEnvironmentKey: "",
            DevinConfigWriteBack.sourceEnvironmentKey: " ",
        ])
        // Keys present but pointing at nothing must not create the source.
        DevinConfigWriteBack.syncIfNeeded(environment: [
            DevinConfigWriteBack.overlayEnvironmentKey: directory.appendingPathComponent("config.json").path,
            DevinConfigWriteBack.sourceEnvironmentKey: directory.appendingPathComponent("real-config.json").path,
        ])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }
}
