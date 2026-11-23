"""Write a single-sheet Excel workbook using SpreadsheetML."""

import io
import math
import re
from xml.sax.saxutils import escape, quoteattr
from zipfile import ZIP_DEFLATED, ZipFile

SPREADSHEET = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
OFFICE_RELATIONSHIPS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PACKAGE_RELATIONSHIPS = "http://schemas.openxmlformats.org/package/2006/relationships"
CONTENT_TYPES = "http://schemas.openxmlformats.org/package/2006/content-types"
XML_DECLARATION = '<?xml version="1.0" encoding="UTF-8"?>'
EXCEL_ESCAPE = re.compile(r"_[xX][0-9A-Fa-f]{4}_")
ESCAPED_CHARACTERS = re.compile(r"[\x00-\x08\x0b-\x1f\ud800-\udfff\ufffe\uffff]")


def _column(index):
    letters = []
    while index:
        index, remainder = divmod(index - 1, 26)
        letters.append(chr(ord("A") + remainder))
    return "".join(reversed(letters))


def _cell(value, reference):
    if value is None:
        return ""
    if isinstance(value, bool):
        return f'<c r="{reference}" t="b"><v>{int(value)}</v></c>'
    if isinstance(value, (int, float)) and math.isfinite(value):
        return f'<c r="{reference}"><v>{value}</v></c>'
    text = str(value)
    if len(text.encode("utf-16-le", errors="surrogatepass")) // 2 > 32767:
        raise ValueError("A field is too long for an Excel cell. Export as CSV or JSON to save the complete value.")
    text = EXCEL_ESCAPE.sub(lambda match: "_x005F_" + match[0][1:], text)
    text = ESCAPED_CHARACTERS.sub(lambda match: f"_x{ord(match[0]):04X}_", text)
    return f'<c r="{reference}" t="inlineStr"><is><t xml:space="preserve">{escape(text)}</t></is></c>'


def workbook_data(headers, rows, *, title):
    columns = tuple(_column(index) for index in range(1, len(headers) + 1))
    content_types = (
        f'<Types xmlns="{CONTENT_TYPES}">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '</Types>'
    )
    parts = {
        "[Content_Types].xml": content_types,
        "_rels/.rels": _relationship("officeDocument", "xl/workbook.xml"),
        "xl/workbook.xml": (
            f'<workbook xmlns="{SPREADSHEET}" xmlns:r="{OFFICE_RELATIONSHIPS}">'
            f'<sheets><sheet name={quoteattr(title)} sheetId="1" r:id="rId1"/></sheets></workbook>'
        ),
        "xl/_rels/workbook.xml.rels": _relationship("worksheet", "worksheets/sheet1.xml"),
    }
    output = io.BytesIO()
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
        for name, data in parts.items():
            archive.writestr(name, XML_DECLARATION + data)
        with archive.open("xl/worksheets/sheet1.xml", "w") as sheet:
            sheet.write(f'{XML_DECLARATION}<worksheet xmlns="{SPREADSHEET}"><sheetData>'.encode())
            _write_row(sheet, 1, headers, columns)
            number = 1
            for number, row in enumerate(rows, 2):
                if number > 1_048_576:
                    raise ValueError("The library exceeds Excel’s row limit. Export as CSV or JSON to include every title.")
                _write_row(sheet, number, row, columns)
            sheet.write(f'</sheetData><autoFilter ref="A1:{columns[-1]}{number}"/></worksheet>'.encode())
    return output.getvalue()


def _relationship(relation, target):
    return (f'<Relationships xmlns="{PACKAGE_RELATIONSHIPS}">'
            f'<Relationship Id="rId1" Type="{OFFICE_RELATIONSHIPS}/{relation}" Target="{target}"/>'
            '</Relationships>')


def _write_row(sheet, number, values, columns):
    cells = "".join(_cell(value, f"{column}{number}") for column, value in zip(columns, values, strict=True))
    sheet.write(f'<row r="{number}">{cells}</row>'.encode())
