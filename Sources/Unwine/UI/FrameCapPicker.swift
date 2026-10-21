import SwiftUI

/// Off, and the frame caps that divide the screen's refresh rate (Wine's primary screen), so each
/// frame shows for the same time. A saved cap that is not one of them (picked on another screen, or
/// by a preset) stays in the list, so the picker never shows a blank.
struct FrameCapPicker: View {
    @Binding var cap: Int?

    var body: some View {
        Picker("Frame rate cap", selection: $cap) {
            Text("Off").tag(Int?.none)
            ForEach(choices, id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
        }
    }

    private var choices: [Int] {
        var list = Profiles.capChoices()
        if let cap, !list.contains(cap) { list.append(cap) }
        return list.sorted()
    }
}
