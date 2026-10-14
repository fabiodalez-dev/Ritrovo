import AppKit
import RitrovoCore
import SwiftUI

/// Interface language. English by default; Italian, or the system language,
/// on request. macOS picks the localization from AppleLanguages when the app
/// starts, so the choice is written there and takes effect at the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", italian = "it", system

    var id: String { rawValue }
    private static let key = "language"

    /// Each language is named in itself, so it can be found in any language.
    var title: String {
        switch self {
        case .english: return "English"
        case .italian: return "Italiano"
        case .system: return loc("System language")
        }
    }

    static var saved: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .english
    }

    /// The language this process started with (changes need a relaunch).
    static let atLaunch = saved

    static func save(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: key)
        apply(language)
    }

    /// Called at launch, before any text is read, and on every change.
    static func apply(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Starts a new copy of the app, then quits this one.
    @MainActor
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var language = AppLanguage.saved

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: language) { AppLanguage.save($0) }

            if language != AppLanguage.atLaunch {
                Hairline()
                Text("Ritrovo restarts to apply the new language.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.isBusy {
                        Text("Available when no recovery is running.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    Button("Restart now") { AppLanguage.relaunch() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.isBusy)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }
}
