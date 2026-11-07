import AppKit
import Foundation

struct StagedFile: Identifiable, Equatable {
  var id: UUID
  var label: String
  var source: DeskContext.Source?
  var image: DeskContext.Image?
}

/// Files the user dropped or pasted. Reading happens here; the turn just
/// attaches whatever was staged.
enum FileInbox {
  static func load(url: URL) -> StagedFile? {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let name = url.lastPathComponent
    switch DeskFiles.kind(filename: name) {
    case .text:
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            let text = DeskFiles.utf8Text(data)
      else {
        return StagedFile(
          id: UUID(),
          label: name,
          source: DeskContext.Source(name: "file", text: DeskFiles.otherNote(name: name)),
          image: nil
        )
      }
      return StagedFile(
        id: UUID(),
        label: name,
        source: DeskContext.Source(name: "file", text: DeskFiles.textNote(name: name, body: text)),
        image: nil
      )
    case .image:
      guard let image = NSImage(contentsOf: url), let jpeg = jpegData(image) else { return nil }
      return StagedFile(
        id: UUID(),
        label: name,
        source: DeskContext.Source(name: "file", text: DeskFiles.imageNote(name: name)),
        image: DeskContext.Image(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
      )
    case .other:
      return StagedFile(
        id: UUID(),
        label: name,
        source: DeskContext.Source(name: "file", text: DeskFiles.otherNote(name: name)),
        image: nil
      )
    }
  }

  static func loadImage(_ image: NSImage, label: String) -> StagedFile? {
    guard let jpeg = jpegData(image) else { return nil }
    let name = label.isEmpty ? "Pasted image" : label
    return StagedFile(
      id: UUID(),
      label: name,
      source: DeskContext.Source(name: "file", text: DeskFiles.imageNote(name: name)),
      image: DeskContext.Image(mediaType: "image/jpeg", data: jpeg.base64EncodedString())
    )
  }

  private static func jpegData(_ image: NSImage) -> Data? {
    let longest = max(image.size.width, image.size.height)
    let prepared: NSImage
    if longest > 1280, longest > 0 {
      let scale = 1280 / longest
      let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
      let next = NSImage(size: size)
      next.lockFocus()
      image.draw(
        in: NSRect(origin: .zero, size: size),
        from: NSRect(origin: .zero, size: image.size),
        operation: .copy,
        fraction: 1
      )
      next.unlockFocus()
      prepared = next
    } else {
      prepared = image
    }
    guard let tiff = prepared.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff)
    else { return nil }
    guard var data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else {
      return nil
    }
    if data.count > 700_000 {
      guard let smaller = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.35]) else {
        return nil
      }
      data = smaller
    }
    guard data.count <= 850_000 else { return nil }
    return data
  }
}
