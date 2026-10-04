/// Keeps the selected candidate inside a fixed-height window over the entire list.
public struct CandidateViewport {
    public var expanded = false
    public private(set) var start = 0
    public init() {}
    public mutating func reset() { expanded = false; start = 0 }
    public mutating func reveal(_ selected: Int, rows: Int, columns: Int = 1) {
        let width = max(1, columns), height = max(1, rows)
        let selectedRow = max(0, selected) / width
        let firstRow = start / width
        if selectedRow < firstRow { start = selectedRow * width }
        if selectedRow >= firstRow + height { start = (selectedRow - height + 1) * width }
    }
}
