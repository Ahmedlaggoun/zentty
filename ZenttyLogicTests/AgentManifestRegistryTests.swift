import Foundation
import XCTest
@testable import Zentty

final class AgentManifestRegistryTests: XCTestCase {
    func test_load_reads_manifests_from_manifest_dirs_environment() throws {
        let directory = try makeTemporaryDirectory(named: "agent-manifests")
        try writeManifest(
            id: "kilo",
            displayName: "Kilo Code",
            binaries: ["kilo"],
            family: "opencode-plugin",
            extraFields: """
              "opencodePlugin": {
                "envPrefix": "KILO",
                "configDirName": "kilo",
                "siblingBinary": ".kilo"
              }
            """,
            to: directory
        )
        let homeDirectory = try makeTemporaryDirectory(named: "agent-manifests-home")
        let bundleRoot = try makeTemporaryDirectory(named: "agent-manifests-bundle")

        let registry = AgentManifestRegistry.load(
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            environment: ["ZENTTY_AGENT_MANIFEST_DIRS": directory.path],
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(registry.manifests.map(\.id), ["kilo"])
        XCTAssertEqual(registry.manifest(id: "kilo")?.displayName, "Kilo Code")
        XCTAssertEqual(registry.manifest(id: "kilo")?.opencodePlugin?.envPrefix, "KILO")
    }

    func test_load_reads_user_config_agents_directory() throws {
        let homeDirectory = try makeTemporaryDirectory(named: "agent-manifests-home")
        let userAgents = homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("zentty", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        try FileManager.default.createDirectory(at: userAgents, withIntermediateDirectories: true)
        try writeManifest(
            id: "kilo",
            displayName: "Kilo Code",
            binaries: ["kilo"],
            family: "canonical",
            to: userAgents
        )
        let bundleRoot = try makeTemporaryDirectory(named: "agent-manifests-bundle")

        let registry = AgentManifestRegistry.load(
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            environment: [:],
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(registry.manifest(id: "kilo")?.displayName, "Kilo Code")
    }

    func test_load_later_manifest_dir_overrides_earlier_by_id() throws {
        let firstDirectory = try makeTemporaryDirectory(named: "agent-manifests-first")
        let secondDirectory = try makeTemporaryDirectory(named: "agent-manifests-second")
        try writeManifest(
            id: "kilo",
            displayName: "Kilo Code",
            binaries: ["kilo"],
            family: "canonical",
            to: firstDirectory
        )
        try writeManifest(
            id: "kilo",
            displayName: "Kilo Code Pro",
            binaries: ["kilo", "kilo-pro"],
            family: "canonical",
            to: secondDirectory
        )
        let homeDirectory = try makeTemporaryDirectory(named: "agent-manifests-home")
        let bundleRoot = try makeTemporaryDirectory(named: "agent-manifests-bundle")

        let registry = AgentManifestRegistry.load(
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            environment: [
                "ZENTTY_AGENT_MANIFEST_DIRS": "\(firstDirectory.path):\(secondDirectory.path)",
            ],
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(registry.manifests.count, 1)
        XCTAssertEqual(registry.manifest(id: "kilo")?.displayName, "Kilo Code Pro")
        XCTAssertEqual(registry.manifest(forBinary: "kilo-pro")?.id, "kilo")
    }

    func test_init_skips_invalid_id() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "Kilo", displayName: "Kilo Code"),
            makeManifest(id: "-kilo", displayName: "Other Agent"),
            makeManifest(id: "kilo", displayName: "Kilo Code", family: .canonical),
        ])
        XCTAssertEqual(registry.manifests.map(\.id), ["kilo"])
        XCTAssertEqual(registry.manifests.first?.displayName, "Kilo Code")
    }

    func test_init_skips_builtin_id_collision() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "claude", displayName: "Not Claude"),
            makeManifest(id: "small-harness", displayName: "Other"),
        ])
        XCTAssertTrue(registry.manifests.isEmpty)
    }

    func test_init_skips_builtin_display_name_collision() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "OpenCode"),
        ])
        XCTAssertTrue(registry.manifests.isEmpty)
    }

    func test_init_skips_duplicate_display_name() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "Kilo Code"),
            makeManifest(id: "kilo2", displayName: "Kilo Code"),
        ])
        XCTAssertEqual(registry.manifests.map(\.id), ["kilo"])
    }

    func test_init_skips_empty_binaries() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "Kilo Code", binaries: []),
        ])
        XCTAssertTrue(registry.manifests.isEmpty)
    }

    func test_init_skips_unsupported_schema_version() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "Kilo Code", schemaVersion: 2),
            makeManifest(id: "kilo", displayName: "Kilo Code", schemaVersion: 0),
        ])
        XCTAssertTrue(registry.manifests.isEmpty)
    }

    func test_init_skips_opencode_plugin_family_without_options() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "Kilo Code", family: .opencodePlugin, opencodePlugin: nil),
        ])
        XCTAssertTrue(registry.manifests.isEmpty)
    }

    func test_load_skips_malformed_json_file_and_keeps_valid() throws {
        let directory = try makeTemporaryDirectory(named: "agent-manifests")
        try "{ not json".write(
            to: directory.appendingPathComponent("bad.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try writeManifest(
            id: "kilo",
            displayName: "Kilo Code",
            binaries: ["kilo"],
            family: "canonical",
            to: directory
        )
        let homeDirectory = try makeTemporaryDirectory(named: "agent-manifests-home")
        let bundleRoot = try makeTemporaryDirectory(named: "agent-manifests-bundle")

        let registry = AgentManifestRegistry.load(
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            environment: ["ZENTTY_AGENT_MANIFEST_DIRS": directory.path],
            homeDirectory: homeDirectory
        )

        XCTAssertEqual(registry.manifests.map(\.id), ["kilo"])
    }

    func test_load_decodes_partial_option_blocks_with_defaults() throws {
        let directory = try makeTemporaryDirectory(named: "agent-manifests")
        // `canonical` without `prependArguments` and `passthrough` without
        // `subcommands` must decode — the option fields have defaults.
        try """
        {
          "schemaVersion": 1,
          "id": "generic-canonical",
          "displayName": "Bench Canonical Agent",
          "binaries": ["zentty-bench-agent"],
          "family": "canonical",
          "canonical": {
            "env": { "BENCH_AGENT_EVENT_COMMAND": "{cliBin} ipc agent-event" }
          },
          "passthrough": { "flags": ["--version"] }
        }
        """.write(
            to: directory.appendingPathComponent("generic-canonical.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let homeDirectory = try makeTemporaryDirectory(named: "agent-manifests-home")
        let bundleRoot = try makeTemporaryDirectory(named: "agent-manifests-bundle")

        let registry = AgentManifestRegistry.load(
            bundle: try XCTUnwrap(Bundle(url: bundleRoot)),
            environment: ["ZENTTY_AGENT_MANIFEST_DIRS": directory.path],
            homeDirectory: homeDirectory
        )

        let manifest = try XCTUnwrap(registry.manifest(id: "generic-canonical"))
        XCTAssertEqual(
            manifest.canonical?.env["BENCH_AGENT_EVENT_COMMAND"],
            "{cliBin} ipc agent-event"
        )
        XCTAssertEqual(manifest.canonical?.prependArguments, [])
        XCTAssertEqual(manifest.passthrough?.flags, ["--version"])
        XCTAssertEqual(manifest.passthrough?.subcommands, [])
    }

    func test_tool_matching_process_name_or_title() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "Kilo Code", binaries: ["kilo"]),
        ])
        XCTAssertEqual(registry.tool(matchingProcessNameOrTitle: "kilo"), .custom("Kilo Code"))
        XCTAssertEqual(registry.tool(matchingProcessNameOrTitle: "kilo - ~/proj"), .custom("Kilo Code"))
        XCTAssertNil(registry.tool(matchingProcessNameOrTitle: "kilometer"))
        XCTAssertNil(registry.tool(matchingProcessNameOrTitle: "vim"))
    }

    func test_shell_table_format() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "kilo", displayName: "Kilo Code", binaries: ["kilo"]),
            makeManifest(id: "zzz", displayName: "Zed Agent", binaries: ["zed", "zed-cli"]),
        ])
        // manifests are sorted by id
        XCTAssertEqual(registry.shellTable, "kilo=Kilo Code=kilo;zzz=Zed Agent=zed,zed-cli")
    }

    func test_init_skips_reserved_characters_in_display_name_and_binaries() {
        let registry = AgentManifestRegistry(manifests: [
            makeManifest(id: "bad1", displayName: "A;B"),
            makeManifest(id: "bad2", displayName: "A=B"),
            makeManifest(id: "bad3", displayName: "A,B"),
            makeManifest(id: "bad4", displayName: "Fine", binaries: ["a;b"]),
            makeManifest(id: "bad5", displayName: "Fine2", binaries: ["a=b"]),
        ])
        XCTAssertTrue(registry.manifests.isEmpty)
    }

    // MARK: - Helpers

    private func makeManifest(
        id: String,
        displayName: String,
        binaries: [String] = ["kilo"],
        schemaVersion: Int = 1,
        family: AgentManifest.Family = .canonical,
        opencodePlugin: AgentManifest.OpenCodePluginOptions? = nil
    ) -> AgentManifest {
        AgentManifest(
            schemaVersion: schemaVersion,
            id: id,
            displayName: displayName,
            binaries: binaries,
            family: family,
            opencodePlugin: opencodePlugin
        )
    }

    private func writeManifest(
        id: String,
        displayName: String,
        binaries: [String],
        family: String,
        extraFields: String = "",
        to directory: URL
    ) throws {
        let binaryList = binaries.map { "\"\($0)\"" }.joined(separator: ",")
        let trailing = extraFields.isEmpty ? "" : ",\n\(extraFields)"
        let json = """
        {
          "schemaVersion": 1,
          "id": "\(id)",
          "displayName": "\(displayName)",
          "binaries": [\(binaryList)],
          "family": "\(family)"\(trailing)
        }
        """
        try json.write(
            to: directory.appendingPathComponent("\(id).json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
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
}
