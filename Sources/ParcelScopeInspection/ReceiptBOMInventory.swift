import Foundation

/// Validates the observed BOMStore v1 Paths layout before trusting pkgutil's file query.
/// Unknown layouts fail closed; this is an integrity check, not a replacement receipt authority.
struct ReceiptBOMInventory {
    let paths: Set<String>

    init(data: Data) throws {
        let reader = Reader(data: data)
        guard data.count >= 32, data.prefix(8) == Data("BOMStore".utf8), try reader.u32(8) == 1 else { throw InvalidBOM.layout }
        let allocated = try reader.u32(12)
        let index = try reader.region(offset: reader.u32(16), length: reader.u32(20))
        let variables = try reader.region(offset: reader.u32(24), length: reader.u32(28))
        guard index.count >= 4, variables.count >= 4, !index.overlaps(variables), index.lowerBound >= 32, variables.lowerBound >= 32 else { throw InvalidBOM.layout }
        let count = try reader.u32(index.lowerBound)
        guard count > 0, count <= (index.count - 4) / 8 else { throw InvalidBOM.layout }
        var blocks: [Range<Int>] = []
        for slot in 0..<count {
            let offset = index.lowerBound + 4 + slot * 8
            let address = try reader.u32(offset), length = try reader.u32(offset + 4)
            let block = address == 0xffffffff && length == 0xffffffff ? 0..<0 : try reader.region(offset: address, length: length)
            if !block.isEmpty {
                guard block.lowerBound >= 32, !block.overlaps(index), !block.overlaps(variables) else { throw InvalidBOM.layout }
            }
            blocks.append(block)
        }
        guard blocks[0].isEmpty, let last = blocks.lastIndex(where: { !$0.isEmpty }),
              allocated >= last, allocated < count else { throw InvalidBOM.layout }
        let occupied = blocks.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        for (left, right) in zip(occupied, occupied.dropFirst()) where left.overlaps(right) { throw InvalidBOM.layout }
        func block(_ id: Int, minimum: Int) throws -> Range<Int> {
            guard id > 0, blocks.indices.contains(id), blocks[id].count >= minimum else { throw InvalidBOM.layout }
            return blocks[id]
        }
        let variableCount = try reader.u32(variables.lowerBound)
        guard variableCount <= (variables.count - 4) / 5 else { throw InvalidBOM.layout }
        var cursor = variables.lowerBound + 4
        var namedBlocks: [String: Int] = [:]
        for _ in 0..<variableCount {
            guard cursor <= variables.upperBound - 5 else { throw InvalidBOM.layout }
            let id = try reader.u32(cursor)
            let length = Int(data[cursor + 4])
            cursor += 5
            guard length > 0, length <= variables.upperBound - cursor,
                  let name = String(data: data[cursor..<(cursor + length)], encoding: .utf8), namedBlocks[name] == nil else { throw InvalidBOM.layout }
            _ = try block(id, minimum: 1)
            namedBlocks[name] = id
            cursor += length
        }
        guard let pathsID = namedBlocks["Paths"] else { throw InvalidBOM.layout }
        let tree = try block(pathsID, minimum: 21)
        let start = tree.lowerBound
        guard data[start..<(start + 4)] == Data("tree".utf8), try reader.u32(start + 4) == 1 else { throw InvalidBOM.layout }
        let declared = try reader.u32(start + 16)
        guard declared <= count else { throw InvalidBOM.layout }
        var nodeID = try reader.u32(start + 8)
        var visited: Set<Int> = []
        // Branches use separator entries; descend to the first leaf, then validate the leaf chain.
        while true {
            guard visited.insert(nodeID).inserted else { throw InvalidBOM.layout }
            let node = try block(nodeID, minimum: 12)
            let leaf = try reader.u16(node.lowerBound)
            if leaf == 1 { break }
            guard leaf == 0, try reader.u16(node.lowerBound + 2) > 0, node.count >= 20 else { throw InvalidBOM.layout }
            nodeID = try reader.u32(node.lowerBound + 12)
        }
        visited.removeAll(keepingCapacity: true)
        var previous = 0
        var records: [Int: (parent: Int, name: String)] = [:]
        while nodeID != 0 {
            guard visited.insert(nodeID).inserted else { throw InvalidBOM.layout }
            let node = try block(nodeID, minimum: 12)
            let start = node.lowerBound
            let entries = try reader.u16(start + 2)
            guard try reader.u16(start) == 1, try reader.u32(start + 8) == previous,
                  entries <= (node.count - 12) / 8 else { throw InvalidBOM.layout }
            for item in 0..<entries {
                let offset = start + 12 + item * 8
                let value = try block(reader.u32(offset), minimum: 8)
                let key = try block(reader.u32(offset + 4), minimum: 6)
                let id = try reader.u32(value.lowerBound)
                _ = try block(reader.u32(value.lowerBound + 4), minimum: 1)
                let parent = try reader.u32(key.lowerBound)
                let bytes = data[(key.lowerBound + 4)..<key.upperBound]
                guard id > 0, records[id] == nil, bytes.last == 0,
                      !bytes.dropLast().contains(0), let name = String(data: bytes.dropLast(), encoding: .utf8),
                      !name.isEmpty, !name.contains("/") else { throw InvalidBOM.layout }
                records[id] = (parent, name)
            }
            previous = nodeID
            nodeID = try reader.u32(start + 4)
        }
        guard records.count == declared else { throw InvalidBOM.layout }
        let roots = records.filter { $0.value.parent == 0 && $0.value.name == "." }
        guard roots.count == 1 || records.isEmpty else { throw InvalidBOM.layout }
        let root = roots.first?.key
        var resolved: [Int: String] = [:]
        for id in records.keys {
            var chain: [Int] = [], seen: Set<Int> = []
            var current = id
            while current != 0 && resolved[current] == nil {
                guard seen.insert(current).inserted, let record = records[current] else { throw InvalidBOM.layout }
                chain.append(current)
                current = record.parent
            }
            // BOMStore can retain detached roots. pkgutil exposes only the '.' tree.
            guard current != 0 || chain.last == root else { continue }
            var prefix = resolved[current] ?? ""
            for item in chain.reversed() {
                let record = records[item]!
                guard record.name != "..", record.name != "." || item == root else { throw InvalidBOM.layout }
                if record.name != "." { prefix = prefix.isEmpty ? record.name : prefix + "/" + record.name }
                resolved[item] = prefix
            }
        }
        guard Set(resolved.values).count == resolved.count else { throw InvalidBOM.layout }
        paths = Set(resolved.values.filter { !$0.isEmpty })
    }

    private enum InvalidBOM: Error { case layout }
    private struct Reader {
        let data: Data
        func region(offset: Int, length: Int) throws -> Range<Int> {
            guard offset <= data.count, length <= data.count - offset else { throw InvalidBOM.layout }
            return offset..<(offset + length)
        }
        func u32(_ offset: Int) throws -> Int {
            let range = try region(offset: offset, length: 4)
            return data[range].reduce(0) { ($0 << 8) | Int($1) }
        }
        func u16(_ offset: Int) throws -> Int {
            let range = try region(offset: offset, length: 2)
            return data[range].reduce(0) { ($0 << 8) | Int($1) }
        }
    }
}
