#!/usr/bin/env swift

import Foundation

private struct IconEntry {
    let type: String
    let pixels: Int
}

private let entries = [
    IconEntry(type: "icp4", pixels: 16),
    IconEntry(type: "icp5", pixels: 32),
    IconEntry(type: "icp6", pixels: 64),
    IconEntry(type: "ic07", pixels: 128),
    IconEntry(type: "ic08", pixels: 256),
    IconEntry(type: "ic09", pixels: 512),
    IconEntry(type: "ic10", pixels: 1024),
]

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift INPUT_PNG OUTPUT_ICNS\n".utf8))
    exit(64)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("RecoveryAppIcon-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

var chunks = Data()
for entry in entries {
    let resized = temporary.appendingPathComponent("\(entry.pixels).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-z", String(entry.pixels), String(entry.pixels),
        input.path, "--out", resized.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }

    let png = try Data(contentsOf: resized)
    chunks.append(contentsOf: entry.type.utf8)
    appendBigEndian(UInt32(png.count + 8), to: &chunks)
    chunks.append(png)
}

var result = Data("icns".utf8)
appendBigEndian(UInt32(chunks.count + 8), to: &result)
result.append(chunks)
try result.write(to: output, options: .atomic)
