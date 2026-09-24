//
//  CodexHookIntegrationManager.swift
//  Notchly
//
//  Created by n0xbyte on 29.05.2026.
//

import Foundation
import Combine

@MainActor
final class CodexHookIntegrationManager: ObservableObject {
    @Published private(set) var installState: AgentHookInstallState = .unknown

    private let fileManager = FileManager.default

    var isInstalled: Bool {
        if case .installed = installState {
            return true
        }
        return false
    }

    var configPreview: String {
        """
        [features]
        hooks = true

        # Notchly Codex alerts
        [[hooks.UserPromptSubmit]]
        [[hooks.UserPromptSubmit.hooks]]
        type = "command"
        command = '\(startedHookCommand)'

        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = '\(completedHookCommand)'

        [[hooks.PermissionRequest]]
        [[hooks.PermissionRequest.hooks]]
        type = "command"
        command = '\(approvalHookCommand)'

        [[hooks.PreToolUse]]
        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = '\(approvedHookCommand)'

        [[hooks.Interrupt]]
        [[hooks.Interrupt.hooks]]
        type = "command"
        command = '\(interruptedHookCommand)'

        [[hooks.PostToolUse]]
        [[hooks.PostToolUse.hooks]]
        type = "command"
        command = '\(approvedHookCommand)'
        """
    }

    func refreshStatus() {
        installState = isHookInstalled() ? .installed : .notInstalled
    }

    func install() {
        installState = .installing

        do {
            try installHookScript()
            try updateCodexConfig()
            refreshStatus()
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    private func installHookScript() throws {
        try fileManager.createDirectory(
            at: hookDirectoryURL,
            withIntermediateDirectories: true
        )

        try hookScript.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptURL.path
        )
    }

    private func updateCodexConfig() throws {
        try fileManager.createDirectory(
            at: codexConfigDirectoryURL,
            withIntermediateDirectories: true
        )

        var config = ""
        if fileManager.fileExists(atPath: codexConfigURL.path) {
            config = try String(contentsOf: codexConfigURL, encoding: .utf8)
        }

        config = enableCodexHooks(in: config)
        config = removeManagedHookBlocks(from: config)

        config = appendHookBlockIfNeeded(
            to: config,
            eventName: "UserPromptSubmit",
            command: startedHookCommand
        )

        config = appendHookBlockIfNeeded(
            to: config,
            eventName: "Stop",
            command: completedHookCommand
        )

        config = appendHookBlockIfNeeded(
            to: config,
            eventName: "PermissionRequest",
            command: approvalHookCommand
        )

        config = appendHookBlockIfNeeded(
            to: config,
            eventName: "PreToolUse",
            command: approvedHookCommand
        )

        config = appendHookBlockIfNeeded(
            to: config,
            eventName: "PostToolUse",
            command: approvedHookCommand
        )

        config = appendHookBlockIfNeeded(
            to: config,
            eventName: "Interrupt",
            command: interruptedHookCommand
        )

        try config.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    }

    private func removeManagedHookBlocks(from config: String) -> String {
        let lines = config.components(separatedBy: .newlines)
        var keptLines: [String] = []
        var pendingBlock: [String] = []
        var isCapturingHookBlock = false

        func flushPendingBlock() {
            guard !pendingBlock.isEmpty else { return }

            if pendingBlock.joined(separator: "\n").contains(hookScriptURL.path) {
                pendingBlock.removeAll()
                return
            }

            keptLines.append(contentsOf: pendingBlock)
            pendingBlock.removeAll()
        }

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            let isHookHeader = trimmedLine.hasPrefix("[[hooks.")

            if isHookHeader {
                flushPendingBlock()
                isCapturingHookBlock = true
                pendingBlock.append(line)
                continue
            }

            if isCapturingHookBlock {
                let startsRegularTable = trimmedLine.hasPrefix("[") &&
                    trimmedLine.hasSuffix("]") &&
                    !trimmedLine.hasPrefix("[[")

                if startsRegularTable {
                    flushPendingBlock()
                    isCapturingHookBlock = false
                    keptLines.append(line)
                } else {
                    pendingBlock.append(line)
                }
                continue
            }

            keptLines.append(line)
        }

        flushPendingBlock()

        return keptLines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }

    private func appendHookBlockIfNeeded(to config: String, eventName: String, command: String) -> String {
        guard !containsHookCommand(config, eventName: eventName, command: command) else { return config }

        var updatedConfig = config
        if !updatedConfig.isEmpty, !updatedConfig.hasSuffix("\n") {
            updatedConfig += "\n"
        }

        if !updatedConfig.contains("# Notchly Codex alerts") {
            updatedConfig += "\n# Notchly Codex alerts\n"
        }

        updatedConfig += """
[[hooks.\(eventName)]]
[[hooks.\(eventName).hooks]]
type = "command"
command = '\(command)'
"""
        updatedConfig += "\n"
        return updatedConfig
    }

    private func containsHookCommand(_ config: String, eventName: String, command: String) -> Bool {
        let eventHeader = "[[hooks.\(eventName)]]"
        let handlerHeader = "[[hooks.\(eventName).hooks]]"
        var isInsideEvent = false

        for line in config.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine == eventHeader || trimmedLine == handlerHeader {
                isInsideEvent = true
                continue
            }

            if trimmedLine.hasPrefix("[[hooks."),
               trimmedLine != eventHeader,
               trimmedLine != handlerHeader {
                isInsideEvent = false
            }

            if isInsideEvent, trimmedLine.contains(command) {
                return true
            }
        }

        return false
    }

    private func enableCodexHooks(in config: String) -> String {
        var lines = config.components(separatedBy: .newlines)

        guard let featuresIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[features]")
            lines.append("hooks = true")
            return lines.joined(separator: "\n")
        }

        var sectionEndIndex = lines.index(after: featuresIndex)
        while sectionEndIndex < lines.endIndex {
            let trimmedLine = lines[sectionEndIndex].trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                break
            }
            sectionEndIndex = lines.index(after: sectionEndIndex)
        }

        if let existingIndex = lines[lines.index(after: featuresIndex)..<sectionEndIndex]
            .firstIndex(where: {
                let trimmedLine = $0.trimmingCharacters(in: .whitespaces)
                return trimmedLine.hasPrefix("hooks") || trimmedLine.hasPrefix("codex_hooks")
            }) {
            lines[existingIndex] = "hooks = true"
        } else {
            lines.insert("hooks = true", at: sectionEndIndex)
        }

        return lines.joined(separator: "\n")
    }

    private func isHookInstalled() -> Bool {
        guard fileManager.isExecutableFile(atPath: hookScriptURL.path),
              let config = try? String(contentsOf: codexConfigURL, encoding: .utf8) else {
            return false
        }

        return config.contains("hooks = true") &&
            containsHookCommand(config, eventName: "UserPromptSubmit", command: startedHookCommand) &&
            config.contains(completedHookCommand) &&
            containsHookCommand(config, eventName: "PermissionRequest", command: approvalHookCommand) &&
            containsHookCommand(config, eventName: "PreToolUse", command: approvedHookCommand) &&
            containsHookCommand(config, eventName: "PostToolUse", command: approvedHookCommand) &&
            containsHookCommand(config, eventName: "Interrupt", command: interruptedHookCommand)
    }

    private var completedHookCommand: String {
        "\"\(hookScriptURL.path)\" completed"
    }

    private var startedHookCommand: String {
        "\"\(hookScriptURL.path)\" started"
    }

    private var interruptedHookCommand: String {
        "\"\(hookScriptURL.path)\" interrupted"
    }

    private var approvalHookCommand: String {
        "\"\(hookScriptURL.path)\" approval"
    }

    private var approvedHookCommand: String {
        "\"\(hookScriptURL.path)\" approved"
    }

    private var hookScript: String {
        """
#!/bin/sh
set -eu
umask 077

event_type="${1:-completed}"
events_dir="$HOME/Library/Application Support/Notchly"
events_file="$events_dir/agent-events.jsonl"

mkdir -p "$events_dir"
/usr/bin/python3 -c '
import json, sys, time
try:
    hook = json.load(sys.stdin)
except (ValueError, TypeError):
    hook = {}
kind = {"started": "started", "approved": "progress", "approval": "access_request", "completed": "completed", "interrupted": "cancelled"}.get(sys.argv[1], "progress")
event = {"source": "codex", "type": kind, "session_id": hook.get("session_id"), "turn_id": hook.get("turn_id"), "timestamp": time.time(), "ttl": 3}
with open(sys.argv[2], "a", encoding="utf-8") as output:
    output.write(json.dumps(event, separators=(",", ":")) + "\\n")
' "$event_type" "$events_file"
case "$event_type" in completed|interrupted) printf '{}\\n' ;; esac
"""
    }

    private var codexConfigDirectoryURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private var codexConfigURL: URL {
        codexConfigDirectoryURL.appendingPathComponent("config.toml")
    }

    private var hookDirectoryURL: URL {
        fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchly", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    private var hookScriptURL: URL {
        hookDirectoryURL.appendingPathComponent("notchly-codex-hook")
    }
}
