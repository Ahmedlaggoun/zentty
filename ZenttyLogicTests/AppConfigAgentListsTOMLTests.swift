import XCTest
@testable import Zentty

final class AppConfigAgentListsTOMLTests: XCTestCase {

    func test_missing_agent_lists_section_decodes_to_defaults() {
        let source = """
            [agent_caffeination]
            enabled = true
            """

        let decoded = AppConfigTOML.decode(source)

        XCTAssertEqual(decoded?.agentLists, .default)
        XCTAssertEqual(decoded?.agentLists.alwaysShowTaskLists, false)
        XCTAssertEqual(decoded?.agentLists.alwaysShowSubagentLists, false)
    }

    func test_agent_lists_round_trip() {
        var config = AppConfig.default
        config.agentLists.alwaysShowTaskLists = true
        config.agentLists.alwaysShowSubagentLists = true

        let decoded = AppConfigTOML.decode(AppConfigTOML.encode(config))

        XCTAssertEqual(decoded?.agentLists.alwaysShowTaskLists, true)
        XCTAssertEqual(decoded?.agentLists.alwaysShowSubagentLists, true)
    }

    func test_agent_lists_partial_section_keeps_other_default() {
        let decoded = AppConfigTOML.decode("""
            [agent_lists]
            always_show_task_lists = true
            """)

        XCTAssertEqual(decoded?.agentLists.alwaysShowTaskLists, true)
        XCTAssertEqual(decoded?.agentLists.alwaysShowSubagentLists, false)
    }

    func test_agent_lists_unknown_key_is_tolerated() {
        let decoded = AppConfigTOML.decode("""
            [agent_lists]
            always_show_task_lists = true
            future_flag = true
            """)

        XCTAssertEqual(decoded?.agentLists.alwaysShowTaskLists, true)
    }

    func test_agent_lists_rejects_non_bool_value() {
        XCTAssertNil(AppConfigTOML.decode("""
            [agent_lists]
            always_show_task_lists = "yes"
            """))
    }
}
