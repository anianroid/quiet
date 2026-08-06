import Testing

// Relaunching Kamui mid-meeting used to leave no status indicator at all: the
// detector re-fires `.started` on its fresh stream, the island appears, and
// then the launch toast replaced it and its own 5s timer hid everything. A
// toast must always be temporary, never terminal.
@MainActor
struct IslandStateTests {
    @Test func toastReturnsToTheMeetingIslandInsteadOfHidingIt() async {
        let controller = QuietBannerController()
        controller.showMeetingStatus()
        #expect(controller.isShowingMeetingIsland)

        controller.show(message: "Armed", duration: 0.05)
        #expect(!controller.isShowingMeetingIsland)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(controller.isShowingMeetingIsland)

        controller.hide()
    }

    @Test func toastHidesWhenNoMeetingIsRunning() async {
        let controller = QuietBannerController()
        controller.show(message: "Armed", duration: 0.05)
        #expect(!controller.isShowingMeetingIsland)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isShowingMeetingIsland)
    }
}
