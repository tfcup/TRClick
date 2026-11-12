import Foundation
import Testing
@testable import TRClick

@MainActor
struct FileTemplateTests {
    @Test func clearingTemplateRemovesItsReference() throws {
        var file = NewFile(ext: "txt", name: "Text", idx: 0)
        file.template = URL(fileURLWithPath: "/tmp/previous-template.txt")
        try file.setTemplate(from: nil, in: FileManager.default.temporaryDirectory)
        #expect(file.template == nil)
        #expect(file.ext == ".txt")
    }

    @Test func templatesAreIsolatedAndSameNamedReplacementsKeepNewContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("TRClick-templates-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let sources = [root.appendingPathComponent("first"), root.appendingPathComponent("second")]
        for source in sources { try manager.createDirectory(at: source, withIntermediateDirectories: true) }
        let first = sources[0].appendingPathComponent("template.txt")
        let second = sources[1].appendingPathComponent("template.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let storage = root.appendingPathComponent("storage")
        var a = NewFile(ext: ".txt", name: "A", idx: 0)
        var b = NewFile(ext: ".txt", name: "B", idx: 1)
        try a.setTemplate(from: first, in: storage)
        try b.setTemplate(from: second, in: storage)
        let savedA = try #require(a.template)
        let savedB = try #require(b.template)
        #expect(savedA != savedB)
        #expect(try String(contentsOf: savedA, encoding: .utf8) == "first")
        #expect(try String(contentsOf: savedB, encoding: .utf8) == "second")

        try a.setTemplate(from: second, in: storage)
        try a.setTemplate(from: a.template, in: storage)
        #expect(try String(contentsOf: savedA, encoding: .utf8) == "second")
        #expect(try String(contentsOf: savedB, encoding: .utf8) == "second")

        #expect(throws: (any Error).self) {
            try a.setTemplate(from: root.appendingPathComponent("missing.txt"), in: storage)
        }
        #expect(a.template == savedA)
        #expect(try String(contentsOf: savedA, encoding: .utf8) == "second")
    }
}
