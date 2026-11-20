import AppKit

/// Menu-bar icon: a solid key with "X̆" cut out (on the BDS layout the X key types Й).
/// Drawn in code as a template image, so macOS tints it for light and dark menu bars.
/// Geometry is on an 18×18 pt grid, y pointing down; see assets/icon.svg for the app icon it echoes.
enum MenuIcon {
    enum State { case normal, paused, needsPermission }

    static let normal = make(.normal)
    static let paused = make(.paused)
    static let needsPermission = make(.needsPermission)

    static func image(_ state: State) -> NSImage {
        switch state {
        case .normal: return normal
        case .paused: return paused
        case .needsPermission: return needsPermission
        }
    }

    private static func make(_ state: State) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // The cut-outs clear pixels, so do it inside a transparency layer
            // to keep them from punching through whatever is behind the icon.
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setFillColor(NSColor.black.cgColor)
            cg.addPath(CGPath(roundedRect: CGRect(x: 1.6, y: 1.6, width: 14.8, height: 14.8),
                              cornerWidth: 3.8, cornerHeight: 3.8, transform: nil))
            cg.fillPath()

            cg.setBlendMode(.clear)
            cg.setLineCap(.round)
            func stroke(_ width: CGFloat, _ build: () -> Void) {
                cg.setLineWidth(width); build(); cg.strokePath()
            }
            func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
                cg.move(to: CGPoint(x: x0, y: y0)); cg.addLine(to: CGPoint(x: x1, y: y1))
            }
            switch state {
            case .normal:
                stroke(2.15) { line(6.15, 7.95, 11.85, 13.65); line(11.85, 7.95, 6.15, 13.65) }   // X
                stroke(2.0) {                                                                     // breve
                    cg.move(to: CGPoint(x: 6.7, y: 4.6))
                    cg.addQuadCurve(to: CGPoint(x: 11.3, y: 4.6), control: CGPoint(x: 9, y: 7.1))
                }
            case .paused:
                stroke(2.25) { line(7.2, 6.2, 7.2, 11.8); line(10.8, 6.2, 10.8, 11.8) }
            case .needsPermission:
                stroke(2.25) { line(9, 5.4, 9, 9.6) }
                cg.fillEllipse(in: CGRect(x: 9 - 1.225, y: 12.6 - 1.225, width: 2.45, height: 2.45))
            }
            cg.endTransparencyLayer()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "JustType"
        return img
    }
}
