import Foundation
import zlib

enum SpreadsheetExport {
    private static let spreadsheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
    private static let declaration = #"<?xml version="1.0" encoding="UTF-8"?>"#
    private static let numberColumns: Set<String> = ["Duration (Seconds)", "Rating", "Rating Count", "Percent Complete"]
    private static let booleanColumns: Set<String> = ["Finished", "PDF Available", "Download Available"]

    static func data(headers: [String], rows: [[String]], title: String, numericHeaders: Set<String> = []) throws -> Data {
        guard rows.count < 1_048_576 else { throw ExportError.rowLimit }
        let columns = (1...headers.count).map(columnTitle)
        var sheet = Data("\(declaration)<worksheet xmlns=\"\(spreadsheet)\"><sheetData>".utf8)
        sheet.append(contentsOf: try rowXML(headers, number: 1, columns: columns, headers: [], numericHeaders: []).utf8)
        let numbers = numberColumns.union(numericHeaders)
        for (index, row) in rows.enumerated() {
            try Task.checkCancellation()
            sheet.append(contentsOf: try rowXML(row, number: index + 2, columns: columns, headers: headers, numericHeaders: numbers).utf8)
        }
        let lastColumn = columns[columns.count - 1]
        sheet.append(contentsOf: "</sheetData><autoFilter ref=\"A1:\(lastColumn)\(rows.count + 1)\"/></worksheet>".utf8)
        let types = """
            <Types xmlns="\(contentTypes)">
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
                <Default Extension="xml" ContentType="application/xml"/>
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            </Types>
            """
        let workbook = """
            <workbook xmlns="\(spreadsheet)" xmlns:r="\(officeRelationships)">
                <sheets><sheet name="\(xml(title))" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """
        return try zip([
            ("[Content_Types].xml", Data((declaration + types).utf8)),
            ("_rels/.rels", relationship("officeDocument", target: "xl/workbook.xml")),
            ("xl/workbook.xml", Data((declaration + workbook).utf8)),
            ("xl/_rels/workbook.xml.rels", relationship("worksheet", target: "worksheets/sheet1.xml")),
            ("xl/worksheets/sheet1.xml", sheet)
        ])
    }

    private static func relationship(_ kind: String, target: String) -> Data {
        Data((declaration + """
            <Relationships xmlns="\(packageRelationships)">
                <Relationship Id="rId1" Type="\(officeRelationships)/\(kind)" Target="\(target)"/>
            </Relationships>
            """).utf8)
    }

    private static func columnTitle(_ number: Int) -> String {
        var index = number
        var letters: [UInt8] = []
        while index > 0 {
            index -= 1
            letters.append(65 + UInt8(index % 26))
            index /= 26
        }
        return String(decoding: letters.reversed(), as: UTF8.self)
    }

    private static func rowXML(
        _ values: [String], number: Int, columns: [String], headers: [String], numericHeaders: Set<String>
    ) throws -> String {
        var row = "<row r=\"\(number)\">"
        for (index, value) in values.enumerated() where !value.isEmpty {
            let address = columns[index] + String(number)
            let header = headers.isEmpty ? "" : headers[index]
            if numericHeaders.contains(header), let numeric = Double(value), numeric.isFinite {
                row += "<c r=\"\(address)\"><v>\(value)</v></c>"
            } else if booleanColumns.contains(header), let truth = Bool(value) {
                row += "<c r=\"\(address)\" t=\"b\"><v>\(truth ? 1 : 0)</v></c>"
            } else {
                guard value.utf16.count <= 32_767 else { throw ExportError.cellLimit }
                row += "<c r=\"\(address)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
            }
        }
        return row + "</row>"
    }

    private static func xml(_ string: String) -> String {
        // Excel treats its own _xHHHH_ escapes specially even inside inline text.
        let literal = string.replacingOccurrences(
            of: #"_([xX][0-9A-Fa-f]{4}_)"#, with: "_x005F_$1", options: .regularExpression
        )
        var text = ""
        for scalar in literal.unicodeScalars {
            switch scalar {
            case "&": text += "&amp;"
            case "<": text += "&lt;"
            case ">": text += "&gt;"
            case "\"": text += "&quot;"
            default:
                switch scalar.value {
                case 0...8, 11...31, 0xfffe, 0xffff: text += String(format: "_x%04X_", scalar.value)
                default: text.unicodeScalars.append(scalar)
                }
            }
        }
        return text
    }

    // Excel accepts stored ZIP entries. Using zlib for CRC avoids a separate archive dependency.
    private static func zip(_ entries: [(String, Data)]) throws -> Data {
        let flags: UInt16 = 0x0800 // UTF-8 paths
        let version: UInt16 = 20
        let date: UInt16 = 33 // 1 January 1980 in DOS date format
        var archive = Data()
        var directory = Data()
        for (path, data) in entries {
            try Task.checkCancellation()
            let name = Data(path.utf8)
            guard let size = UInt32(exactly: data.count), let offset = UInt32(exactly: archive.count),
                  let nameLength = UInt16(exactly: name.count) else { throw ExportError.archiveLimit }
            let crc = data.withUnsafeBytes { bytes in
                UInt32(crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, size))
            }

            archive.appendLittleEndian(UInt32(0x04034b50)) // Local file header
            [version, flags, 0, 0, date].forEach { archive.appendLittleEndian($0) }
            [crc, size, size].forEach { archive.appendLittleEndian($0) }
            [nameLength, 0].forEach { archive.appendLittleEndian($0) }
            archive.append(name)
            archive.append(data)

            directory.appendLittleEndian(UInt32(0x02014b50)) // Central directory header
            [version, version, flags, 0, 0, date].forEach { directory.appendLittleEndian($0) }
            [crc, size, size].forEach { directory.appendLittleEndian($0) }
            [nameLength, 0, 0, 0, 0].forEach { directory.appendLittleEndian($0) }
            [0, offset].forEach { directory.appendLittleEndian($0) }
            directory.append(name)
        }
        guard let offset = UInt32(exactly: archive.count), let size = UInt32(exactly: directory.count),
              let count = UInt16(exactly: entries.count) else { throw ExportError.archiveLimit }
        archive.append(directory)
        archive.appendLittleEndian(UInt32(0x06054b50)) // End of central directory
        [0, 0, count, count].forEach { archive.appendLittleEndian($0) }
        [size, offset].forEach { archive.appendLittleEndian($0) }
        archive.appendLittleEndian(UInt16(0))
        return archive
    }

    private enum ExportError: LocalizedError {
        case cellLimit, rowLimit, archiveLimit

        var errorDescription: String? {
            switch self {
            case .cellLimit: "A field is too long for an Excel cell. Export as CSV or JSON to save the complete value."
            case .rowLimit: "The library exceeds Excel’s row limit. Export as CSV or JSON to include every title."
            case .archiveLimit: "The workbook is too large to save. Export as CSV or JSON to include every title."
            }
        }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
