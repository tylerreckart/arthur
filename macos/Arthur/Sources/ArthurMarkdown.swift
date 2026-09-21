import AppKit
import SwiftUI

enum ArthurBlock: Equatable {
  case prose(String)
  case bullets([String])
  case numbers([String])
  case code(String)
}

enum ArthurMarkdown {
  static func blocks(from text: String) -> [ArthurBlock] {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    var out: [ArthurBlock] = []
    var para: [String] = []
    var bullets: [String] = []
    var numbers: [String] = []
    var i = 0

    func flushPara() {
      let joined = para.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { out.append(.prose(joined)) }
      para.removeAll(keepingCapacity: true)
    }

    func flushList() {
      if !bullets.isEmpty {
        out.append(.bullets(bullets))
        bullets.removeAll(keepingCapacity: true)
      }
      if !numbers.isEmpty {
        out.append(.numbers(numbers))
        numbers.removeAll(keepingCapacity: true)
      }
    }

    while i < lines.count {
      let line = lines[i]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        flushPara()
        flushList()
        i += 1
        var code: [String] = []
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          code.append(lines[i])
          i += 1
        }
        if i < lines.count { i += 1 }
        out.append(.code(code.joined(separator: "\n")))
        continue
      }
      if let item = listItem(trimmed, markers: ["- ", "* ", "• "]) {
        flushPara()
        if !numbers.isEmpty { flushList() }
        bullets.append(item)
        i += 1
        continue
      }
      if let item = numberedItem(trimmed) {
        flushPara()
        if !bullets.isEmpty { flushList() }
        numbers.append(item)
        i += 1
        continue
      }
      if trimmed.isEmpty {
        flushPara()
        flushList()
        i += 1
        continue
      }
      flushList()
      para.append(trimmed)
      i += 1
    }
    flushPara()
    flushList()
    return out.isEmpty ? [.prose(text)] : out
  }

  static func inline(_ raw: String, live: Bool) -> Text {
    var result = Text("")
    var buffer = ""
    var bold = false
    var code = false
    var i = raw.startIndex
    let end = raw.endIndex

    func flush() {
      guard !buffer.isEmpty else { return }
      let chunk = styled(buffer, bold: bold, code: code, live: live)
      result = result + chunk
      buffer = ""
    }

    while i < end {
      if !code, raw[i...].hasPrefix("**") {
        flush()
        bold.toggle()
        i = raw.index(i, offsetBy: 2)
        continue
      }
      if raw[i] == "`" {
        flush()
        code.toggle()
        i = raw.index(after: i)
        continue
      }
      buffer.append(raw[i])
      i = raw.index(after: i)
    }
    flush()
    return result
  }

  private static func styled(_ text: String, bold: Bool, code: Bool, live: Bool) -> Text {
    let opacity = live ? 0.8 : 1.0
    if code {
      return Text(text)
        .font(.system(.body, design: .monospaced))
        .foregroundStyle(.primary.opacity(opacity))
    }
    return Text(text)
      .font(.system(.title3, design: .serif).weight(bold ? .semibold : .regular))
      .foregroundStyle(.primary.opacity(opacity))
  }

  private static func listItem(_ line: String, markers: [String]) -> String? {
    for marker in markers where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count))
    }
    return nil
  }

  private static func numberedItem(_ line: String) -> String? {
    guard let dot = line.firstIndex(of: ".") else { return nil }
    let num = line[..<dot]
    guard !num.isEmpty, num.allSatisfy(\.isNumber) else { return nil }
    let rest = line[line.index(after: dot)...]
    guard rest.first == " " else { return nil }
    return String(rest.dropFirst())
  }
}

struct ArthurProse: View {
  let text: String
  var live = false

  var body: some View {
    ArthurMarkdown.inline(text, live: live)
      .multilineTextAlignment(.leading)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct ArthurCodeBlock: View {
  let code: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Spacer(minLength: 0)
        Button {
          ArthurPasteboard.copy(code)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Copy code")
      }
      Text(code)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ArthurTheme.codeFill, in: .rect(cornerRadius: 10, style: .continuous))
    }
  }
}

enum ArthurPasteboard {
  static func copy(_ text: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
  }
}
