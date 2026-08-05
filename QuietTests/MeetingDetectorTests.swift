import Testing

// classifyMeetingWindow is a pure (owner, title) -> label function.
struct MeetingDetectorTests {
    private let detector = MeetingDetector()

    @Test func meetCodeInBrowserTitle() {
        #expect(detector.classifyMeetingWindow(owner: "Google Chrome", title: "Meet – abc-defg-hij") == "Google Meet")
        #expect(detector.classifyMeetingWindow(owner: "Arc", title: "Meet - xyz-abcd-efg") == "Google Meet")
    }

    @Test func meetURLMatchesRegardlessOfOwner() {
        #expect(detector.classifyMeetingWindow(owner: "Anything", title: "meet.google.com/abc-defg-hij") == "Google Meet")
        #expect(detector.classifyMeetingWindow(owner: "Safari", title: "Google Meet") == "Google Meet")
    }

    @Test func instantMeetingInBrowser() {
        #expect(detector.classifyMeetingWindow(owner: "Brave Browser", title: "Meet - Instant meeting") == "Google Meet")
    }

    @Test func zoomWindows() {
        #expect(detector.classifyMeetingWindow(owner: "Google Chrome", title: "zoom.us/j/1234567890") == "Zoom (browser)")
        #expect(detector.classifyMeetingWindow(owner: "Microsoft Edge", title: "Zoom Meeting") == "Zoom (browser)")
        // "Zoom Meeting" outside a browser is not a browser-meeting signal.
        #expect(detector.classifyMeetingWindow(owner: "Finder", title: "Zoom Meeting") == nil)
    }

    @Test func teamsAndWebexWindows() {
        #expect(detector.classifyMeetingWindow(owner: "Anything", title: "teams.microsoft.com — Standup") == "Teams (browser)")
        #expect(detector.classifyMeetingWindow(owner: "Safari", title: "Microsoft Teams") == "Teams (browser)")
        #expect(detector.classifyMeetingWindow(owner: "Firefox", title: "company.webex.com/meet/ani") == "Webex (browser)")
    }

    @Test func ordinaryTabsAreNotMeetings() {
        #expect(detector.classifyMeetingWindow(owner: "Google Chrome", title: "Meet the team - Our Company") == nil)
        #expect(detector.classifyMeetingWindow(owner: "Google Chrome", title: "Committee meeting agenda - Google Docs") == nil)
        #expect(detector.classifyMeetingWindow(owner: "Google Chrome", title: "Inbox - Gmail") == nil)
        // A meet code without the word "meet" anywhere is not enough.
        #expect(detector.classifyMeetingWindow(owner: "Google Chrome", title: "abc-defg-hij") == nil)
    }
}
