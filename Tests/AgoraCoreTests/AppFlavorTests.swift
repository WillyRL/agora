import Testing

@testable import AgoraCore

struct AppFlavorTests {
    @Test func eachCopyIsTellableFromItsBundleID() {
        #expect(AppFlavor(bundleID: "io.github.willyrl.agora") == .stable)
        #expect(AppFlavor(bundleID: "app.agora.Agora") == .stable)  // before the first release
        #expect(AppFlavor(bundleID: "io.github.willyrl.agora.nightly") == .nightly)
        #expect(AppFlavor(bundleID: "io.github.willyrl.agora.dev") == .dev)
        #expect(AppFlavor(bundleID: nil) == .dev)
    }

    @Test func copiesKeepTheirLoginsApartButStableKeepsItsOldPlace() {
        #expect(AppFlavor.stable.keychainService == "app.agora.remote-login")
        #expect(Set(AppFlavor.allCases.map(\.keychainService)).count == 3)
        #expect(Set(AppFlavor.allCases.map(\.bundleID)).count == 3)
        #expect(AppFlavor.nightly.bundleID == "io.github.willyrl.agora.nightly")
    }
}
