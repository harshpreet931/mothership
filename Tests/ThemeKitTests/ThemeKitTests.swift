import Testing
@testable import ThemeKit

@Test func colorsRoundTripHex() {
    #expect(RGBA(hex: "#FF8A33")?.hex == "#FF8A33")
    #expect(RGBA(hex: "#0B1424A6")?.hex == "#0B1424A6")
    #expect(RGBA(hex: "nope") == nil)
}
