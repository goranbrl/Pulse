// The MIT License (MIT)
//
// Copyright (c) 2020–2023 Alexander Grebenyuk (github.com/kean).

import XCTest
import Combine
@testable import Pulse
@testable import PulseUI

final class ConsoleDataSourceTests: XCTestCase, ConsoleDataSourceDelegate {
    var store: LoggerStore!
    var source: ConsoleSource = .store
    var mode: ConsoleMode = .all
    var options = ConsoleListOptions()

    var sut: ConsoleDataSource!

    var updates: [CollectionDifference<NSManagedObjectID>?] = []
    var onUpdate: ((CollectionDifference<NSManagedObjectID>?) -> Void)?

    let directory = TemporaryDirectory()

    override func setUp() {
        super.setUp()

        let storeURL = directory.url.appending(filename: "\(UUID().uuidString).pulse")
        store = try! LoggerStore(storeURL: storeURL, options: [.create, .synchronous])
        store.populate()

        recreate()
    }

    override func tearDown() {
        super.tearDown()

        try? store.destroy()
        directory.remove()
    }

    func recreate() {
        self.sut = ConsoleDataSource(store: store, source: source, mode: mode, options: options)
        self.sut.delegate = self
        self.sut.refresh()
    }

    func testThatAllLogsAreLoadedByDefault() {
        // GIVEN
        let entities = sut.entities

        // THEN all logs loaded, including traces because there is no predicate by default
        XCTAssertEqual(entities.count, 15)
        XCTAssertTrue(entities is [LoggerMessageEntity])
    }

    func testThatEntitiesAreOrderedByCreationDate() {
        // GIVEN
        let entities = sut.entities

        // THEN
        XCTAssertEqual(entities, entities.sorted(by: isOrderedBefore))
    }

    // MARK: Modes

    func testSwitchingToNetworkMode() {
        // WHEN
        mode = .tasks
        recreate()

        // THEN
        XCTAssertEqual(sut.entities.count, 8)
        XCTAssertTrue(sut.entities is [NetworkTaskEntity])
    }

    // MARK: Grouping

    func testGroupingLogsByLabel() {
        // WHEN
        options.messageGroupBy = .label
        recreate()

        // THEN entities are still loaded
        XCTAssertEqual(sut.entities.count, 15)

        // THEN sections are created
        let sections = sut.sections ?? []
        XCTAssertEqual(sections.count, 6)

        // THEN groups are sorted by the label
        XCTAssertEqual(sections.map(\.name), ["analytics", "application", "auth", "default", "network", "session"])

        // THEN entities within these groups are sorted by creation date
        for section in sections {
            let entities = section.objects as! [NSManagedObject]
            XCTAssertEqual(entities, entities.sorted(by: isOrderedBefore))
        }
    }

    func testGroupTasks() {
        XCTAssertEqual(groupTasksBy(.url).map(sut.name), ["https://github.com/CreateAPI/Get", "https://github.com/kean/Nuke/archive/tags/11.0.0.zip", "https://github.com/login?username=kean&password=sensitive", "https://github.com/octocat.png", "https://github.com/profile/valdo", "https://github.com/repos", "https://github.com/repos/kean/Nuke", "https://objects-origin.githubusercontent.com/github-production-release-asset-2e65be"])
        XCTAssertEqual(groupTasksBy(.host).map(sut.name), ["github.com", "objects-origin.githubusercontent.com"])
        XCTAssertEqual(groupTasksBy(.method).map(sut.name), ["GET", "PATCH", "POST"])
        XCTAssertEqual(groupTasksBy(.statusCode).map(sut.name), ["200 OK", "204 No Content", "404 Not Found"])
        XCTAssertEqual(groupTasksBy(.errorCode).map(sut.name), ["4864", "–"])
        XCTAssertEqual(groupTasksBy(.requestState).map(sut.name), ["Success", "Failure"])
        XCTAssertEqual(groupTasksBy(.responseContentType).map(sut.name), ["–", "application/html", "application/json", "application/zip", "image/png", "text/html"])
        XCTAssertTrue(groupTasksBy(.session).map(sut.name).first?.hasPrefix("#1") ?? false)
    }

    func groupTasksBy(_ grouping: ConsoleListOptions.TaskGroupBy) -> [NSFetchedResultsSectionInfo] {
        mode = .tasks
        options.taskGroupBy = grouping
        recreate()
        return sut.sections ?? []
    }

    // MARK: Sorting

    func testSetCustomSortDescriptors() throws {
        // WHEN
        sut.sortDescriptors = [NSSortDescriptor(keyPath: \LoggerMessageEntity.level, ascending: true)]
        sut.refresh()

        // THEN
        let messages = try XCTUnwrap(sut.entities as? [LoggerMessageEntity])
        XCTAssertEqual(messages, messages.sorted(by: { $0.level < $1.level }))
    }

    // MARK: Delegate

    func testWhenMessageIsInsertedDelegateIsCalled() throws {
        let expectation = self.expectation(description: "onUpdate")
        onUpdate = { _ in expectation.fulfill() }

        // WHEN
        store.storeMessage(label: "test", level: .debug, message: "test")

        // THEN delegate is called
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(updates.count, 1)
        let diff = try XCTUnwrap(XCTUnwrap(updates.first))

        // THEN item is inserted at the bottom
        XCTAssertEqual(diff.count, 1)
        let change = try XCTUnwrap(diff.first)
        switch change {
        case let .insert(offset, _, _):
            XCTAssertEqual(offset, 15)
        case .remove:
            XCTFail()
        }

        // THEN entities are updated
        XCTAssertTrue(sut.entities.contains(where: {
            ($0 as! LoggerMessageEntity).text == "test" })
        )
    }

    func testWhenMessageIsInsertedInGroupedDataSourceDelegateIsCalled() throws {
        // GIVEN
        options.messageGroupBy = .level
        recreate()

        let expectation = self.expectation(description: "onUpdate")
        onUpdate = { _ in expectation.fulfill() }

        // WHEN
        store.storeMessage(label: "test", level: .debug, message: "test")

        // THEN delegate is called
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(updates.count, 1)
        let diff = try XCTUnwrap(updates.first)

        // THEN diff is empty because it's not supported for sectioned request
        XCTAssertNil(diff)

        // THEN entities are updated
        XCTAssertTrue(sut.entities.contains(where: {
            ($0 as! LoggerMessageEntity).text == "test" })
        )

        // THEN sections are updated
        XCTAssertTrue((sut.sections ?? []).contains(where: {
            ($0.objects as! [LoggerMessageEntity]).contains(where: {
                $0.text == "test"
            })
        }))
    }

    // MARK: ConsoleDataSourceDelegate

    func dataSource(_ dataSource: ConsoleDataSource, didUpdateWith diff: CollectionDifference<NSManagedObjectID>?) {
        updates.append(diff)
        onUpdate?(diff)
    }
}

private func isOrderedBefore(_ lhs: NSManagedObject, _ rhs: NSManagedObject) -> Bool {
    let lhs = (lhs as? LoggerMessageEntity)?.createdAt ?? (lhs as? NetworkTaskEntity)!.createdAt
    let rhs = (rhs as? LoggerMessageEntity)?.createdAt ?? (rhs as? NetworkTaskEntity)!.createdAt
#if os(macOS)
    return lhs < rhs
#else
    return lhs > rhs
#endif
}
