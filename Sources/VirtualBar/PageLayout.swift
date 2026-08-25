import Foundation

/// Where each page has to be parked so that paging looks like a fixed
/// viewport rather than icons wandering around the bar.
///
/// # Model
///
/// Work in *natural* coordinates — screen x with the spacer at zero. Icons
/// are numbered left to right, `i = 0..<n`, with left edge `L[i]` and width
/// `w[i]`. macOS packs status items with no gaps between them (measured:
/// every `L[i+1] - (L[i] + w[i])` is exactly 0), so
///
///     L[i] = L[0] + Σ_{j<i} w[j]         W = Σ_j w[j]
///
/// and with the spacer at zero the group is flush against our controls at
/// `C`, giving `L[0] = C - W`.
///
/// # Displacement law
///
/// A spacer of length `d` slides everything to its left by `s(d)` and leaves
/// everything to its right alone:
///
///     x[i](d) = L[i] - s(d)          s(d) = slope · (d - deadZone),  d ≥ 0
///
/// On the machine this was measured on, `slope = 1` and `deadZone = 0`, so
/// `s = d`. The important part is `s ≥ 0`: **the group can never move right
/// of its natural position**, and its natural position is already flush with
/// the controls.
///
/// # Placing a page
///
/// Page `p` spans `[a_p, b_p]`, is `W_p = Σ_{i∈p} w[i]` wide, and sits at
/// `inset_p` inside a viewport of width `V = max_p W_p` (0 when left
/// aligned, `(V - W_p)/2` centred, `V - W_p` right aligned). Landing its left
/// edge on viewport origin `U` costs
///
///     d_p = L[a_p] - (U + inset_p)
///
/// which is only legal while `d_p ≥ 0`, i.e. `U ≤ L[a_p] - inset_p`. One
/// shared viewport for every page therefore forces
///
///     U* = min_p ( L[a_p] - inset_p )
///     d_p = L[a_p] - inset_p - U*
///
/// # The gap is irreducible
///
/// The distance from a page's right edge to the controls is
///
///     C - (U* + W_p) = W - W_p
///
/// — the combined width of every icon *not* on this page. No value of `d`
/// shrinks it, because shrinking it means moving a page right of natural,
/// which `s ≥ 0` forbids. This is why the viewport lives at the far-left end
/// of the group's natural span instead of tucked up against the controls,
/// and why the space between is masked rather than closed.
struct PageLayout: Equatable {
    /// How a page narrower than the viewport is positioned within it.
    enum Alignment {
        case left, centre, right

        func inset(pageWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
            switch self {
            case .left: 0
            case .centre: (viewportWidth - pageWidth) / 2
            case .right: viewportWidth - pageWidth
            }
        }
    }

    /// Screen x of the viewport's left edge, `U*` above.
    let viewportOrigin: CGFloat
    /// Width of the widest page; the viewport never changes size.
    let viewportWidth: CGFloat
    /// Displacement `s_p` per page, in the same order as the pages given.
    let displacement: [CGFloat]

    /// - Parameters:
    ///   - pageLeftEdges: natural left edge `L[a_p]` of each page's first icon.
    ///   - pageWidths: `W_p` for each page.
    static func make(
        pageLeftEdges: [CGFloat],
        pageWidths: [CGFloat],
        alignment: Alignment = .left
    ) -> PageLayout? {
        guard !pageLeftEdges.isEmpty, pageLeftEdges.count == pageWidths.count else { return nil }

        let viewportWidth = pageWidths.max() ?? 0
        let insets = pageWidths.map { alignment.inset(pageWidth: $0, viewportWidth: viewportWidth) }
        let origin = zip(pageLeftEdges, insets).map(-).min() ?? 0
        // Clamped only as a guard against rounding; by construction of
        // `origin` every term here is already ≥ 0.
        let displacement = zip(pageLeftEdges, insets).map { max(0, $0 - $1 - origin) }

        return PageLayout(viewportOrigin: origin, viewportWidth: viewportWidth, displacement: displacement)
    }

    /// Converts a wanted displacement into a spacer length, inverting
    /// `s(d) = slope · (d - deadZone)`. Both default to the measured identity.
    static func spacerLength(for displacement: CGFloat, slope: CGFloat = 1, deadZone: CGFloat = 0) -> CGFloat {
        guard slope > 0 else { return displacement }
        return max(0, deadZone + displacement / slope)
    }
}
