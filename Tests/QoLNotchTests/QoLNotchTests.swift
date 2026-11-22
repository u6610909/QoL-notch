import XCTest
@testable import QoLNotch

final class QoLNotchTests: XCTestCase {
    // MARK: Thai tokenising

    func testThaiIsSplitIntoGluedWords() {
        let words = Tokenizer.tokenize("สวัสดีครับวันนี้ผมจะมานำเสนอโครงงาน")
        XCTAssertGreaterThan(words.count, 4, "Thai sentence should be segmented into several words")
        XCTAssertFalse(words[0].glue)
        XCTAssertTrue(words.dropFirst().allSatisfy(\.glue))
        XCTAssertEqual(words.map(\.text).joined(), "สวัสดีครับวันนี้ผมจะมานำเสนอโครงงาน")
    }

    func testMixedScriptKeepsEnglishWordsWhole() {
        let words = Tokenizer.tokenize("เราใช้ computer vision ตรวจจับรถ")
        let texts = words.map(\.text)
        XCTAssertTrue(texts.contains("computer"))
        XCTAssertTrue(texts.contains("vision"))
        XCTAssertFalse(words.first { $0.text == "computer" }!.glue)
    }

    func testEnglishUnchanged() {
        let words = Tokenizer.tokenize("Hello, world.\n\nNext paragraph")
        XCTAssertEqual(words.map(\.text), ["Hello,", "world.", "Next", "paragraph"])
        XCTAssertEqual(words.map(\.norm), ["hello", "world", "next", "paragraph"])
        XCTAssertTrue(words[2].paragraphStart)
        XCTAssertFalse(words.contains(where: \.glue))
    }

    func testLanguageDetection() {
        XCTAssertTrue(Tokenizer.isMostlyThai("วันนี้เราจะพูดเรื่อง AI"))
        XCTAssertFalse(Tokenizer.isMostlyThai("Today we talk about AI"))
    }

    // MARK: Thai tracking

    /// Feeds a growing transcript, as the recogniser does, and returns the final position.
    private func follow(script: String, spoken: String, step: Int = 3) -> (position: Int, count: Int) {
        let words = Tokenizer.tokenize(script)
        let index = Matcher.CharIndex(words: words)
        var current = 0
        let scalars = Array(spoken.unicodeScalars)
        var end = step
        while true {
            let partial = String(String.UnicodeScalarView(scalars.prefix(end)))
            if let next = Matcher.advanceByChars(index: index, current: current, transcript: partial) {
                XCTAssertGreaterThan(next, current)
                current = next
            }
            if end >= scalars.count { break }
            end = min(scalars.count, end + step)
        }
        return (current, words.count)
    }

    func testThaiFollowsToTheEnd() {
        let script = "สวัสดีครับ วันนี้ผมจะมานำเสนอโครงงานระบบควบคุมสัญญาณไฟจราจร"
        let result = follow(script: script, spoken: script.replacingOccurrences(of: " ", with: ""))
        XCTAssertEqual(result.position, result.count)
    }

    func testThaiStopsWhereSpeakerStops() {
        let script = "สวัสดีครับ วันนี้ผมจะมานำเสนอโครงงานระบบควบคุมสัญญาณไฟจราจร"
        let result = follow(script: script, spoken: "สวัสดีครับวันนี้ผมจะมานำเสนอ")
        XCTAssertGreaterThan(result.position, 3)
        XCTAssertLessThan(result.position, result.count)
    }

    func testMixedScriptSkipsUnrecognisedEnglish() {
        // The recogniser writes the English term differently; tracking should recover after it.
        let script = "ระบบของเราใช้ YOLO ตรวจจับรถยนต์บนถนนแล้วส่งข้อมูลไปยังตัวควบคุม"
        let result = follow(script: script, spoken: "ระบบของเราใช้โยโล่ตรวจจับรถยนต์บนถนนแล้วส่งข้อมูลไปยังตัวควบคุม")
        XCTAssertEqual(result.position, result.count)
    }

    func testUnrelatedThaiSpeechDoesNotAdvance() {
        let script = "วันนี้ผมจะมานำเสนอโครงงานระบบควบคุมสัญญาณไฟจราจร"
        let result = follow(script: script, spoken: "ขอโทษนะครับเดี๋ยวกลับมา")
        XCTAssertEqual(result.position, 0)
    }

    // MARK: English tracking still works

    func testEnglishWordMatching() {
        let words = Tokenizer.tokenize("This is QoL Notch. A teleprompter that sits right next to your camera")
        XCTAssertEqual(Matcher.advanceByWords(words: words, current: 0, tail: ["this", "is"]), 2)
        XCTAssertEqual(Matcher.advanceByWords(words: words, current: 2, tail: ["that", "sits", "right"]), 9)
        XCTAssertNil(Matcher.advanceByWords(words: words, current: 2, tail: ["camera"]))
    }

    // MARK: Obsidian import

    func testMarkdownBecomesSpeakable() {
        let note = """
        ---
        tags: [pitch]
        ---
        # Opening

        Hello **everyone**, see [[SP2 plan|our plan]] and [the site](https://example.com).
        ![[diagram.png]]
        - [ ] first *point*
        > [!note] Remember to smile
        %% private comment %%
        ```python
        print("no")
        ```
        Done ==now==. #pitch
        """
        let text = MarkdownCleaner.speakable(note)
        XCTAssertEqual(text, """
        Opening

        Hello everyone, see our plan and the site.

        first point
        Remember to smile

        Done now. pitch
        """)
    }

    // MARK: Team scripts

    func testSpeakerTags() {
        let words = Tokenizer.tokenize("@Tanny: Hello everyone.\n\n@Itim\nNow the vision part.\nStill me.\n@Kimmy: สวัสดีครับ")
        XCTAssertFalse(words.contains { $0.text.contains("@") })
        XCTAssertEqual(words.filter(\.speakerStart).map(\.text).prefix(2), ["Hello", "Now"])
        XCTAssertEqual(words.first?.speaker, "Tanny")
        XCTAssertEqual(words.first { $0.text == "Still" }?.speaker, "Itim")
        XCTAssertFalse(words.first { $0.text == "Still" }!.speakerStart)
        XCTAssertEqual(words.last?.speaker, "Kimmy")
        XCTAssertNil(Tokenizer.tokenize("email me @ home: now").first?.speaker)
    }

    // MARK: Rehearsal

    func testRehearsalReport() {
        let script = "One two three four five.\n\nSix seven eight nine ten."
        let words = Tokenizer.tokenize(script)
        // 5 words in 4 s, a 4 s stall, then 5 more words in 2 s.
        let events: [(t: Double, position: Int)] = [(1, 1), (2, 3), (4, 5), (8, 6), (9, 8), (10, 10)]
        let report = RehearsalReport.build(
            words: words, events: events, startPosition: 0, duration: 10,
            transcript: "one two um three four five um six seven actually eight nine ten", scriptText: script
        )
        XCTAssertEqual(report.wordsSpoken, 10)
        XCTAssertTrue(report.finished)
        XCTAssertEqual(report.wordsPerMinute, 60, accuracy: 0.01)
        XCTAssertEqual(report.pauses.count, 1)
        XCTAssertEqual(report.pauses[0].wordIndex, 5)
        XCTAssertEqual(report.pauses[0].seconds, 4, accuracy: 0.01)
        XCTAssertEqual(report.sections.count, 2)
        XCTAssertEqual(report.sections[0].seconds, 4, accuracy: 0.01)
        XCTAssertEqual(report.sections[1].seconds, 6, accuracy: 0.01)
        XCTAssertEqual(report.fillers.first, RehearsalReport.Filler(word: "um", count: 2))
        XCTAssertEqual(report.fillerCount, 3)
    }

    func testFillersInTheScriptAreNotCounted() {
        let fillers = RehearsalReport.countFillers(heard: "it is actually fine", script: "It is actually fine")
        XCTAssertTrue(fillers.isEmpty)
    }

    func testSectionsFollowSpeakers() {
        let words = Tokenizer.tokenize("@A: one two\n@B: three four")
        let report = RehearsalReport.build(
            words: words, events: [(1, 2), (5, 4)], startPosition: 0, duration: 5, transcript: "", scriptText: ""
        )
        XCTAssertEqual(report.sections.map(\.title), ["A", "B"])
        XCTAssertEqual(report.sections[1].seconds, 4, accuracy: 0.01)
    }

    // MARK: Phone remote

    func testRemoteRequiresTokenAndRunsCommands() {
        let server = RemoteServer()
        var received: [String] = []
        server.onCommand = { received.append($0) }
        server.stateProvider = { ["current": 3] }

        func status(_ path: String) -> String {
            let data = server.respond(to: "GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n")
            return String(String(decoding: data, as: UTF8.self).prefix(12))
        }
        XCTAssertEqual(status("/"), "HTTP/1.1 403")
        XCTAssertEqual(status("/cmd?t=wrong&a=toggle"), "HTTP/1.1 403")
        XCTAssertTrue(received.isEmpty)
        XCTAssertEqual(status("/?t=\(server.token)"), "HTTP/1.1 200")
        XCTAssertEqual(status("/cmd?t=\(server.token)&a=toggle"), "HTTP/1.1 200")
        XCTAssertEqual(received, ["toggle"])
        let state = String(decoding: server.respond(to: "GET /state?t=\(server.token) HTTP/1.1\r\n\r\n"), as: UTF8.self)
        XCTAssertTrue(state.contains("\"current\":3"))
        XCTAssertEqual(status("/nope?t=\(server.token)"), "HTTP/1.1 404")
    }

    // MARK: Island

    func testIslandSizes() {
        let island = IslandState.shared
        island.collapse()
        island.notchWidth = 185
        island.inset = 32
        let resting = island.size(listening: false, hasActivity: false)
        XCTAssertEqual(resting.height, 34)
        XCTAssertLessThan(resting.width, 200)
        XCTAssertGreaterThan(island.size(listening: false, hasActivity: true).width, resting.width + 100)

        // Reading opens the prompter without the pointer being there.
        XCTAssertTrue(island.isExpanded(listening: true))
        XCTAssertEqual(island.shownTab, .prompter)
        XCTAssertEqual(island.size(listening: true, hasActivity: false), CGSize(width: 475, height: 150))

        island.open(.timer)
        XCTAssertEqual(island.shownTab, .timer)
        XCTAssertGreaterThan(island.size(listening: false, hasActivity: false).width, 475)
        island.pointerLeft()
        XCTAssertFalse(island.isExpanded(listening: false))
    }

    func testTimerClock() {
        XCTAssertEqual(TimerModule.clock(300), "5:00")
        XCTAssertEqual(TimerModule.clock(59.2), "1:00")
        XCTAssertEqual(TimerModule.clock(0), "0:00")
    }

    func testSystemStatsReadable() {
        XCTAssertNotNil(StatsModule.cpuTicks())
        let memory = StatsModule.memoryUsed()
        XCTAssertNotNil(memory)
        XCTAssertGreaterThan(memory ?? 0, 0.05)
    }

    // MARK: Media and weather

    func testMediaTakesHelperUpdates() {
        let media = MediaModule.shared
        media.apply(["title": "Song", "artist": "Band", "duration": 200, "elapsed": 50,
                     "rate": 1, "playing": 1, "timestamp": Date().timeIntervalSince1970 - 10, "pid": 0, "artwork": ""])
        XCTAssertTrue(media.hasTrack)
        XCTAssertTrue(media.isPlaying)
        XCTAssertEqual(media.position(), 60, accuracy: 1)
        XCTAssertFalse(media.canShuffle)

        // Paused: the position stops moving.
        media.apply(["title": "Song", "artist": "Band", "duration": 200, "elapsed": 50,
                     "rate": 0, "playing": 0, "timestamp": Date().timeIntervalSince1970 - 10, "pid": 0, "artwork": ""])
        XCTAssertFalse(media.isPlaying)
        XCTAssertEqual(media.position(), 50, accuracy: 0.01)

        media.apply(["title": "", "playing": 1])
        XCTAssertFalse(media.hasTrack)
        XCTAssertFalse(media.isPlaying)
    }

    func testWeatherParsing() {
        let json = """
        {"current":{"temperature_2m":31.4,"apparent_temperature":36.0,"weather_code":61,"wind_speed_10m":9.6},
         "hourly":{"precipitation_probability":[70]}}
        """
        let reading = WeatherModule.parse(Data(json.utf8), place: "Bangkok")
        XCTAssertEqual(reading?.temperature, 31.4)
        XCTAssertEqual(reading?.rainChance, 70)
        XCTAssertEqual(WeatherModule.describe(reading?.code ?? 0).text, "Rain")
        XCTAssertNil(WeatherModule.parse(Data("{}".utf8), place: "x"))
    }

    func testBrowsingIslandFitsEveryTabIcon() {
        let island = IslandState.shared
        island.collapse()
        island.notchWidth = 185
        island.inset = 32
        island.open(.home)
        let side = (island.size(listening: false, hasActivity: false).width - island.notchWidth) / 2 - island.ear
        // Half the tabs sit on each side, with room left for the battery or the controls.
        XCTAssertGreaterThanOrEqual(side, 3 * 26 + 26 + 2 * 24)
        island.collapse()
    }

    func testMonthGridAndYearProgress() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15))!
        let grid = CalendarModule.monthGrid(for: date, calendar: calendar)
        XCTAssertEqual(grid.count, 5)
        XCTAssertEqual(grid[0], [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(grid[4], [29, 30, nil, nil, nil, nil, nil])
        calendar.firstWeekday = 2
        XCTAssertEqual(CalendarModule.monthGrid(for: date, calendar: calendar)[0], [nil, nil, nil, nil, nil, nil, 1])
        let progress = CalendarModule.yearProgress(for: date, calendar: calendar)
        XCTAssertEqual(progress.day, 319)
        XCTAssertEqual(progress.total, 365)
    }

    func testDailyLineAndBatteryTime() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DailyLine.line(for: day, custom: "  Ship it  "), "Ship it")
        let first = DailyLine.line(for: day, custom: "")
        XCTAssertTrue(DailyLine.builtIn.contains(first))
        XCTAssertEqual(DailyLine.line(for: day.addingTimeInterval(3600 * 5), custom: ""), first)
        XCTAssertNotEqual(DailyLine.line(for: day.addingTimeInterval(86400), custom: ""), first)
        XCTAssertEqual(StatsModule.timeLeft(220), "3h 40m")
        XCTAssertEqual(StatsModule.timeLeft(45), "45m")
    }

    func testPinnedToolsStayWithinSix() {
        let island = IslandState.shared
        let before = island.pinnedTabs
        island.pinnedTabs = IslandState.defaultPins
        XCTAssertEqual(island.pinnedTabs.count, 6)
        island.setPinned(.shelf, true)                       // full: nothing changes
        XCTAssertFalse(island.pinnedTabs.contains(.shelf))
        island.setPinned(.prompter, false)                   // the prompter always stays
        XCTAssertTrue(island.pinnedTabs.contains(.prompter))
        island.setPinned(.timer, false)
        island.setPinned(.mirror, true)
        XCTAssertEqual(island.pinnedTabs, [.prompter, .home, .media, .calendar, .notes, .mirror])
        island.movePinned(.mirror, by: -1)
        XCTAssertEqual(island.pinnedTabs, [.prompter, .home, .media, .calendar, .mirror, .notes])
        island.movePinned(.prompter, by: -1)                 // already first: nothing changes
        XCTAssertEqual(island.pinnedTabs.first, .prompter)
        XCTAssertTrue(island.moreTabs.contains(.timer))
        XCTAssertEqual(Set(island.pinnedTabs + island.moreTabs), Set(IslandTab.allCases))
        island.pinnedTabs = before
    }

    func testHomeHoldsAtMostThreeWidgets() {
        let look = IslandLook.shared
        let before = look.homeSlots
        look.homeSlots = [.music, .agenda, .weather]
        look.setSlot(.clock, true)                           // full: nothing changes
        XCTAssertEqual(look.homeSlots, [.music, .agenda, .weather])
        look.setSlot(.agenda, false)
        look.setSlot(.clock, true)
        look.moveSlot(.clock, by: -2)
        XCTAssertEqual(look.homeSlots, [.clock, .weather, .music])
        look.homeSlots = before
    }

    func testClipboardHistorySurvivesARestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qolnotch-clips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ClipboardModule(directory: folder, watching: false)
        first.add(text: "one")
        first.add(text: "two")
        first.add(text: "one")                               // copied again: moves to the front, no duplicate
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        first.add(png: try XCTUnwrap(picture.representation(using: .png, properties: [:])))
        XCTAssertEqual(first.items.map(\.text), [nil, "one", "two"])

        // A new launch reads the same history back, picture included.
        let second = ClipboardModule(directory: folder, watching: false)
        XCTAssertEqual(second.items.map(\.text), [nil, "one", "two"])
        let saved = try XCTUnwrap(second.imageURL(second.items[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))

        second.remove(second.items[0])                       // deleting a picture deletes its file
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        second.clear()
        XCTAssertTrue(ClipboardModule(directory: folder, watching: false).items.isEmpty)
    }

    // MARK: Peeks

    func testPeekQueueOrdersAndInterrupts() {
        let now = Date()
        var queue = PeekQueue()
        XCTAssertEqual(queue.post(Peek(kind: .shelfDrop, icon: "tray"), now: now, blocked: false), .show)
        XCTAssertEqual(queue.post(Peek(kind: .calendarSoon, icon: "calendar"), now: now, blocked: false), .show)
        XCTAssertEqual(queue.current?.kind, .calendarSoon)
        XCTAssertEqual(queue.post(Peek(kind: .shelfDrop, icon: "tray"), now: now, blocked: false), .queued)
        XCTAssertEqual(queue.finish(now: now.addingTimeInterval(1), blocked: false)?.kind, .shelfDrop)

        XCTAssertEqual(queue.post(Peek(kind: .volume, icon: "speaker", level: 0.3), now: now, blocked: false), .show)
        let id = queue.current?.id
        XCTAssertEqual(queue.post(Peek(kind: .volume, icon: "speaker", level: 0.6), now: now, blocked: false), .update)
        XCTAssertEqual(queue.current?.id, id)
        XCTAssertEqual(queue.current?.level, 0.6)
        queue.suspend()
        XCTAssertNil(queue.current)

        var blocked = PeekQueue()
        XCTAssertEqual(blocked.post(Peek(kind: .volume, icon: "speaker"), now: now, blocked: true), .dropped)
        XCTAssertEqual(blocked.post(Peek(kind: .lowBattery, icon: "battery.25"), now: now, blocked: true), .queued)
        XCTAssertNil(blocked.finish(now: now.addingTimeInterval(700), blocked: false))     // waited too long
        XCTAssertEqual(blocked.post(Peek(kind: .lowBattery, icon: "battery.25"), now: now, blocked: true), .queued)
        XCTAssertNil(blocked.finish(now: now.addingTimeInterval(10), blocked: true))       // still busy: keeps waiting
        XCTAssertEqual(blocked.finish(now: now.addingTimeInterval(10), blocked: false)?.kind, .lowBattery)
        blocked.suspend()
        XCTAssertNil(blocked.current)
    }

    func testPeekWidensTheRestingIsland() {
        let island = IslandState.shared
        PrompterModel.shared.docked = true
        PrompterModel.shared.panelVisible = true
        island.collapse()
        island.notchWidth = 185
        island.inset = 32
        island.post(Peek(kind: .charging, icon: "bolt.fill", value: "54%"))
        XCTAssertEqual(island.size(listening: false, hasActivity: false), CGSize(width: 185 + 12 + 192, height: 34))
        island.post(Peek(kind: .calendarSoon, icon: "calendar", title: "Soon", value: "14:05", detail: "Stand-up"))
        XCTAssertEqual(island.size(listening: false, hasActivity: false).height, 58)
        island.collapse()
        while island.peek != nil { island.endPeek() }
        XCTAssertEqual(island.size(listening: false, hasActivity: false).height, 34)
    }

    func testCalendarAnnouncesOnceAMinuteBefore() {
        let now = Date()
        let allDay = CalendarModule.Item(id: "a", title: "Holiday", start: now, allDay: true, colour: .red)
        let soon = CalendarModule.Item(id: "b", title: "Stand-up", start: now.addingTimeInterval(50), allDay: false, colour: .red)
        let later = CalendarModule.Item(id: "c", title: "Review", start: now.addingTimeInterval(600), allDay: false, colour: .red)
        let events = [allDay, soon, later]
        XCTAssertEqual(CalendarModule.dueSoon(events, now: now, announced: [])?.id, "b")
        XCTAssertNil(CalendarModule.dueSoon(events, now: now, announced: ["b"]))
        XCTAssertEqual(CalendarModule.dueSoon(events, now: now.addingTimeInterval(570), announced: ["b"])?.id, "c")
    }

    func testTimerSpokenLength() {
        XCTAssertEqual(TimerModule.spoken(300), "5-minute")
        XCTAssertEqual(TimerModule.spoken(90), "90-second")
    }

    func testPowerTrackerAnnouncesPlugAndLowOnce() {
        var tracker = PowerTracker()
        func step(_ level: Double, _ plugged: Bool = false) -> PowerEvent? {
            tracker.update(PowerSnapshot(level: level, pluggedIn: plugged))
        }
        XCTAssertNil(step(0.5))
        XCTAssertEqual(step(0.5, true), .pluggedIn(level: 0.5))
        XCTAssertNil(step(0.5, true))
        XCTAssertNil(step(0.5))
        XCTAssertNil(step(0.21))
        XCTAssertEqual(step(0.20), .low(threshold: 20, level: 0.20))
        XCTAssertNil(step(0.19))
        XCTAssertEqual(step(0.10), .low(threshold: 10, level: 0.10))
        XCTAssertNil(step(0.09))
        XCTAssertEqual(step(0.09, true), .pluggedIn(level: 0.09))
        XCTAssertNil(step(0.30))
        XCTAssertEqual(step(0.2), .low(threshold: 20, level: 0.2))

        var launchedLow = PowerTracker()
        XCTAssertNil(launchedLow.update(PowerSnapshot(level: 0.08, pluggedIn: false)))
        XCTAssertNil(launchedLow.update(PowerSnapshot(level: 0.07, pluggedIn: false)))

        var plunge = PowerTracker()
        XCTAssertNil(plunge.update(PowerSnapshot(level: 0.5, pluggedIn: false)))
        XCTAssertEqual(plunge.update(PowerSnapshot(level: 0.09, pluggedIn: false)), .low(threshold: 10, level: 0.09))
        XCTAssertNil(plunge.update(PowerSnapshot(level: 0.08, pluggedIn: false)))
    }

    func testVolumeGlyphAndBrightnessStep() {
        XCTAssertEqual(SystemHUD.volumeIcon(level: 0.5, muted: true), "speaker.slash.fill")
        XCTAssertEqual(SystemHUD.volumeIcon(level: 0, muted: false), "speaker.slash.fill")
        XCTAssertEqual(SystemHUD.volumeIcon(level: 0.4, muted: false), "speaker.wave.3.fill")
        XCTAssertTrue(SystemHUD.isKeyStep(from: 0.5, to: 0.5625))
        XCTAssertFalse(SystemHUD.isKeyStep(from: 0.5, to: 0.505))
    }

    func testRecordSpinsUpAndCoasts() {
        var spin = VinylSpin()
        var date = Date()
        func run(_ seconds: Double, playing: Bool) -> Double {
            var angle = 0.0
            for _ in 0..<Int((seconds * 30).rounded()) {
                date = date.addingTimeInterval(1 / 30)
                angle = spin.advance(to: date, playing: playing)
            }
            return angle
        }
        _ = spin.advance(to: date, playing: true)
        _ = run(0.1, playing: true)
        XCTAssertGreaterThan(spin.speed, 0.1)
        XCTAssertLessThan(spin.speed, 0.3)
        _ = run(1.9, playing: true)
        XCTAssertGreaterThan(spin.speed, 0.98)
        let before = spin.angle
        _ = run(0.3, playing: false)
        XCTAssertGreaterThan(spin.speed, 0.5)
        XCTAssertLessThan(spin.speed, 0.8)
        XCTAssertNotEqual(spin.angle, before)                // still turning while it coasts
        _ = run(3.7, playing: false)
        XCTAssertLessThan(spin.speed, 0.01)                  // 4 s paused: barely moving
        _ = run(0.5, playing: false)
        XCTAssertTrue(spin.isStill)                          // 4.5 s: still (e^(-4.5/0.8) < 0.004)

        var instant = VinylSpin()
        _ = instant.advance(to: date, playing: true, instant: true)
        _ = instant.advance(to: date.addingTimeInterval(1 / 30), playing: true, instant: true)
        XCTAssertEqual(instant.speed, 1)
    }

    func testArmAngle() {
        XCTAssertEqual(VinylArtwork.armAngle(playing: false, progress: 0.5), -8)
        XCTAssertEqual(VinylArtwork.armAngle(playing: true, progress: 0), 14)
        XCTAssertEqual(VinylArtwork.armAngle(playing: true, progress: 1), 20)
        XCTAssertEqual(VinylArtwork.armAngle(playing: true, progress: 2), 20)
    }

    func testScreenshotThumbnailFitsItsBox() {
        XCTAssertEqual(ScreenshotDrop.thumbSize(for: CGSize(width: 3024, height: 1964)), CGSize(width: 172, height: 112))
        XCTAssertEqual(ScreenshotDrop.thumbSize(for: CGSize(width: 400, height: 300)), CGSize(width: 149, height: 112))
        XCTAssertEqual(ScreenshotDrop.thumbSize(for: CGSize(width: 2000, height: 100)), CGSize(width: 180, height: 40))
        XCTAssertEqual(ScreenshotDrop.thumbSize(for: CGSize(width: 100, height: 2000)), CGSize(width: 64, height: 112))
    }

    func testDragOpensShelfAndRestoresTab() {
        let island = IslandState.shared
        let before = island.tab
        PrompterModel.shared.docked = true
        PrompterModel.shared.panelVisible = true
        island.collapse()
        island.tab = .timer
        island.beginDragOpen()
        XCTAssertTrue(island.dragOpen)
        XCTAssertEqual(island.tab, .shelf)
        XCTAssertTrue(island.isExpanded(listening: false))
        XCTAssertTrue(island.browsing)
        island.endDragOpen(landed: false)
        XCTAssertFalse(island.dragOpen)
        XCTAssertFalse(island.isExpanded(listening: false))
        let restored = expectation(description: "the old tab comes back after the island closes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restored.fulfill() }
        wait(for: [restored], timeout: 2)
        XCTAssertEqual(island.tab, .timer)

        island.pinned = true                                 // reading: a drag opens nothing
        island.beginDragOpen()
        XCTAssertFalse(island.dragOpen)
        island.collapse()
        island.tab = before
    }

    func testLockScreenLayout() {
        let compact = LockScreenLayout.make(screen: CGSize(width: 1512, height: 982), large: false)
        XCTAssertEqual(compact.panel, CGSize(width: 420, height: 132))
        XCTAssertEqual(compact.cover, 0)
        XCTAssertEqual(compact.bottom, 0.24 * 982, accuracy: 0.001)
        let large = LockScreenLayout.make(screen: CGSize(width: 1512, height: 982), large: true)
        XCTAssertEqual(large.cover, 275)
        XCTAssertEqual(large.card, CGSize(width: 260, height: 104))
        XCTAssertEqual(large.panel, CGSize(width: 331, height: 445))
        XCTAssertEqual(large.bottom, 159)
        XCTAssertEqual(LockScreenLayout.make(screen: CGSize(width: 3840, height: 2160), large: true).cover, 320)
        XCTAssertEqual(LockScreenLayout.make(screen: CGSize(width: 1280, height: 720), large: true).cover, 202)
    }

    func testArtworkVersionAdvancesWithTheCover() {
        let media = MediaModule.shared
        let start = media.artworkVersion
        func feed(_ path: String) {
            media.apply(["title": "Song", "artist": "Band", "duration": 200, "elapsed": 0, "rate": 1, "playing": 1,
                         "timestamp": Date().timeIntervalSince1970, "pid": 0, "artwork": path])
        }
        feed("/nonexistent/qolnotch-a.jpg")
        feed("/nonexistent/qolnotch-b.jpg")
        XCTAssertEqual(media.artworkVersion, start + 2)
        feed("/nonexistent/qolnotch-b.jpg")
        XCTAssertEqual(media.artworkVersion, start + 2)
        media.apply(["title": "", "playing": 1])
        XCTAssertFalse(media.hasTrack)
    }

    func testConcentricRadius() {
        XCTAssertEqual(IslandPalette.concentric(outer: 32, padding: 12), 20)
        XCTAssertEqual(IslandPalette.concentric(outer: 40, padding: 12), 22)
        XCTAssertEqual(IslandPalette.concentric(outer: 14, padding: 12), 8)
        var palette = IslandPalette()
        palette.tileRadius = 20
        XCTAssertEqual(palette.inner(8), 12)
        XCTAssertEqual(palette.inner(30), 4)
    }

    // MARK: Themes

    func testPresetsStayReadableOnBlack() {
        XCTAssertEqual(Theme.presets.count, 5)
        XCTAssertEqual(Set(Theme.presets.map(\.name)).count, 5)
        XCTAssertEqual(Theme.presets.first?.name, "Midnight Blue")
        for preset in Theme.presets {
            XCTAssertGreaterThanOrEqual(preset.accent.contrastOnBlack, 4.5, preset.name)
            XCTAssertFalse(preset.accentWasLifted, preset.name)
            XCTAssertEqual(preset.fontSize, 23)
        }
    }

    func testMidnightBlueMatchesTheOldStandardLook() {
        let midnight = Theme.midnightBlue
        XCTAssertEqual(midnight.accent, RGBA(0.04, 0.52, 1))
        XCTAssertEqual(midnight.glowColour, RGBA(0.04, 0.4, 1))
        XCTAssertEqual(midnight.font, .typewriter)
        XCTAssertEqual(midnight.fontSize, 23)
        XCTAssertEqual(Theme(), Theme.midnightBlue)
    }

    func testDarkAccentIsLifted() {
        let blue = RGBA(0, 0, 1)
        XCTAssertEqual(blue.contrastOnBlack, 2.44, accuracy: 0.01)
        let lifted = blue.liftedForBlack()
        XCTAssertGreaterThanOrEqual(lifted.contrastOnBlack, 4.5)
        XCTAssertTrue(lifted.b >= lifted.r && lifted.b >= lifted.g)
        XCTAssertGreaterThanOrEqual(RGBA(0, 0, 0).liftedForBlack().contrastOnBlack, 4.5)
        let bright = RGBA(1, 0.624, 0.039)
        XCTAssertEqual(bright.liftedForBlack(), bright)
        var theme = Theme()
        theme.accent = blue
        XCTAssertTrue(theme.accentWasLifted)
        XCTAssertEqual(RGBA(IslandPalette(theme).accent).contrastOnBlack, lifted.contrastOnBlack, accuracy: 0.05)
    }

    func testOldThemeFileStillOpens() throws {
        let paper = """
        {"name":"Paper","font":"serif","weight":"regular","fontSize":19,"text":{"r":0.16,"g":0.14,"b":0.12,"a":0.9},
         "highlight":{"r":0.72,"g":0.2,"b":0.12,"a":1},"highlightStyle":"underline","background":{"r":0.96,"g":0.94,"b":0.89,"a":1},
         "cornerRadius":12,"glow":0,"auraStrength":0,"aura":{"r":0.2,"g":0.24,"b":1,"a":1},"glass":false,"align":"centre"}
        """
        let old = try JSONDecoder().decode(Theme.self, from: Data(paper.utf8))
        XCTAssertEqual(old.name, "Paper")
        XCTAssertEqual(old.font, .serif)
        XCTAssertEqual(old.fontSize, 19)
        XCTAssertEqual(old.accent, RGBA(0.72, 0.2, 0.12))
        XCTAssertEqual(old.glowColour, old.accent)
        XCTAssertTrue(old.accentWasLifted)

        let terminal = """
        {"name":"Terminal","font":"mono","fontSize":11,"highlight":{"r":0.75,"g":1,"b":0.75,"a":1},
         "aura":{"r":0.1,"g":0.9,"b":0.3,"a":1},"auraStrength":0.6}
        """
        let mono = try JSONDecoder().decode(Theme.self, from: Data(terminal.utf8))
        XCTAssertEqual(mono.font, .typewriter)
        XCTAssertEqual(mono.fontSize, 14)
        XCTAssertEqual(mono.glowColour, RGBA(0.1, 0.9, 0.3))
    }

    func testThemeRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qolnotch-themes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let theme = Theme(name: "Ocean", accent: RGBA(0.2, 0.7, 0.9), glow: RGBA(0.1, 0.3, 0.8), font: .rounded, size: 30)
        let url = try ThemeFiles.write(theme, to: folder)
        XCTAssertEqual(ThemeFiles.load(from: folder), [theme])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "name", "accent", "glowColour", "font", "fontSize"])
    }

    func testThemeNamesStayUnique() {
        XCTAssertEqual(ThemeFiles.uniqueName("Forest", taken: ["Forest", "Forest 2"]), "Forest 3")
        XCTAssertEqual(ThemeFiles.uniqueName("  ", taken: []), "My Theme")
        XCTAssertTrue(Theme.isPresetName(" midnight blue "))
    }

    func testNotAThemeIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(Theme.self, from: Data("{}".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Theme.self, from: Data(#"{"script":"hi"}"#.utf8)))
    }

    func testNormalisedClampsSizeAndAlpha() {
        var theme = Theme()
        theme.fontSize = 60
        XCTAssertEqual(theme.normalised().fontSize, 40)
        theme.fontSize = 19.97
        XCTAssertEqual(theme.normalised().fontSize, 20)
        theme.accent.a = 0.3
        XCTAssertEqual(theme.normalised().accent.a, 1)
    }

    // MARK: Auto Scroll

    func testAutoScrollRestsLongerAtSentenceEnds() {
        let words = Tokenizer.tokenize("Hello there, friend. Next\n\nNew paragraph")
        let plain = AutoScroller.dwell(on: words[0], next: words[1], wordsPerMinute: 120)
        XCTAssertEqual(plain, 0.5, accuracy: 0.001)                       // 60 / 120
        let comma = AutoScroller.dwell(on: words[1], next: words[2], wordsPerMinute: 120)
        XCTAssertEqual(comma, 0.75, accuracy: 0.001)
        let stop = AutoScroller.dwell(on: words[2], next: words[3], wordsPerMinute: 120)
        XCTAssertEqual(stop, 1.1, accuracy: 0.001)
        let beforeParagraph = AutoScroller.dwell(on: words[3], next: words[4], wordsPerMinute: 120)
        XCTAssertEqual(beforeParagraph, 1.3, accuracy: 0.001)
        // Faster speeds shorten every rest; out-of-range speeds are held to the range.
        XCTAssertLessThan(AutoScroller.dwell(on: words[0], next: nil, wordsPerMinute: 200), plain)
        XCTAssertEqual(AutoScroller.dwell(on: words[0], next: nil, wordsPerMinute: 1000), 60 / 240, accuracy: 0.001)
    }

    func testMediaKeysStepLikeMacOS() {
        XCTAssertEqual(SystemHUD.stepped(0.5, up: true, fine: false), 0.5625, accuracy: 0.0001)
        XCTAssertEqual(SystemHUD.stepped(0.5, up: false, fine: false), 0.4375, accuracy: 0.0001)
        XCTAssertEqual(SystemHUD.stepped(0.5, up: true, fine: true), 0.5 + 1.0 / 64, accuracy: 0.0001)
        XCTAssertEqual(SystemHUD.stepped(1, up: true, fine: false), 1)
        XCTAssertEqual(SystemHUD.stepped(0.01, up: false, fine: false), 0)
        // An off-grid level snaps to the grid before stepping, like the system does.
        XCTAssertEqual(SystemHUD.stepped(0.52, up: true, fine: false), 0.5625, accuracy: 0.0001)

        // data1: key code in the high 16 bits, 0x0A = down / 0x0B = up, bit 0 = repeat.
        let down = MediaKeyTap.decode(data1: (0 << 16) | (0x0A << 8))
        XCTAssertEqual(down.code, 0); XCTAssertTrue(down.down); XCTAssertFalse(down.isRepeat)
        let up = MediaKeyTap.decode(data1: (3 << 16) | (0x0B << 8))
        XCTAssertEqual(up.code, 3); XCTAssertFalse(up.down)
        let held = MediaKeyTap.decode(data1: (1 << 16) | (0x0A << 8) | 1)
        XCTAssertTrue(held.down); XCTAssertTrue(held.isRepeat)
    }
}
