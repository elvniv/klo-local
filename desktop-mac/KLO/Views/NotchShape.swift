import SwiftUI

// Canonical notch-extension shape. Adapted from MrKai77's DynamicNotchKit
// (https://github.com/MrKai77/DynamicNotchKit) — the path is the proven
// solution every shipping notch app uses.
//
// The shape is filled BLACK and positioned with its top edge at the
// screen's top edge. Because the hardware notch IS black, the rendered
// shape merges with the notch: the screen's top portion appears as a
// single continuous black blob that extends downward into a panel.
//
// Two corner radii control the silhouette:
//   - topCornerRadius: small curves at the very top (where the shape
//     meets the screen edge). 6pt compact / 15pt expanded.
//   - bottomCornerRadius: larger curves at the bottom (the visible
//     wrap-around-the-notch curves). 14pt compact / 20pt expanded.
//
// The shape's width must be ≥ notchWidth + 2*topCornerRadius for the
// top corners not to clip the notch.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}
