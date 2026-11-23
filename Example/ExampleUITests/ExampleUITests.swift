//
//  ExampleUITests.swift
//  ExampleUITests
//
//  Created by APPLE on 2024/12/27.
//

import XCTest

final class ExampleUITests: XCTestCase {

    override func setUpWithError() throws {

        // 首次断言失败后终止当前 UI 测试。
        continueAfterFailure = false

    }

    override func tearDownWithError() throws {
    }

    @MainActor
    func testExample() throws {
        // 启动示例应用，验证基本启动流程。
        let app = XCUIApplication()
        app.launch()

    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // 使用 XCTest 启动指标测量应用启动耗时。
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
