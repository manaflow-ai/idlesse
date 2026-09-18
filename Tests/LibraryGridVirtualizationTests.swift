import AppKit

@main struct LibraryGridVirtualizationTests {
    static func main() {
        exerciseCatalog(count: 1_000)
        exerciseCatalog(count: 4_000)

        let narrow = LibraryGridLayoutPlan(itemCount: 4_000, contentWidth: 620, viewportHeight: 640)
        let wide = LibraryGridLayoutPlan(itemCount: 4_000, contentWidth: 1_440, viewportHeight: 640)
        precondition(wide.columns > narrow.columns, "Gallery must add columns as the viewport widens")
        precondition(wide.contentHeight < narrow.contentHeight, "More columns should reduce total scroll height")

        let originalY = narrow.frame(for: 120)!.minY + narrow.rowStride * 0.3
        let resizedY = wide.scrollOrigin(preserving: originalY, from: narrow)
        let expectedY = wide.frame(for: 120)!.minY + wide.rowStride * 0.3
        precondition(abs(resizedY - expectedY) < 0.01, "Resize must retain the visible wallpaper and row fraction")
        precondition(wide.scrollOrigin(preserving: 0, from: narrow) == 0)
        let bottom = wide.scrollOrigin(preserving: narrow.contentHeight, from: narrow)
        precondition(bottom <= wide.contentHeight - wide.viewportHeight, "Resize must clamp at the end of the catalog")
        print("library grid virtualization tests passed")
    }

    private static func exerciseCatalog(count: Int) {
        let viewportHeight: CGFloat = 640
        let plan = LibraryGridLayoutPlan(itemCount: count, contentWidth: 1_040, viewportHeight: viewportHeight)
        precondition(plan.rowCount == (count + plan.columns - 1) / plan.columns)
        precondition(plan.contentHeight > viewportHeight)

        let topRect = NSRect(x: 0, y: 0, width: plan.contentWidth, height: viewportHeight)
        let topCandidates = plan.indexes(intersecting: topRect, extraRows: 1)
        precondition(!topCandidates.isEmpty)
        precondition(topCandidates.count < 64,
                     "A \(count)-item catalog must keep the near-visible thumbnail window bounded")
        precondition(topCandidates.upperBound < count,
                     "Initial layout must avoid touching the full synthetic catalog")

        let middleIndex = count / 2
        let middleFrame = plan.frame(for: middleIndex)!
        let middleRect = NSRect(x: 0,
                                y: max(0, middleFrame.midY - viewportHeight / 2),
                                width: plan.contentWidth,
                                height: viewportHeight)
        let middleCandidates = plan.indexes(intersecting: middleRect, extraRows: 1)
        precondition(middleCandidates.contains(middleIndex))
        precondition(middleCandidates.count < 64,
                     "Scrolling deep into \(count) items must still instantiate/request only a small window")

        let lastIndex = count - 1
        let lastFrame = plan.frame(for: lastIndex)!
        let bottomRect = NSRect(x: 0,
                               y: max(0, lastFrame.maxY - viewportHeight),
                               width: plan.contentWidth,
                               height: viewportHeight)
        let bottomCandidates = plan.indexes(intersecting: bottomRect, extraRows: 1)
        precondition(bottomCandidates.contains(lastIndex))
        precondition(bottomCandidates.count < 64)

        let hitPoint = NSPoint(x: middleFrame.midX, y: middleFrame.midY)
        precondition(plan.itemIndex(at: hitPoint) == middleIndex, "Hover hit-testing must map geometry back to the correct item")
        let gapPoint = NSPoint(x: middleFrame.maxX + plan.spacing / 2, y: middleFrame.midY)
        precondition(plan.itemIndex(at: gapPoint) == nil, "Spacing between cards must stay non-interactive")
    }
}
