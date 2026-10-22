import Foundation
import Testing
@testable import ThemeKit

@Test func colorsRoundTripHex() {
    #expect(RGBA(hex: "#FF8A33")?.hex == "#FF8A33")
    #expect(RGBA(hex: "#0B1424A6")?.hex == "#0B1424A6")
    #expect(RGBA(hex: "nope") == nil)
}

@Test func sunCyclePhasesAreAJSONObject() throws {
    let json = ##"{"kind":"sunCycle","phases":{"night":{"gradient":[{"color":"#000000","location":0}],"layers":[{"kind":"stars","density":0.5}]},"day":{"gradient":[{"color":"#4F86D4","location":0}],"layers":[]}}}"##
    let backdrop = try JSONDecoder().decode(Backdrop.self, from: Data(json.utf8))
    #expect(backdrop.phases?[.night]?.layers.first?.kind == .stars)
    let encoded = String(decoding: try JSONEncoder().encode(backdrop), as: UTF8.self)
    #expect(encoded.contains(##""night":{"##))
}
