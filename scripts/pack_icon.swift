import Foundation

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
func lengthBytes(_ count: Int) -> Data {
    var value = UInt32(count).bigEndian
    return Data(bytes: &value, count: 4)
}
let sizes = [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
             ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
             ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
             ("ic10", "icon_512x512@2x.png")]
var chunks = Data()
for (type, filename) in sizes {
    let png = try Data(contentsOf: iconset.appendingPathComponent(filename))
    chunks.append(Data(type.utf8)); chunks.append(lengthBytes(png.count + 8)); chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(lengthBytes(chunks.count + 8)); icns.append(chunks)
try icns.write(to: output, options: .atomic)
