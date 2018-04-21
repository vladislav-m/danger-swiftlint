import Danger
import Foundation
import Files

public struct SwiftLint {
    internal static let danger = Danger()
    internal static let shellExecutor = ShellExecutor()

    /// This is the main entry point for linting Swift in PRs using Danger-Swift.
    /// Call this function anywhere from within your Dangerfile.swift.
    @discardableResult
    public static func lint(inline: Bool = false, directory: String? = nil, configFile: String? = nil, pathToSwiftLint: String? = nil, checkAllFiles: Bool = false) -> [Violation] {
        // First, for debugging purposes, print the working directory.
        print("Working directory: \(shellExecutor.execute("pwd"))")
        return self.lint(danger: danger, shellExecutor: shellExecutor, inline: inline, directory: directory, configFile: configFile, pathToSwiftLint: pathToSwiftLint, checkAllFiles: checkAllFiles)
    }
}

/// This extension is for internal workings of the plugin. It is marked as internal for unit testing.
internal extension SwiftLint {
    static func lint(
        danger: DangerDSL,
        shellExecutor: ShellExecutor,
        inline: Bool = false,
        directory: String? = nil,
        configFile: String? = nil,
        pathToSwiftLint: String? = nil,
        checkAllFiles: Bool = false,
        markdownAction: (String) -> Void = markdown,
        failAction: @escaping (String) -> Void = fail,
        failInlineAction: (String, String, Int) -> Void = fail,
        warnInlineAction: (String, String, Int) -> Void = warn) -> [Violation] {
        // Gathers modified+created files, invokes SwiftLint on each, and posts collected errors+warnings to Danger.

        func violationsFromFiles(files: [String], shouldBeInline: Bool) -> [Violation] {
            let decoder = JSONDecoder()
            let violations = files.filter { $0.hasSuffix(".swift") }.flatMap { file -> [Violation] in
                var arguments = ["lint", "--quiet", "--path \"\(file)\"", "--reporter json"]
                if let configFile = configFile {
                    arguments.append("--config \"\(configFile)\"")
                }
                let outputJSON = shellExecutor.execute(pathToSwiftLint ?? "swiftlint", arguments: arguments)
                do {
                    var violations = try decoder.decode([Violation].self, from: outputJSON.data(using: String.Encoding.utf8)!)
                    // Workaround for a bug that SwiftLint returns absolute path
                    violations = violations.map { violation in
                        var newViolation = violation
                        newViolation.inline = shouldBeInline
                        newViolation.update(file: file)

                        return newViolation
                    }

                    return violations
                } catch let error {
                    failAction("Error deserializing SwiftLint JSON response (\(outputJSON)): \(error)")
                    return []
                }
            }
            return violations
        }

        var allViolations: [Violation] = []

        var changedFiles = danger.git.createdFiles + danger.git.modifiedFiles
        print("Changed Count files in begining: \(changedFiles.count)")
        if let directory = directory {
            changedFiles = changedFiles.filter { $0.hasPrefix(directory) }
            print("Count files after hasPrefix(directory): \(changedFiles.count)")
        }

        allViolations = violationsFromFiles(files: changedFiles, shouldBeInline: inline)
        print("Count all change violation: \(allViolations.count)")

        if let directory = directory, checkAllFiles {
            var allFiles: [String] = []
            do {
                try Folder(path: directory).makeSubfolderSequence(recursive: true).forEach { folder in
                    files: for file in folder.files {
                        for changedFile in changedFiles {
                            if file.path.hasSuffix(changedFile) { continue files }
                        }

                        allFiles.append(file.path)
                    }
                }
            } catch let error {
                print("Error adding all Files: \(error)")
            }
            allViolations += violationsFromFiles(files: allFiles, shouldBeInline: false)
        }

        print("Count all violation: \(allViolations.count)")

        if !allViolations.isEmpty {
            var markdownMessage = ""
            allViolations.forEach { violation in
                if violation.inline {
                    switch violation.severity {
                    case .error:
                        failInlineAction(violation.reason, violation.file, violation.line)
                    case .warning:
                        warnInlineAction(violation.reason, violation.file, violation.line)
                    }
                    print("Inline action \(violation.file)")
                } else {
                    print("markdown action \(violation.file)")
                    markdownMessage += "\(violation.toMarkdown() )\n"
                }
            }
            if !markdownMessage.isEmpty {
                let finalMessage = """
                ### SwiftLint found issues
                || ||
                |:----:|:---:|:---:|
                \(markdownMessage)
                """
                markdownAction(finalMessage)
            }
        }

        return allViolations
    }
}
