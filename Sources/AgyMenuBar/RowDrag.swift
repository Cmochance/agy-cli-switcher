import CoreGraphics

// 按住一行上下拖动时的位置计算。frames 是开始拖的那一刻每一行在列表里的位置，
// 顺序和列表一样，行的高度可以不同。
struct RowDrag: Equatable {
    var index: Int
    var frames: [CGRect]
    var translation: CGFloat = 0

    // 被拖的那一行跟着鼠标走，但不拖出列表。
    var offset: CGFloat {
        guard frames.indices.contains(index), let first = frames.first, let last = frames.last else {
            return 0
        }
        return min(max(translation, first.minY - frames[index].minY), last.maxY - frames[index].maxY)
    }

    // 松手之后这一行排到第几个。往下拖时，它的下沿越过了后面几行的中线，就往后排几位；往上拖时看上沿。
    // 按边沿算而不是按中线算：拖到列表尽头时，它的中线到不了最后一行的中线之外。
    var target: Int {
        guard frames.indices.contains(index) else {
            return index
        }
        let moved = offset
        if moved > 0 {
            let bottom = frames[index].maxY + moved
            return index + frames[(index + 1)...].filter { $0.midY < bottom }.count
        }
        if moved < 0 {
            let top = frames[index].minY + moved
            return index - frames[..<index].filter { $0.midY > top }.count
        }
        return index
    }

    // 别的行给它让位置：夹在原位置和新位置之间的那些行，往反方向挪它的高度。
    func shift(of row: Int) -> CGFloat {
        guard frames.indices.contains(index), row != index else {
            return 0
        }
        if index < row, row <= target {
            return -frames[index].height
        }
        if target <= row, row < index {
            return frames[index].height
        }
        return 0
    }
}
