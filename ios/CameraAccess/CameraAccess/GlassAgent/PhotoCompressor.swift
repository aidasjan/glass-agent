//
// PhotoCompressor.swift
//
// Resizes a captured photo to ~1568px on the long side and compresses it to a JPEG under 1 MB
// before upload (what Claude vision works best with).
//

import UIKit

enum PhotoCompressor {
  static let maxLongSide: CGFloat = 1568
  static let maxBytes = 1_000_000

  static func prepare(_ data: Data) -> Data? {
    guard let image = UIImage(data: data) else { return nil }
    let size = image.size
    let scale = min(1, maxLongSide / max(size.width, size.height))
    let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    // Drawing also bakes in EXIF orientation, so the backend sees the photo upright.
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }

    for quality in [0.85, 0.75, 0.6, 0.45, 0.3] as [CGFloat] {
      if let jpeg = resized.jpegData(compressionQuality: quality), jpeg.count < maxBytes {
        return jpeg
      }
    }
    return nil
  }
}
