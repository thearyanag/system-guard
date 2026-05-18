import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-icns.swift <input-iconset> <output-icns>\n".utf8))
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])

let entries: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

func appendChunk(type: String, payload: Data, to output: inout Data) {
    output.append(Data(type.utf8))
    appendUInt32(UInt32(payload.count + 8), to: &output)
    output.append(payload)
}

var chunks = Data()
for entry in entries {
    let url = iconsetURL.appendingPathComponent(entry.1)
    let payload = try Data(contentsOf: url)
    appendChunk(type: entry.0, payload: payload, to: &chunks)
}

var icns = Data("icns".utf8)
appendUInt32(UInt32(chunks.count + 8), to: &icns)
icns.append(chunks)

try icns.write(to: outputURL)
