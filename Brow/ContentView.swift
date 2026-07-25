//
//  ContentView.swift
//  BrowApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BrowViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BrowViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @ObservedObject private var claudeStore = ClaudeCodeStore.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    /// Per-screen memo: was *this* screen's notch already open when AI
    /// auto-expansion kicked in? Each screen tracks this independently so
    /// every screen can decide for itself whether to close on collapse —
    /// the global `coordinator.aiAutoExpanded` flag would otherwise be
    /// cleared by whichever screen fires onChange first, leaving the
    /// others stuck open.
    @State private var notchWasOpenBeforeAI: Bool = false

    /// Task 2.7: brief `.approved`/`.denied` flash for the v8 closed pill's
    /// `.mascot` case, set from `claudeStore.recentlyResolved` (still the
    /// live source of truth for decisions) and self-cleared back to nil
    /// (→ `.idle`) after `mascotFlashDuration` — mirrors the `hoverTask`/
    /// `notchWasOpenBeforeAI` self-cancelling `Task` idiom already used in
    /// this file rather than adding a new timer abstraction.
    @State private var mascotFlashState: BrowMascot.MascotState?
    @State private var mascotFlashTask: Task<Void, Never>?
    private let mascotFlashDuration: Duration = .seconds(1.2)

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private let animationSpring = Animation.interactiveSpring(response: 0.38, dampingFraction: 0.8, blendDuration: 0)

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    /// Height of the opened header lane (`BrowHeader`), matching the frame in
    /// `NotchLayout`'s open branch.
    private var openHeaderHeight: CGFloat { max(24, vm.effectiveClosedNotchHeight) }

    /// Cap the auto-height AI surface content grows to before it scrolls.
    /// `maxOpenNotchHeight` minus the header and the panel's bottom padding /
    /// margin, so header + content + padding stays within the window.
    private var openSurfaceMaxHeight: CGFloat {
        max(120, maxOpenNotchHeight - openHeaderHeight - 24)
    }

    /// Height for the opened `mainLayout`:
    /// - AI tab → `nil`, so the panel auto-sizes to header + the measured,
    ///   capped surface content (the single `NotchShape` fill/clip hugs it).
    /// - home / shelf → the fixed `openNotchSize.height` (unchanged).
    /// - closed → `nil` (intrinsic closed-pill size).
    private var openPanelHeight: CGFloat? {
        guard vm.notchState == .open else { return nil }
        return coordinator.currentView == .ai ? nil : openNotchSize.height
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? 12 : 0)
                    // Single fill for the whole island (closed pill + open
                    // panel): `V6Palette.ink`, painted once here and clipped
                    // to `currentNotchShape`. v8 content views (`V8ClosedPill`,
                    // `IslandSurfaceView`) must NOT paint their own
                    // background/shape — a second nested fill drifts out of
                    // sync with this one (different padding/size) and shows
                    // up as a mismatched black frame around an inset panel.
                    .background(V6Palette.ink)
                    .clipShape(currentNotchShape)
                    .overlay {
                        // Animated rainbow halo — only while Claude Code
                        // is waiting on the user AND the notch is open.
                        // No border in closed state, no border once the
                        // queue is empty.
                        if claudeStore.shouldAutoExpand && vm.notchState == .open {
                            rainbowNotchHalo
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: openPanelHeight)
                    .conditionalModifier(true) { view in
                        // Task 2.7: close timing aligned to the v8 spec's
                        // reference morph (open: spring 0.42/0.8, close:
                        // smooth 0.3s) — `currentNotchShape` is the single
                        // `NotchShape` instance both states clip through,
                        // so this animation interpolates its corner radii
                        // (`NotchShape.animatableData`) rather than
                        // cross-fading two shapes.
                        let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
                        let closeAnimation = Animation.smooth(duration: 0.3)
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(.smooth, value: gestureProgress)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            withAnimation {
                                isHovering = false
                            }
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        //                    Button("Edit") { // Doesnt work....
                        //                        let dn = DynamicNotch(content: EditPanelView())
                        //                        dn.toggle()
                        //                    }
                        //                    .keyboardShortcut("E", modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(.smooth, value: gestureProgress)
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
        .onChange(of: claudeStore.shouldAutoExpand) { _, shouldExpand in
            handleAIAutoExpansionChange(shouldExpand)
        }
        .onChange(of: claudeStore.recentlyResolved.first?.id) { _, newID in
            handleDecisionResolved(newID)
        }
        .onChange(of: vm.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if vm.notchState == .closed {
                    coordinator.currentView = .shelf
                    doOpen()
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if vm.dropEvent {
                    vm.dropEvent = false
                    return
                }

                vm.dropEvent = false
                if !SharingStateManager.shared.preventNotchClose {
                    vm.close()
                }
            }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BrowBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && v8ClosedPillContent != .empty {
                          // Task 2.7: single precedence-driven pill —
                          // AI-attention > AI-running > music > mascot —
                          // replacing the old ad-hoc AI-tab / Music /
                          // BrowFaceAnimation branches. The `|| type ==
                          // .music` clause preserves the old Music branch's
                          // one exception: still show while the dedicated
                          // music sneak-peek is expanding.
                          V8ClosedPill(
                              content: v8ClosedPillContent,
                              albumArtNamespace: albumArtNamespace,
                              attentionSession: v8AttentionSession(for: v8ClosedPillContent),
                              attentionCount: v8AttentionCount,
                              mascotState: mascotFlashState ?? .idle,
                              size: vm.closedNotchSize,
                              // Per-screen physical-notch avoidance: on a
                              // notched MacBook `closedNotchSize.width` IS the
                              // cutout width, so pass it as the reserved span
                              // and the pill flanks it. External displays →
                              // 0 → spanning layout unchanged.
                              notchWidth: screenHasNotch(screenUUID: vm.screenUUID) ? vm.closedNotchSize.width : 0
                          )
                          .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.selectedIdleVisualizer] != nil && !vm.hideOnClosed {
                          IdleLottieActivity()
                       } else if vm.notchState == .open {
                           BrowHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                VStack {
                    switch coordinator.currentView {
                    case .ai:
                        IslandSurfaceView(
                            surface: currentIslandSurface,
                            model: AIAppModel.shared,
                            onJump: { session in TerminalJumpService.jump(to: session) },
                            maxContentHeight: openSurfaceMaxHeight
                        )
                        // Auto-dismiss the completion card ~5s after it
                        // appears (the old store toast's timer, moved to
                        // the surface). `.task(id:)` cancels/restarts when
                        // the surface changes, so a resolved card's timer
                        // is torn down the moment the surface flips away.
                        .task(id: currentIslandSurface) {
                            guard case let .completionCard(sessionID) = currentIslandSurface else { return }
                            try? await Task.sleep(for: .seconds(5))
                            guard !Task.isCancelled,
                                  let session = AIAppModel.shared.state.sessionsByID[sessionID]
                            else { return }
                            AIAppModel.shared.dismissCompletion(session)
                        }
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    }
                }
                .transition(
                    .scale(scale: 0.8, anchor: .top)
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.35))
                )
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: GeneralDropTargetDelegate(isTargeted: $vm.generalDropTargeting))
    }

    @ViewBuilder
    var dragDetector: some View {
        if Defaults[.boringShelf] && vm.notchState == .closed {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
            vm.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }

    private func doOpen() {
        withAnimation(animationSpring) {
            vm.open()
        }
    }

    // MARK: - Rainbow halo

    /// Same corner radii as `currentNotchShape` but as an open path —
    /// only the two concave shoulders + the bottom U, no top edge.
    private var currentNotchBottomBorder: NotchBottomBorder {
        NotchBottomBorder(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    /// Animated angular-gradient stroke that runs along the notch's
    /// visible outline (3 corners + bottom edge) whenever Claude Code is
    /// waiting on the user. Uses `TimelineView` so it ticks every
    /// animation frame without driving us through `@State`.
    @ViewBuilder
    private var rainbowNotchHalo: some View {
        TimelineView(.animation) { context in
            // 4-second loop. truncatingRemainder gives us a 0..<4 sawtooth
            // that we map onto a full 360° rotation of the gradient.
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t.truncatingRemainder(dividingBy: 4) / 4) * 360)
            let gradient = AngularGradient(
                gradient: Gradient(colors: [
                    .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
                ]),
                center: .center,
                angle: angle
            )
            ZStack {
                // Outer soft glow.
                currentNotchBottomBorder
                    .stroke(gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .blur(radius: 5)
                    .opacity(0.75)
                // Sharp inner stroke.
                currentNotchBottomBorder
                    .stroke(gradient, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .opacity(0.95)
            }
        }
    }

    // MARK: - Claude Code auto-expansion

    /// Drives the notch open / closed in response to Claude Code activity.
    /// Multi-screen safe: every screen runs this independently and acts on
    /// *its own* `vm`. Global UI state (saved tab, the `aiAutoExpanded`
    /// flag) lives on the singleton coordinator — whichever screen sees
    /// the transition first does the global cleanup; subsequent screens
    /// observe the now-cleared global state but still close their own
    /// notch via the per-screen `notchWasOpenBeforeAI` memo.
    private func handleAIAutoExpansionChange(_ shouldExpand: Bool) {
        if shouldExpand {
            // Per-screen memo before any state mutation.
            notchWasOpenBeforeAI = (vm.notchState == .open)

            // Global save — first screen wins, the rest are no-ops.
            if !coordinator.aiAutoExpanded {
                coordinator.viewBeforeAIAutoExpansion = coordinator.currentView
                coordinator.aiAutoExpanded = true
            }
            withAnimation(.smooth) {
                coordinator.currentView = .ai
            }
            if vm.notchState == .closed {
                doOpen()
            }
        } else {
            // A completion card showing right now is about to lose its
            // `.task(id:)` auto-dismiss timer below — collapsing the notch
            // (or the global cleanup flipping `coordinator.currentView`
            // away from `.ai`) tears down `IslandSurfaceView` before its 5s
            // sleep finishes, so `dismissCompletion` never runs. Record the
            // dismissal now, while the surface is still resolvable, so the
            // same completion doesn't re-present on the next manual AI-tab
            // open (checked before any state mutation below).
            if coordinator.currentView == .ai,
               case let .completionCard(sessionID) = currentIslandSurface,
               let session = AIAppModel.shared.state.sessionsByID[sessionID] {
                AIAppModel.shared.dismissCompletion(session)
            }

            // Per-screen close — runs on every screen regardless of who
            // cleared the global flag. Critically, this is independent
            // of `coordinator.currentView` because the first screen will
            // mutate that to the restore-tab before the others observe
            // the change — checking `currentView == .ai` here would race
            // and leave the remaining screens stuck open.
            if !notchWasOpenBeforeAI && vm.notchState == .open {
                withAnimation(animationSpring) {
                    vm.close()
                }
            }
            notchWasOpenBeforeAI = false

            // Global cleanup — first screen wins, the rest see the flag
            // already cleared and skip.
            if coordinator.aiAutoExpanded {
                let restoreTo = coordinator.viewBeforeAIAutoExpansion ?? .home
                coordinator.aiAutoExpanded = false
                coordinator.viewBeforeAIAutoExpansion = nil
                if coordinator.currentView == .ai {
                    withAnimation(.smooth) {
                        coordinator.currentView = restoreTo
                    }
                }
            }
        }
    }

    // MARK: - Task 2.7: v8 surface mount

    /// Which v8 card the open `.ai` tab shows right now. Kept here rather
    /// than as an `AIAppModel` computed property so Core stays free of a
    /// `ClaudeCodeStore` dependency (`AIAppModel` is an additive pure
    /// mirror per Task 1.7's doc comment) — this is the one place that's
    /// allowed to read both.
    ///
    /// - An attention-requiring session (approval/question) always wins,
    ///   most-recently-updated first — same tiebreak as
    ///   `AIAppModel.closedPillContent`.
    /// - Else, a session that JUST finished shows its completion card,
    ///   driven off `AIAppModel.completionCardSession(now:)` (a recently
    ///   completed, non-stale, not-yet-dismissed session) rather than
    ///   `claudeStore`'s `.stopped` toast — the `.task(id:)` on the surface
    ///   view below auto-dismisses it after 5s (`dismissCompletion`).
    /// - Else, the session list.
    private var currentIslandSurface: IslandSurface {
        let model = AIAppModel.shared
        if let attention = model.state.sessionsByID.values
            .filter(\.isVisibleInIsland)
            .filter(\.phase.requiresAttention)
            .max(by: { $0.updatedAt < $1.updatedAt })
        {
            switch attention.phase {
            case .waitingForApproval: return .approvalCard(sessionID: attention.id)
            case .waitingForAnswer:   return .questionCard(sessionID: attention.id)
            default: break
            }
        }
        if let completed = model.completionCardSession(now: Date()) {
            return .completionCard(sessionID: completed.id)
        }
        return .sessionList
    }

    /// Precedence-resolved content for the closed-notch `V8ClosedPill`.
    /// Reuses the coordinator/`Defaults` flags the old ad-hoc branches read
    /// (`musicLiveActivityEnabled` + `isPlaying`/`isPlayerIdle` for music,
    /// `showNotHumanFace` for the idle mascot) — `mascotEnabled` also
    /// requires no `selectedIdleVisualizer` chosen, preserving the old
    /// branch order where a custom Lottie idle visualizer always won over
    /// the built-in mascot (`IdleLottieActivity` stays a separate fallback
    /// below this pill for that case).
    private var v8ClosedPillContent: ClosedPillContent {
        AIAppModel.shared.closedPillContent(
            musicPlaying: (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled,
            mascotEnabled: showNotHumanFace && Defaults[.selectedIdleVisualizer] == nil
        )
    }

    /// The session backing a `.aiAttention` pill, and how many sessions are
    /// currently tied for that slot (`V8ClosedPill`'s trailing count badge).
    private func v8AttentionSession(for content: ClosedPillContent) -> AgentSession? {
        guard case let .aiAttention(sessionID) = content else { return nil }
        return AIAppModel.shared.state.sessionsByID[sessionID]
    }

    private var v8AttentionCount: Int {
        AIAppModel.shared.state.sessionsByID.values
            .filter { $0.isVisibleInIsland && $0.phase.requiresAttention }
            .count
    }

    /// Fires a brief `.approved`/`.denied` mascot flash whenever a new
    /// entry lands at the head of `claudeStore.recentlyResolved` (a fresh
    /// decision, not merely `recentlyResolved` mutating in some other way —
    /// `newID` only changes when index 0 itself changes). Self-clears back
    /// to `nil` (→ `.idle`) after `mascotFlashDuration`, cancelling any
    /// still-pending clear from a previous flash so back-to-back decisions
    /// each get their own full window.
    private func handleDecisionResolved(_ newID: UUID?) {
        guard newID != nil, let outcome = claudeStore.recentlyResolved.first?.outcome else { return }
        let flash: BrowMascot.MascotState
        switch outcome {
        case .decided(.deny):  flash = .denied
        case .decided:         flash = .approved
        case .timedOut:        return
        }
        mascotFlashTask?.cancel()
        mascotFlashState = flash
        mascotFlashTask = Task {
            try? await Task.sleep(for: mascotFlashDuration)
            guard !Task.isCancelled else { return }
            await MainActor.run { mascotFlashState = nil }
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }
        hoverTask?.cancel()
        
        if hovering {
            withAnimation(animationSpring) {
                isHovering = true
            }
            
            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }
            
            guard vm.notchState == .closed,
                  !coordinator.sneakPeek.show,
                  Defaults[.openNotchOnHover] else { return }
            
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.coordinator.sneakPeek.show else { return }
                    
                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    // Auto-height fix (commit bdc1377): the opened AI panel
                    // hugs its content, so a measurement/expand resizes the
                    // panel under a stationary pointer — a subview slides out
                    // from under the cursor and SwiftUI fires a spurious
                    // `.onHover(false)`. Acting on it closed the notch, the
                    // closed pill reappeared under the pointer, `.onHover(true)`
                    // reopened it → open/close flicker loop. Gate the close on
                    // the LIVE pointer actually being outside the island:
                    // `isMouseHovering()` hit-tests `notchSize`, which `open()`
                    // sets to `openNotchSize` while open — so this is the
                    // opened panel's rect. Still inside → the exit was
                    // spurious, keep the panel open and the hover state intact.
                    if self.vm.isMouseHovering() { return }

                    withAnimation(animationSpring) {
                        self.isHovering = false
                    }

                    if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                        self.vm.close()
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .open && !vm.isHoveringCalendar else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BrowViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
