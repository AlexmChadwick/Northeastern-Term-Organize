//
//  MCPServer.swift
//  Term Organize
//
//  Copyright (C) 2026 Term Organize contributors.
//  SPDX-License-Identifier: AGPL-3.0-only
//  See LICENSE and NOTICE.md in the project root for details.
//

import Foundation

/// Local MCP server (stdio, JSON-RPC 2.0, protocol 2025-06-18).
/// Unofficial and not affiliated with Northeastern University.
public enum TermOrganizeMCP {
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "term-organize"
    public static let serverVersion = "1.0.0"
    public static let serverTitle = "Term Organize (unofficial, not affiliated with Northeastern University)"
    public static let instructions = """
    Unofficial and not affiliated with Northeastern University. \
    This server reads only the Fall 2026 (202710) and Spring 2027 (202730) catalogs bundled with Term Organize. \
    It does not use the network and it does not log in. \
    Plan tools read and write the same UserData.json file the Mac app stores on this computer. \
    Instructor emails are included only when the domain is exactly northeastern.edu or neu.edu.
    """

    public static func run() {
        let readOnly = ProcessInfo.processInfo.arguments.contains("--read-only")
            || ProcessInfo.processInfo.environment["TERM_ORGANIZE_MCP_READONLY"] == "1"
        let library = CatalogLibrary.loadBundled()
        let server = TermOrganizeMCPServer(library: library, plansURL: PlanFileLocation.resolve(), readOnly: readOnly)
        server.serveStandardIO()
    }
}

/// One stdio session. Tests call `handle` directly.
final class TermOrganizeMCPServer {
    let library: CatalogLibrary
    let plansURL: URL
    let readOnly: Bool

    init(library: CatalogLibrary, plansURL: URL, readOnly: Bool) {
        self.library = library
        self.plansURL = plansURL
        self.readOnly = readOnly
    }

    func serveStandardIO() {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        while let body = MCPFraming.readMessage(from: input) {
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { continue }
            if let response = handle(object) {
                MCPFraming.writeMessage(MCPJSON.data(response), to: output)
            }
        }
    }

    /// Returns nil for notifications (no id).
    func handle(_ message: [String: Any]) -> [String: Any]? {
        let method = message["method"] as? String ?? ""
        let id = message["id"]
        if id == nil {
            return nil
        }
        switch method {
        case "initialize":
            return rpc(id, result: [
                "protocolVersion": TermOrganizeMCP.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": TermOrganizeMCP.serverName,
                    "version": TermOrganizeMCP.serverVersion,
                    "title": TermOrganizeMCP.serverTitle,
                ],
                "instructions": TermOrganizeMCP.instructions,
            ])
        case "ping":
            return rpc(id, result: [String: Any]())
        case "tools/list":
            return rpc(id, result: ["tools": toolDefinitions().map(\.schema)])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return rpc(id, result: call(name: name, arguments: arguments))
        default:
            return rpcError(id, code: -32601, message: "Unknown method \(method)")
        }
    }

    func call(name: String, arguments: [String: Any]) -> [String: Any] {
        guard let tool = toolDefinitions().first(where: { $0.name == name }) else {
            return toolError("unknown_tool", "No tool named \(name).")
        }
        if readOnly && !tool.readOnly {
            return toolError("read_only", "This server is running with --read-only. \(name) is hidden.")
        }
        do {
            let value = try tool.body(arguments, self)
            return toolSuccess(value)
        } catch let error as MCPToolError {
            var payload: [String: Any] = ["error": error.code, "message": error.message]
            for (key, extra) in error.extra { payload[key] = extra }
            return toolResult(payload, isError: true)
        } catch {
            return toolError("failed", error.localizedDescription)
        }
    }

    func toolDefinitions() -> [MCPTool] {
        let plans = readOnly ? MCPTool.planTools.filter(\.readOnly) : MCPTool.planTools
        return MCPTool.catalogTools + plans
    }
}

struct MCPToolError: Error {
    var code: String
    var message: String
    var extra: [String: Any] = [:]
}

struct MCPTool {
    var name: String
    var description: String
    var schema: [String: Any]
    var readOnly: Bool
    var destructive: Bool
    var body: ([String: Any], TermOrganizeMCPServer) throws -> [String: Any]

    init(name: String, description: String, properties: [String: Any], required: [String], readOnly: Bool, destructive: Bool = false, body: @escaping ([String: Any], TermOrganizeMCPServer) throws -> [String: Any]) {
        self.name = name
        self.description = description
        self.readOnly = readOnly
        self.destructive = destructive
        self.body = body
        let annotations: [String: Any] = [
            "readOnlyHint": readOnly,
            "destructiveHint": destructive,
            "openWorldHint": false,
        ]
        self.schema = [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
            "annotations": annotations,
        ]
    }
}

enum MCPJSON {
    static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    static func object(_ value: Any) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

func rpc(_ id: Any?, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
}

func rpcError(_ id: Any?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

func toolSuccess(_ value: [String: Any]) -> [String: Any] {
    toolResult(value, isError: false)
}

func toolError(_ code: String, _ message: String) -> [String: Any] {
    toolResult(["error": code, "message": message], isError: true)
}

func toolResult(_ value: [String: Any], isError: Bool) -> [String: Any] {
    let text = String(data: MCPJSON.data(value), encoding: .utf8) ?? "{}"
    return [
        "content": [["type": "text", "text": text]],
        "structuredContent": value,
        "isError": isError,
    ]
}

func stringArg(_ arguments: [String: Any], _ key: String) -> String? {
    guard let raw = arguments[key] as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func intArg(_ arguments: [String: Any], _ key: String) -> Int? {
    if let number = arguments[key] as? Int { return number }
    if let number = arguments[key] as? NSNumber { return number.intValue }
    if let text = arguments[key] as? String, let number = Int(text) { return number }
    return nil
}

func boolArg(_ arguments: [String: Any], _ key: String) -> Bool? {
    if let value = arguments[key] as? Bool { return value }
    if let number = arguments[key] as? NSNumber { return number.boolValue }
    return nil
}

enum MCPFraming {
    static func readMessage(from handle: FileHandle) -> Data? {
        var header = Data()
        while !header.contains(Data("\r\n\r\n".utf8)) {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            header.append(byte)
            if header.count > 64 * 1024 { return nil }
        }
        let headerText = String(data: header, encoding: .utf8) ?? ""
        var length = 0
        for line in headerText.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            length = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        guard length > 0 else { return nil }
        var body = Data()
        while body.count < length {
            let chunk = handle.readData(ofLength: length - body.count)
            if chunk.isEmpty { return nil }
            body.append(chunk)
        }
        return body
    }

    static func writeMessage(_ body: Data, to handle: FileHandle) {
        let header = "Content-Length: \(body.count)\r\n\r\n"
        if let data = header.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        try? handle.write(contentsOf: body)
    }
}
