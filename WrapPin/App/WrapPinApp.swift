import AppIntents
import SwiftUI

@main
struct WrapPinApp: App {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appModel: AppModel
    @State private var releaseUpdates = ReleaseUpdateModel()

    init() {
        // App Shortcuts and the interface share this one model.
        let appModel = AppModel()
        _appModel = State(initialValue: appModel)
        AppDependencyManager.shared.add(dependency: appModel)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                Group {
                if appModel.hasCompletedOnboarding || shouldBypassOnboarding {
#if WRAPPIN_SBB_EDITION
                    TrainView()
#else
                    HomeView(
                        showDeviceSetupInitially: appModel.shouldPresentDeviceSetup
                            || shouldShowDeviceSetupInitially,
                        showSettingsInitially: shouldShowSettingsInitially
                    )
                    .task { await releaseUpdates.checkOnLaunch() }
#endif
                    .transition(.opacity)
                } else {
                    OnboardingView()
                        .transition(.opacity)
                }
                }
            }
                .environment(appModel)
                .environment(releaseUpdates)
                .preferredColorScheme(preferredColorScheme)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.25),
                    value: appModel.hasCompletedOnboarding
                )
                .onOpenURL { url in
                    appModel.handleOpenURL(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    appModel.appBecameActive()
                }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appModel.appearance {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var shouldBypassOnboarding: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--skip-onboarding")
            || shouldShowDeviceSetupInitially
            || shouldShowSettingsInitially
#else
        false
#endif
    }

    private var shouldShowDeviceSetupInitially: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-device-setup")
#else
        false
#endif
    }

    private var shouldShowSettingsInitially: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-settings")
#else
        false
#endif
    }
}
