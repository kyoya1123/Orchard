import OrchardCore
import Foundation
import XCTest

final class SelectionResolverTests: XCTestCase {
    // MARK: - Helpers

    private func destination(
        _ name: String,
        kind: XcodeDestination.Kind = .simulator,
        runtime: String = "17.0",
        id: String = UUID().uuidString
    ) -> XcodeDestination {
        XcodeDestination(id: id, name: name, runtime: runtime, isAvailable: true, kind: kind)
    }

    private func worktree(branch: String, path: String) -> WorktreeContext {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let project = XcodeProject(
            rootURL: root,
            fileURL: root.appendingPathComponent("App.xcodeproj"),
            kind: .project
        )
        return WorktreeContext(
            project: project,
            gitInfo: GitInfo(rootURL: root, branchName: branch),
            terminalContexts: []
        )
    }

    // MARK: - Scheme matching stages

    func testSchemeExactMatch() throws {
        let result = SelectionResolver.resolveScheme(name: "ProdDebug", in: ["ProdDebug", "DevDebug", "Release"])
        XCTAssertEqual(try result.get(), "ProdDebug")
    }

    func testSchemeCaseInsensitiveMatch() throws {
        let result = SelectionResolver.resolveScheme(name: "proddebug", in: ["ProdDebug", "DevDebug"])
        XCTAssertEqual(try result.get(), "ProdDebug")
    }

    func testSchemePrefixMatch() throws {
        let result = SelectionResolver.resolveScheme(name: "Prod", in: ["ProdDebug", "DevDebug"])
        XCTAssertEqual(try result.get(), "ProdDebug")
    }

    func testSchemeSubstringMatch() throws {
        let result = SelectionResolver.resolveScheme(name: "Widget", in: ["ProdDebug", "WidgetExtension"])
        XCTAssertEqual(try result.get(), "WidgetExtension")
    }

    func testSchemeNotFound() {
        let result = SelectionResolver.resolveScheme(name: "Nope", in: ["ProdDebug", "DevDebug"])
        guard case .failure(.notFound) = result else {
            return XCTFail("Expected notFound, got \(result)")
        }
    }

    func testSchemeAmbiguousSubstring() {
        let result = SelectionResolver.resolveScheme(name: "Debug", in: ["ProdDebug", "DevDebug"])
        guard case let .failure(.ambiguous(_, _, candidates)) = result else {
            return XCTFail("Expected ambiguous, got \(result)")
        }
        XCTAssertEqual(Set(candidates), ["ProdDebug", "DevDebug"])
    }

    /// A tighter stage should win before a looser one is considered: an exact
    /// match resolves even though a substring search would match several.
    func testTighterStageWinsOverLooser() throws {
        let result = SelectionResolver.resolveScheme(name: "Debug", in: ["Debug", "ProdDebug", "DevDebug"])
        XCTAssertEqual(try result.get(), "Debug")
    }

    // MARK: - Destination matching

    func testDestinationExactIDWins() throws {
        let target = destination("iPhone 15", id: "ABC-123")
        let others = [destination("iPad"), target, destination("iPhone 15", runtime: "18.0")]
        let result = SelectionResolver.resolveDestination(name: "ABC-123", kind: nil, in: others)
        XCTAssertEqual(try result.get().id, "ABC-123")
    }

    func testDestinationKindFilter() throws {
        let sim = destination("iPhone 15", kind: .simulator)
        let device = destination("iPhone 15", kind: .device)
        let result = SelectionResolver.resolveDestination(name: "iPhone 15", kind: .device, in: [sim, device])
        XCTAssertEqual(try result.get().kind, .device)
    }

    func testDestinationAmbiguousByRuntime() {
        let a = destination("iPhone 15", runtime: "17.0")
        let b = destination("iPhone 15", runtime: "18.0")
        let result = SelectionResolver.resolveDestination(name: "iPhone 15", kind: nil, in: [a, b])
        guard case let .failure(.ambiguous(_, _, candidates)) = result else {
            return XCTFail("Expected ambiguous, got \(result)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    // MARK: - Worktree matching

    func testWorktreeMatchByBranch() throws {
        let worktrees = [
            worktree(branch: "develop", path: "/repo/main"),
            worktree(branch: "feature/x", path: "/repo/wt-x")
        ]
        let result = SelectionResolver.resolveWorktree(name: "feature/x", in: worktrees)
        XCTAssertEqual(try result.get().worktreeURL.path, "/repo/wt-x")
    }

    func testWorktreeDisambiguateByPathFragment() throws {
        let worktrees = [
            worktree(branch: "develop", path: "/Projects/cir-mobile"),
            worktree(branch: "develop", path: "/Projects/coefont-full-repo/cir-mobile")
        ]
        // The branch alone is ambiguous; a path fragment narrows it to one.
        let ambiguous = SelectionResolver.resolveWorktree(name: "develop", in: worktrees)
        guard case .failure(.ambiguous) = ambiguous else {
            return XCTFail("Expected ambiguous for bare branch name")
        }

        let resolved = SelectionResolver.resolveWorktree(name: "coefont-full-repo", in: worktrees)
        XCTAssertEqual(try resolved.get().worktreeURL.path, "/Projects/coefont-full-repo/cir-mobile")
    }

    func testWorktreeNotFoundInEmptyList() {
        let result = SelectionResolver.resolveWorktree(name: "develop", in: [])
        guard case .failure(.notFound) = result else {
            return XCTFail("Expected notFound, got \(result)")
        }
    }
}
